const std = @import("std");
const ast = @import("ast.zig");
const catalog = @import("catalog.zig");
const page = @import("page.zig");
const parser_mod = @import("parser.zig");
const record = @import("record.zig");
const schema = @import("schema.zig");
const table = @import("table.zig");
const index_mod = @import("index.zig");

pub const SqlError = error{
    OutOfMemory,
    InvalidSelect,
    UnsupportedSql,
    TableNotFound,
    ColumnNotFound,
    UnsupportedWhere,
    PageOutOfBounds,
    InvalidPageNumber,
    PageTooSmall,
    InvalidPageType,
    InvalidCellIndex,
    CellOffsetOutOfBounds,
    InvalidPageHeader,
    UnsupportedTableBTree,
    InvalidTableCell,
    InvalidOverflowPage,
    PayloadOverflowUnsupported,
    TooSmall,
    Overflow,
    InvalidHeaderSize,
    InvalidSerialType,
    ValueOutOfBounds,
    VarintTooSmall,
    VarintOverflow,
    InvalidCreateTableSql,
    UnsupportedColumnType,
    UnsupportedIndexBTree,
    InvalidIndexCell,
    RowNotFound,
    TooManyColumns,
};

pub const SelectStatement = ast.SelectStatement;
pub const WhereClause = ast.WhereClause;
pub const Literal = ast.Literal;

/// A single cell in the query result set. `name` is the display label
/// (projection alias, or original column name, or literal like "COUNT(*)").
/// `value` is a `record.Value` variant, always owned by the result row.
pub const ResultCell = catalog.NamedValue;

pub const ResultRow = struct {
    /// -1 when the row is synthesised (aggregate, join) and doesn't map
    /// to a single underlying rowid.
    rowid: i64,
    values: []ResultCell,
    values_owned: bool = true,

    pub fn deinit(self: ResultRow, allocator: std.mem.Allocator) void {
        freeResultCellPayloads(self.values, allocator);
        if (self.values_owned) allocator.free(self.values);
    }
};

fn freeResultCellPayloads(values: []const ResultCell, allocator: std.mem.Allocator) void {
    for (values) |value| {
        switch (value.value) {
            .text => |text| allocator.free(text),
            .blob => |blob| allocator.free(blob),
            else => {},
        }
    }
}

/// Column metadata for the result set. For single-table `SELECT *`
/// this collapses to the underlying `TableInfo.columns`; for JOIN
/// and projection queries it's a freshly-built list.
pub const ResultColumn = struct {
    name: []const u8,
};

pub const QueryResult = struct {
    /// Column headers, one per cell in each `ResultRow`.
    columns: []ResultColumn,
    /// Convenience handle onto the primary FROM-table's info. For
    /// `SELECT *` queries this is the table the CLI prints verbatim.
    /// Consumers that don't need it can ignore it.
    table_info: catalog.TableInfo,
    rows: []ResultRow,
    /// Optional contiguous storage for every row's `values` slice. When
    /// present, individual rows borrow their cell slices from this slab.
    cell_slab: ?[]ResultCell = null,
    /// Fast deinit hint for result sets whose cells contain only scalar
    /// values and therefore do not own text/blob payloads.
    values_have_owned_payloads: bool = true,
    columns_owned: bool = true,
    table_info_owned: bool = true,

    pub fn deinit(self: QueryResult, allocator: std.mem.Allocator) void {
        for (self.rows) |row| {
            if (self.values_have_owned_payloads) freeResultCellPayloads(row.values, allocator);
            if (row.values_owned) allocator.free(row.values);
        }
        allocator.free(self.rows);
        if (self.cell_slab) |slab| allocator.free(slab);
        if (self.columns_owned) allocator.free(self.columns);
        if (self.table_info_owned) self.table_info.deinit(allocator);
    }
};

pub const CountPlan = struct {
    root_page: u32,
    stats: table.CountStats,
};

pub fn parseSelect(sql: []const u8, allocator: std.mem.Allocator) SqlError!SelectStatement {
    return parser_mod.parseSelect(sql, allocator) catch |err| return mapParseError(err);
}

/// A "source" is one table referenced by the query, identified either
/// by its alias (preferred) or its bare table name. When resolving a
/// `ColumnRef.qualifier`, we match against either field.
const Source = struct {
    info: catalog.TableInfo,
    alias: ?[]const u8,

    fn matches(self: Source, qualifier: []const u8) bool {
        if (self.alias) |a| {
            if (asciiEql(a, qualifier)) return true;
        }
        return asciiEql(self.info.name, qualifier);
    }
};

/// A scanned row paired with the source it came from. During join
/// execution we build cartesian-product tuples of these.
const SourcedRow = struct {
    source_index: usize,
    row: table.Row,
};

pub const PreparedSelect = struct {
    allocator: std.mem.Allocator,
    sql: []u8,
    stmt: SelectStatement,
    plan: PreparedSelectPlan = .generic,

    pub fn deinit(self: *PreparedSelect) void {
        self.plan.deinit(self.allocator);
        self.stmt.deinit(self.allocator);
        self.allocator.free(self.sql);
    }
};

const PreparedSelectPlan = union(enum) {
    generic,
    indexed_minmax: PreparedIndexedMinMax,

    fn deinit(self: PreparedSelectPlan, allocator: std.mem.Allocator) void {
        switch (self) {
            .generic => {},
            .indexed_minmax => |plan| {
                allocator.free(plan.columns);
                plan.table_info.deinit(allocator);
            },
        }
    }
};

const PreparedIndexedMinMax = struct {
    table_info: catalog.TableInfo,
    columns: []ResultColumn,
    index_root: u32,
    reverse: bool,
};

pub fn prepareSelect(sql: []const u8, allocator: std.mem.Allocator) SqlError!PreparedSelect {
    const sql_copy = try allocator.dupe(u8, sql);
    errdefer allocator.free(sql_copy);

    const stmt = try parseSelect(sql_copy, allocator);
    errdefer stmt.deinit(allocator);

    return .{
        .allocator = allocator,
        .sql = sql_copy,
        .stmt = stmt,
    };
}

pub fn prepareSelectForSchema(db_schema: schema.Schema, sql: []const u8, allocator: std.mem.Allocator) SqlError!PreparedSelect {
    var prepared = try prepareSelect(sql, allocator);
    errdefer prepared.deinit();
    prepared.plan = try buildPreparedSelectPlan(db_schema, prepared.stmt, allocator);
    return prepared;
}

pub fn executePreparedSelect(reader: page.PageReader, db_schema: schema.Schema, prepared: *const PreparedSelect, allocator: std.mem.Allocator) SqlError!QueryResult {
    return switch (prepared.plan) {
        .generic => executeSelectStatement(reader, db_schema, prepared.stmt, allocator),
        .indexed_minmax => |plan| executePreparedIndexedMinMax(reader, plan, allocator),
    };
}

pub fn executeSelect(reader: page.PageReader, db_schema: schema.Schema, sql: []const u8, allocator: std.mem.Allocator) SqlError!QueryResult {
    var parse_arena = std.heap.ArenaAllocator.init(allocator);
    defer parse_arena.deinit();
    const stmt = try parseSelect(sql, parse_arena.allocator());
    return executeSelectStatement(reader, db_schema, stmt, allocator);
}

fn buildPreparedSelectPlan(db_schema: schema.Schema, stmt: SelectStatement, allocator: std.mem.Allocator) SqlError!PreparedSelectPlan {
    if (stmt.where_expr != null or stmt.joins.len != 0 or stmt.projections.len != 1) return .generic;
    if (stmt.projections[0] != .aggregate) return .generic;

    const ag = stmt.projections[0].aggregate;
    if (ag.func != .min and ag.func != .max) return .generic;
    if (asciiEql(ag.column.name, "rowid")) return .generic;

    const primary_entry = db_schema.findTable(stmt.table_name) orelse return error.TableNotFound;
    var primary_info = try catalog.tableInfo(primary_entry, allocator);
    var consume_info = false;
    defer if (!consume_info) primary_info.deinit(allocator);

    const primary_source = Source{ .info = primary_info, .alias = stmt.table_alias };
    if (ag.column.qualifier) |q| {
        if (!primary_source.matches(q)) return .generic;
    }

    const index_entry = findIndexForColumn(db_schema, primary_info, ag.column.name) orelse return .generic;
    const sources = [_]Source{primary_source};
    const columns = try buildResultColumns(allocator, stmt.projections, sources[0..]);
    errdefer allocator.free(columns);

    const plan = PreparedIndexedMinMax{
        .table_info = primary_info,
        .columns = columns,
        .index_root = @intCast(index_entry.root_page),
        .reverse = ag.func == .max,
    };
    consume_info = true;
    return .{ .indexed_minmax = plan };
}

fn executePreparedIndexedMinMax(reader: page.PageReader, plan: PreparedIndexedMinMax, allocator: std.mem.Allocator) SqlError!QueryResult {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const ascratch = arena.allocator();

    const edge = try index_mod.firstNonNullFirstColumnEdgeValue(
        reader,
        plan.index_root,
        plan.reverse,
        ascratch,
    );

    var value: record.Value = .null;
    if (edge) |edge_value| {
        defer edge_value.deinit(ascratch);
        value = try dupValue(allocator, edge_value.value);
    }
    errdefer freeValue(allocator, value);

    var values = try allocator.alloc(ResultCell, 1);
    errdefer allocator.free(values);
    values[0] = .{ .name = plan.columns[0].name, .value = value };

    var rows = try allocator.alloc(ResultRow, 1);
    errdefer allocator.free(rows);
    rows[0] = .{ .rowid = -1, .values = values };

    return .{
        .columns = plan.columns,
        .table_info = plan.table_info,
        .rows = rows,
        .columns_owned = false,
        .table_info_owned = false,
    };
}

fn executeSelectStatement(reader: page.PageReader, db_schema: schema.Schema, stmt: SelectStatement, allocator: std.mem.Allocator) SqlError!QueryResult {
    // One arena for every transient allocation made during this query
    // — parsed Schema view, per-source TableInfo, scanned tables
    // themselves (each with its per-row []Value), intermediate tuple
    // lists, sort context, and any concat/LIKE strings produced during
    // expression evaluation. The arena is freed in bulk at function exit.
    //
    // The caller's `allocator` is still used for everything that
    // lives past the call: `QueryResult.columns`, `QueryResult.rows`,
    // and each `ResultRow.values` slice (with `dupe`d text/blob).
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const ascratch = arena.allocator();

    // --- Resolve every FROM / JOIN table into a Source list. ---
    var sources: std.ArrayList(Source) = .empty;

    const primary_entry = db_schema.findTable(stmt.table_name) orelse return error.TableNotFound;
    const primary_info = try catalog.tableInfo(primary_entry, ascratch);
    try sources.append(ascratch, .{ .info = primary_info, .alias = stmt.table_alias });

    for (stmt.joins) |j| {
        const jentry = db_schema.findTable(j.table_name) orelse return error.TableNotFound;
        const jinfo = try catalog.tableInfo(jentry, ascratch);
        try sources.append(ascratch, .{ .info = jinfo, .alias = j.alias });
    }

    // --- COUNT(*) shortcut: `SELECT COUNT(*) FROM t` with no WHERE
    // and no JOINs collapses to summing leaf-page cell_count fields
    // (table.countRows). No row materialisation, no per-row alloc —
    // matches what SQLite's optimizer does for the same query. ---
    if (stmt.where_expr == null and
        stmt.joins.len == 0 and
        stmt.projections.len == 1 and
        stmt.projections[0] == .count_star)
    {
        return try buildPureCountResult(allocator, primary_info, primary_entry, db_schema, reader, stmt.projections[0]);
    }

    // --- Filtered COUNT(*) shortcut for indexed predicates.
    // The general indexed fast path hydrates table rows after getting
    // rowids, which is useful for SELECT * but wasted for COUNT(*).
    // Count directly from the table key/index hit count when the
    // predicate shape is indexable and single-table.
    if (stmt.joins.len == 0 and
        stmt.projections.len == 1 and
        stmt.projections[0] == .count_star and
        stmt.where_expr != null)
    {
        const where_expr = stmt.where_expr.?;
        if (asSimpleRowidEq(where_expr)) |rid| {
            const n: u64 = if (try table.rowidExists(reader, primary_info.root_page, rid)) 1 else 0;
            return try buildCountResult(allocator, primary_info, stmt.projections[0], n);
        }
        if (asIndexableEq(where_expr)) |ieq| {
            if (try indexedCountForColumn(reader, db_schema, primary_info, ieq.column_name, ieq.value, ascratch)) |n| {
                return try buildCountResult(allocator, primary_info, stmt.projections[0], n);
            }
        }
        if (asIndexableRange(where_expr)) |range_pred| {
            if (try indexedCountForRange(reader, db_schema, primary_info, range_pred, ascratch)) |n| {
                return try buildCountResult(allocator, primary_info, stmt.projections[0], n);
            }
        }
        if (try asIndexableIn(where_expr, ascratch)) |in_pred| {
            if (try indexedCountForIn(reader, db_schema, primary_info, in_pred, ascratch)) |n| {
                return try buildCountResult(allocator, primary_info, stmt.projections[0], n);
            }
        }
    }

    // --- MIN/MAX shortcut: `SELECT MIN(indexed_col) FROM t` or
    // `SELECT MAX(indexed_col) FROM t` can read one non-NULL edge
    // value from the index instead of scanning table rows.
    if (try buildIndexedMinMaxResult(allocator, primary_info, db_schema, reader, stmt, sources.items, ascratch)) |result| {
        return result;
    }

    // The fast path only handles COUNT(*) among aggregates; if the
    // query mentions SUM/MIN/MAX/AVG/COUNT(col) fall through to the
    // general scan so reduceAggregates can do the math.
    var has_non_count_agg = false;
    for (stmt.projections) |p| if (p == .aggregate) {
        has_non_count_agg = true;
        break;
    };

    // --- Covering index scan: when projections are limited to the
    // indexed first column and/or rowid, the index entry already has
    // every value the caller needs. Try this before the indexed-rowid
    // hydration fast path so covered WHERE range / equality / IN queries
    // never bounce through table lookups.
    if (!has_non_count_agg and sources.items.len == 1) {
        if (try tryCoveringIndexScan(reader, db_schema, primary_info, stmt, sources.items, allocator, ascratch)) |result| {
            return result;
        }
    }

    // --- Fast path: single-table, WHERE is either `rowid = N` or an
    // indexed-column equality / range / IN-list. ---
    if (!has_non_count_agg and sources.items.len == 1 and stmt.where_expr != null) {
        const natural_rowid_order = if (stmt.order_by) |ob| isNaturalRowidAscOrder(ob, sources.items[0]) else false;
        if (asSimpleRowidEq(stmt.where_expr.?)) |rid| {
            return try buildFromSingleTable(reader, db_schema, stmt, sources.items, &sources, primary_info, rid, null, allocator, ascratch);
        }
        if (stmt.order_by == null or natural_rowid_order) {
            if (asIndexableEq(stmt.where_expr.?)) |ieq| {
                // When the caller asks for only a handful of rows, stop the
                // index walk as soon as we have them. Without this a small
                // LIMIT on a high-cardinality bucket still materialises every
                // matching rowid in the index page range.
                const small_limit: ?usize = if (stmt.limit) |l| (if (l > 0 and l < 1000) @as(usize, @intCast(l)) else null) else null;
                const rowids = if (small_limit) |limit|
                    try indexedRowidsForColumnWithLimit(reader, db_schema, primary_info, ieq.column_name, ieq.value, limit, ascratch)
                else
                    try indexedRowidsForColumn(reader, db_schema, primary_info, ieq.column_name, ieq.value, ascratch);
                if (rowids) |rids| {
                    return try buildFromSingleTable(reader, db_schema, stmt, sources.items, &sources, primary_info, null, rids, allocator, ascratch);
                }
            }
            // Range predicates (BETWEEN, <, <=, >, >=, AND-ed comparisons)
            // walk the indexed b-tree directly instead of full-scanning the
            // table. Returned rowids feed the same hydration path as the
            // equality fast path.
            if (asIndexableRange(stmt.where_expr.?)) |range_pred| {
                if (!asciiEql(range_pred.column_name, "rowid")) {
                    const limit_hint: ?usize = if (stmt.limit) |l|
                        (if (l > 0 and l < 1_000_000) @as(usize, @intCast(l)) else null)
                    else
                        null;
                    if (try indexedRowidsForRange(reader, db_schema, primary_info, range_pred, limit_hint, ascratch)) |rids| {
                        return try buildFromSingleTable(reader, db_schema, stmt, sources.items, &sources, primary_info, null, rids, allocator, ascratch);
                    }
                }
            }
            // `col IN (lit, lit, ...)` becomes N equality probes into the
            // index — much cheaper than a full table scan even for short
            // lists since each probe is O(log n) page reads.
            if (try asIndexableIn(stmt.where_expr.?, ascratch)) |in_pred| {
                const limit_hint: ?usize = if (stmt.limit) |l|
                    (if (l > 0 and l < 1_000_000) @as(usize, @intCast(l)) else null)
                else
                    null;
                if (try indexedRowidsForIn(reader, db_schema, primary_info, in_pred, limit_hint, ascratch)) |rids| {
                    return try buildFromSingleTable(reader, db_schema, stmt, sources.items, &sources, primary_info, null, rids, allocator, ascratch);
                }
            }
        }
    }

    // --- Indexed ORDER BY [DESC] LIMIT N: walk the index in order to
    // collect at most N rowids, hydrate, project. Avoids materialising
    // every row + a sort. Optionally accepts a range WHERE on the same
    // indexed column. ---
    if (!has_non_count_agg and
        sources.items.len == 1 and
        stmt.order_by != null and
        stmt.limit != null and
        stmt.limit.? > 0 and stmt.limit.? < 1_000_000)
    {
        const ob = stmt.order_by.?;
        if (ob.column.qualifier == null or sources.items[0].matches(ob.column.qualifier.?)) {
            if (!asciiEql(ob.column.name, "rowid")) {
                if (findIndexForColumn(db_schema, primary_info, ob.column.name)) |index_entry| {
                    var range_opts: IndexableRange = .{
                        .column_name = ob.column.name,
                        .low = .none,
                        .high = .none,
                    };
                    var range_ok = true;
                    if (stmt.where_expr) |w| {
                        if (asIndexableRange(w)) |r| {
                            if (asciiEql(r.column_name, ob.column.name)) {
                                range_opts = r;
                            } else range_ok = false;
                        } else range_ok = false;
                    }
                    if (range_ok) {
                        const limit_n: usize = @intCast(stmt.limit.?);
                        const rids = try collectIndexOrderedRowids(
                            reader,
                            @intCast(index_entry.root_page),
                            range_opts.low,
                            range_opts.high,
                            ob.descending,
                            limit_n,
                            ascratch,
                        );
                        return try buildFromSingleTable(reader, db_schema, stmt, sources.items, &sources, primary_info, null, rids, allocator, ascratch);
                    }
                }
            }
        }
    }

    // --- Streaming fast path: single source, no ORDER BY, or natural
    // rowid ASC order. Table b-trees are already visited in ascending
    // rowid order, so ORDER BY rowid/IPK ASC LIMIT can stop early.
    // We can walk the table via `scanTableForEach` and apply
    // WHERE / projection per row, skipping full scan materialisation.
    if (sources.items.len == 1 and
        (stmt.order_by == null or isNaturalRowidAscOrder(stmt.order_by.?, sources.items[0])))
    {
        var has_agg = false;
        for (stmt.projections) |p| {
            if (p == .count_star or p == .aggregate) {
                has_agg = true;
                break;
            }
        }
        if (has_agg) {
            // Streaming aggregates: accumulate SUM/COUNT/MIN/MAX/AVG
            // inline per row without ever materialising the full scan.
            return try streamSingleTableAgg(reader, stmt, sources.items, primary_info, allocator, ascratch);
        }
        return try streamSingleTable(reader, stmt, sources.items, primary_info, allocator, ascratch);
    }

    // --- General path: scan every source into the arena, build
    // cartesian-product rows, filter, project, sort, limit. ---
    var source_scans: std.ArrayList(table.Table) = .empty;
    for (sources.items) |src| {
        const scanned = try table.scanTable(reader, src.info.root_page, ascratch);
        try source_scans.append(ascratch, scanned);
    }

    // Build the cartesian product. Per-tuple SourcedRow slices come
    // out of the arena, so we never have to free them piecewise.
    var tuples: std.ArrayList([]SourcedRow) = .empty;
    try buildTuples(ascratch, sources.items, source_scans.items, stmt.joins, &tuples, ascratch);

    // Apply WHERE. Compile the expression once, evaluate the flat
    // instruction list per row — skips the recursive AST walk and
    // two O(n) lookups (resolveColumnSource + columnIndex) per column
    // reference per row.
    var filtered: std.ArrayList([]SourcedRow) = .empty;
    if (stmt.where_expr) |w| {
        const compiled = try compileExpr(w, sources.items, ascratch);
        for (tuples.items) |t| {
            const v = try evalCompiled(&compiled, t, ascratch);
            if (isTruthy(v)) try filtered.append(ascratch, t);
        }
    } else {
        for (tuples.items) |t| try filtered.append(ascratch, t);
    }

    // ORDER BY.
    if (stmt.order_by) |ob| {
        const src_idx = try resolveColumnSource(sources.items, ob.column);
        const col_idx = columnIndex(sources.items[src_idx].info, ob.column.name) orelse return error.ColumnNotFound;
        sortTuples(filtered.items, src_idx, col_idx, ob.descending, sources.items);
    }

    // Build the result column headers (once, from projection list) and
    // materialise rows.
    const columns = try buildResultColumns(allocator, stmt.projections, sources.items);
    errdefer allocator.free(columns);

    // Aggregate detection: if any projection is an aggregate we
    // collapse `filtered` to a single synthetic row, otherwise every
    // projection is per-row. Mixing is rejected (no implicit GROUP BY).
    var has_agg = false;
    for (stmt.projections) |p| {
        if (p == .count_star or p == .aggregate) {
            has_agg = true;
            break;
        }
    }

    var rows: std.ArrayList(ResultRow) = .empty;
    errdefer {
        for (rows.items) |r| r.deinit(allocator);
        rows.deinit(allocator);
    }

    if (has_agg) {
        // Every projection must be an aggregate (no implicit GROUP BY).
        for (stmt.projections) |p| switch (p) {
            .count_star, .aggregate => {},
            else => return error.UnsupportedSql,
        };
        const values = try reduceAggregates(allocator, stmt.projections, sources.items, filtered.items, columns, ascratch);
        try rows.append(allocator, .{ .rowid = -1, .values = values });
    } else {
        const limit = stmt.limit orelse std.math.maxInt(i64);
        var emitted: i64 = 0;
        for (filtered.items) |t| {
            if (emitted >= limit) break;
            emitted += 1;
            const values = try projectTuple(allocator, stmt.projections, sources.items, t, columns, ascratch);
            try rows.append(allocator, .{ .rowid = primaryRowid(t), .values = values });
        }
    }

    // The primary table info needs to escape the arena, so dupe its
    // columns into the caller's allocator. Aliases / names borrow
    // from `sql` (already stable for the caller).
    const out_info = try cloneTableInfo(allocator, primary_info);

    return .{
        .columns = columns,
        .table_info = out_info,
        .rows = try rows.toOwnedSlice(allocator),
    };
}

/// `SELECT COUNT(*) FROM t` shortcut. Skips parsing the b-tree leaves
/// — `table.countRows` walks the tree summing `cell_count` from each
/// leaf header, which is what SQLite's optimizer rewrites the same
/// query to. Saves the ~85 row materialisations we'd do otherwise.
fn buildPureCountResult(
    allocator: std.mem.Allocator,
    primary_info: catalog.TableInfo,
    primary_entry: schema.SchemaEntry,
    db_schema: schema.Schema,
    reader: page.PageReader,
    projection: ast.Projection,
) SqlError!QueryResult {
    const count_plan = try bestCountPlanForTable(reader, db_schema, primary_entry);
    return try buildCountResult(allocator, primary_info, projection, count_plan.stats.entries);
}

fn buildIndexedMinMaxResult(
    allocator: std.mem.Allocator,
    primary_info: catalog.TableInfo,
    db_schema: schema.Schema,
    reader: page.PageReader,
    stmt: SelectStatement,
    sources: []const Source,
    ascratch: std.mem.Allocator,
) SqlError!?QueryResult {
    if (stmt.where_expr != null or stmt.joins.len != 0 or stmt.projections.len != 1) return null;
    if (stmt.projections[0] != .aggregate) return null;

    const ag = stmt.projections[0].aggregate;
    if (ag.func != .min and ag.func != .max) return null;
    if (ag.column.qualifier) |q| {
        if (sources.len == 0 or !sources[0].matches(q)) return null;
    }
    if (asciiEql(ag.column.name, "rowid")) return null;

    const index_entry = findIndexForColumn(db_schema, primary_info, ag.column.name) orelse return null;
    const edge = try index_mod.firstNonNullFirstColumnEdgeValue(
        reader,
        @intCast(index_entry.root_page),
        ag.func == .max,
        ascratch,
    );

    const columns = try buildResultColumns(allocator, stmt.projections, sources);
    errdefer allocator.free(columns);

    var value: record.Value = .null;
    if (edge) |edge_value| {
        defer edge_value.deinit(ascratch);
        value = try dupValue(allocator, edge_value.value);
    }
    errdefer freeValue(allocator, value);

    var values = try allocator.alloc(ResultCell, 1);
    errdefer allocator.free(values);
    values[0] = .{ .name = columns[0].name, .value = value };

    var rows = try allocator.alloc(ResultRow, 1);
    errdefer allocator.free(rows);
    rows[0] = .{ .rowid = -1, .values = values };

    return .{
        .columns = columns,
        .table_info = try cloneTableInfo(allocator, primary_info),
        .rows = rows,
    };
}

fn buildCountResult(
    allocator: std.mem.Allocator,
    primary_info: catalog.TableInfo,
    projection: ast.Projection,
    n: u64,
) SqlError!QueryResult {
    const label = countStarLabel(projection);
    var columns = try allocator.alloc(ResultColumn, 1);
    errdefer allocator.free(columns);
    columns[0] = .{ .name = label };

    var values = try allocator.alloc(ResultCell, 1);
    errdefer allocator.free(values);
    values[0] = .{ .name = label, .value = .{ .integer = @intCast(n) } };

    var rows = try allocator.alloc(ResultRow, 1);
    rows[0] = .{ .rowid = -1, .values = values };

    const out_info = try cloneTableInfo(allocator, primary_info);
    return .{ .columns = columns, .table_info = out_info, .rows = rows };
}

fn countStarLabel(projection: ast.Projection) []const u8 {
    return switch (projection) {
        .count_star => |cs| cs.alias orelse "COUNT(*)",
        else => "COUNT(*)",
    };
}

pub fn bestCountRootForTable(reader: page.PageReader, db_schema: schema.Schema, table_entry: schema.SchemaEntry) SqlError!u32 {
    return (try bestCountPlanForTable(reader, db_schema, table_entry)).root_page;
}

pub fn bestCountPlanForTable(reader: page.PageReader, db_schema: schema.Schema, table_entry: schema.SchemaEntry) SqlError!CountPlan {
    if (table_entry.root_page <= 0) return error.TableNotFound;

    var best: ?CountPlan = null;

    for (db_schema.entries) |entry| {
        if (!isUsableCountIndex(entry, table_entry.name)) continue;
        const root: u32 = @intCast(entry.root_page);
        const stats = table.countBtreeEntries(reader, root) catch continue;
        if (best == null or stats.pages < best.?.stats.pages) {
            best = .{ .root_page = root, .stats = stats };
        }
    }

    if (best) |plan| return plan;

    const table_root: u32 = @intCast(table_entry.root_page);
    return .{
        .root_page = table_root,
        .stats = try table.countBtreeEntries(reader, table_root),
    };
}

fn isUsableCountIndex(entry: schema.SchemaEntry, table_name: []const u8) bool {
    if (!entry.isIndex() or entry.root_page <= 0) return false;
    if (!asciiEql(entry.table_name, table_name)) return false;
    if (entry.sql.len == 0) return true;
    return !containsSqlKeyword(entry.sql, "WHERE");
}

/// Streaming single-table SELECT — the no-JOIN, no-ORDER-BY,
/// no-aggregate path. Walks the table via `scanTableForEach` (zero
/// alloc per row, stack-allocated `InlineRecord`) and runs WHERE +
/// projection inline. Only matching rows pay for `dupe`-into-
/// `allocator`; non-matches are free.
///
/// This is the path that makes `WHERE col = lit AND col2 IS NOT NULL`
/// over an 85-row table land at ~4-5 µs/iter instead of the 20+ µs
/// it cost when we used to materialise the full scan first.
fn streamSingleTable(
    reader: page.PageReader,
    stmt: SelectStatement,
    sources: []const Source,
    info: catalog.TableInfo,
    allocator: std.mem.Allocator,
    ascratch: std.mem.Allocator,
) SqlError!QueryResult {
    const columns = try buildResultColumns(allocator, stmt.projections, sources);
    errdefer allocator.free(columns);

    var rows: std.ArrayList(ResultRow) = .empty;
    errdefer {
        for (rows.items) |r| r.deinit(allocator);
        rows.deinit(allocator);
    }

    const Ctx = struct {
        sources: []const Source,
        stmt: SelectStatement,
        compiled_where: ?CompiledExpr,
        columns: []const ResultColumn,
        rows_out: *std.ArrayList(ResultRow),
        allocator: std.mem.Allocator,
        ascratch: std.mem.Allocator,
        simple_projection: bool,
        emitted: i64,
        limit: i64,
        stop_after: bool, // set to true once limit hit
    };
    // Compile WHERE once so the per-row callback is a flat instruction
    // dispatch instead of a recursive AST walk.
    var compiled_where: ?CompiledExpr = null;
    if (stmt.where_expr) |w| compiled_where = try compileExpr(w, sources, ascratch);
    const simple_projection = projectionsAreSimpleSingleSource(stmt.projections);
    var ctx: Ctx = .{
        .sources = sources,
        .stmt = stmt,
        .compiled_where = compiled_where,
        .columns = columns,
        .rows_out = &rows,
        .allocator = allocator,
        .ascratch = ascratch,
        .simple_projection = simple_projection,
        .emitted = 0,
        .limit = stmt.limit orelse std.math.maxInt(i64),
        .stop_after = false,
    };

    const onRow = struct {
        fn call(c: *Ctx, rowid: i64, values: []const record.Value) SqlError!void {
            if (c.stop_after) return;
            var tuple_buf: [1]SourcedRow = undefined;
            var have_tuple = false;
            if (c.compiled_where != null or !c.simple_projection) {
                // Evaluation is synchronous, so the tuple can borrow the
                // scanner's row view instead of copying it per row.
                tuple_buf[0] = .{ .source_index = 0, .row = .{ .rowid = rowid, .values = @constCast(values) } };
                have_tuple = true;
            }
            if (c.compiled_where) |*cw| {
                if (!isTruthy(try evalCompiled(cw, tuple_buf[0..], c.ascratch))) return;
            }
            const out_values = if (c.simple_projection)
                try projectSingleSourceRow(c.allocator, c.stmt.projections, c.sources[0], rowid, values, c.columns)
            else
                try projectTuple(c.allocator, c.stmt.projections, c.sources, tuple_buf[0..@intFromBool(have_tuple)], c.columns, c.ascratch);
            try c.rows_out.append(c.allocator, .{ .rowid = rowid, .values = out_values });
            c.emitted += 1;
            if (c.emitted >= c.limit) c.stop_after = true;
        }
    }.call;

    var mask = record.ProjectionMask.empty();
    var mask_safe = simple_projection and sources.len == 1;
    if (mask_safe) mask_safe = try buildProjectionMaskFromProjections(stmt.projections, sources[0], &mask);
    if (mask_safe) {
        if (compiled_where) |cw| mask_safe = addCompiledExprColumnsToMask(cw, 0, &mask);
    }

    if (mask_safe) {
        table.scanTableForEachProjected(reader, info.root_page, allocator, mask, &ctx, onRow) catch |err| {
            return mapTableScanErr(err);
        };
    } else {
        table.scanTableForEach(reader, info.root_page, &ctx, onRow) catch |err| handle_scan_err: {
            if (err == error.PayloadOverflowUnsupported) {
                for (rows.items) |r| r.deinit(allocator);
                rows.clearRetainingCapacity();
                ctx.emitted = 0;
                ctx.stop_after = false;
                table.scanTableForEachAlloc(reader, info.root_page, allocator, &ctx, onRow) catch |alloc_err| {
                    return mapTableScanErr(alloc_err);
                };
                break :handle_scan_err;
            }
            return mapTableScanErr(err);
        };
    }

    return .{
        .columns = columns,
        .table_info = try cloneTableInfo(allocator, info),
        .rows = try rows.toOwnedSlice(allocator),
    };
}

fn mapTableScanErr(err: anyerror) SqlError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.TooManyColumns => error.TooManyColumns,
        error.PayloadOverflowUnsupported => error.PayloadOverflowUnsupported,
        error.CellOffsetOutOfBounds => error.CellOffsetOutOfBounds,
        error.InvalidCellIndex => error.InvalidCellIndex,
        error.InvalidHeaderSize => error.InvalidHeaderSize,
        error.InvalidOverflowPage => error.InvalidOverflowPage,
        error.InvalidPageHeader => error.InvalidPageHeader,
        error.InvalidPageNumber => error.InvalidPageNumber,
        error.InvalidPageType => error.InvalidPageType,
        error.InvalidSerialType => error.InvalidSerialType,
        error.InvalidTableCell => error.InvalidTableCell,
        error.Overflow => error.Overflow,
        error.PageOutOfBounds => error.PageOutOfBounds,
        error.PageTooSmall => error.PageTooSmall,
        error.RowNotFound => error.RowNotFound,
        error.ValueOutOfBounds => error.ValueOutOfBounds,
        error.VarintOverflow => error.VarintOverflow,
        error.VarintTooSmall => error.VarintTooSmall,
        else => error.UnsupportedSql,
    };
}

fn buildProjectionMaskFromProjections(
    projections: []const ast.Projection,
    source: Source,
    mask: *record.ProjectionMask,
) SqlError!bool {
    for (projections) |p| switch (p) {
        .star => {
            if (source.info.columns.len > record.MAX_INLINE_VALUES) return false;
            for (source.info.columns, 0..) |_, idx| mask.set(idx);
        },
        .table_star => |qname| {
            if (!source.matches(qname)) return error.TableNotFound;
            if (source.info.columns.len > record.MAX_INLINE_VALUES) return false;
            for (source.info.columns, 0..) |_, idx| mask.set(idx);
        },
        .column => |col| {
            if (col.ref.qualifier) |q| {
                if (!source.matches(q)) return error.ColumnNotFound;
            }
            if (asciiEql(col.ref.name, "rowid")) continue;
            const idx = columnIndex(source.info, col.ref.name) orelse return error.ColumnNotFound;
            if (idx >= record.MAX_INLINE_VALUES) return false;
            mask.set(idx);
        },
        .expr, .count_star, .aggregate => unreachable,
    };
    return true;
}

fn addCompiledExprColumnsToMask(compiled: CompiledExpr, source_index: u8, mask: *record.ProjectionMask) bool {
    for (compiled.cols) |col| {
        if (col.source_index != source_index) return false;
        if (col.column_index >= record.MAX_INLINE_VALUES) return false;
        mask.set(col.column_index);
    }
    return true;
}

/// Streaming path for single-table aggregate queries (SUM, COUNT,
/// MIN, MAX, AVG without GROUP BY). Walks the table via
/// `scanTableForEach`, updates in-line accumulators per matching row,
/// and produces a single result row — zero scan materialisation.
fn streamSingleTableAgg(
    reader: page.PageReader,
    stmt: SelectStatement,
    sources: []const Source,
    info: catalog.TableInfo,
    allocator: std.mem.Allocator,
    ascratch: std.mem.Allocator,
) SqlError!QueryResult {
    const columns = try buildResultColumns(allocator, stmt.projections, sources);
    errdefer allocator.free(columns);

    // Validate: every projection must be a pure aggregate; no GROUP BY.
    for (stmt.projections) |p| switch (p) {
        .count_star, .aggregate => {},
        else => return error.UnsupportedSql,
    };

    // Compile WHERE once (if present).
    var compiled_where: ?CompiledExpr = null;
    if (stmt.where_expr) |w| compiled_where = try compileExpr(w, sources, ascratch);

    // ── accumulator state ──────────────────────────────────────────
    const Acc = struct {
        count: i64 = 0,
        sum: f64 = 0,
        sum_int: i64 = 0,
        any_real: bool = false,
        min_v: ?record.Value = null,
        max_v: ?record.Value = null,
    };
    var accs: std.ArrayList(Acc) = .empty;
    defer accs.deinit(ascratch);
    {
        var n_aggs: usize = 0;
        for (stmt.projections) |p| {
            if (p == .aggregate) n_aggs += 1;
        }
        try accs.ensureTotalCapacity(ascratch, n_aggs);
        for (stmt.projections) |p| {
            if (p == .aggregate) accs.appendAssumeCapacity(.{});
        }
    }

    var total_count: i64 = 0;

    // ── Pre-resolve column indices for each aggregate ───────────────
    const ResolvedAgg = struct { col_idx: usize, ipk: bool, func: ast.AggregateFunc };
    var resolved: std.ArrayList(ResolvedAgg) = .empty;
    defer resolved.deinit(ascratch);
    for (stmt.projections) |p| {
        if (p == .aggregate) {
            const ag = p.aggregate;
            const ci = columnIndex(info, ag.column.name) orelse return error.ColumnNotFound;
            const ipk = if (info.integer_primary_key_index) |ipk_idx| ci == ipk_idx else false;
            try resolved.append(ascratch, .{ .col_idx = ci, .ipk = ipk, .func = ag.func });
        }
    }

    // ── Per-row callback (rewritten to use pre-resolved columns) ────
    const Ctx2 = struct {
        accs: []Acc,
        total_count: *i64,
        compiled_where: ?*CompiledExpr,
        resolved: []ResolvedAgg,
        info: *const catalog.TableInfo,
        ascratch: std.mem.Allocator,
    };
    var ctx2: Ctx2 = .{
        .accs = accs.items,
        .total_count = &total_count,
        .compiled_where = if (compiled_where) |*cw| cw else null,
        .resolved = resolved.items,
        .info = &info,
        .ascratch = ascratch,
    };

    const onRow2 = struct {
        fn call(c: *Ctx2, rowid: i64, values: []const record.Value) SqlError!void {
            // WHERE filter.
            if (c.compiled_where) |cw| {
                const row = table.Row{ .rowid = rowid, .values = @constCast(values) };
                var tuple_buf: [1]SourcedRow = .{.{ .source_index = 0, .row = row }};
                if (!isTruthy(try evalCompiled(cw, &tuple_buf, c.ascratch))) return;
            }
            c.total_count.* += 1;

            for (c.accs, 0..) |*acc, pi| {
                const ra = c.resolved[pi];
                var v: record.Value = if (ra.col_idx < values.len) values[ra.col_idx] else .null;
                if (ra.ipk and v == .null) v = .{ .integer = rowid };
                if (v == .null) continue;
                acc.count += 1;
                switch (ra.func) {
                    .sum, .avg => switch (v) {
                        .integer => |x| {
                            if (!acc.any_real) acc.sum_int +%= x;
                            acc.sum += @floatFromInt(x);
                        },
                        .real => |x| {
                            acc.any_real = true;
                            acc.sum += x;
                        },
                        else => {},
                    },
                    .min => {
                        if (acc.min_v == null or compareValues(v, acc.min_v.?, .lt)) acc.min_v = v;
                    },
                    .max => {
                        if (acc.max_v == null or compareValues(v, acc.max_v.?, .gt)) acc.max_v = v;
                    },
                    .count => {},
                }
            }
        }
    }.call;

    table.scanTableForEach(reader, info.root_page, &ctx2, onRow2) catch |err| {
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.TooManyColumns => error.TooManyColumns,
            error.PayloadOverflowUnsupported => error.PayloadOverflowUnsupported,
            error.CellOffsetOutOfBounds => error.CellOffsetOutOfBounds,
            error.InvalidPageNumber => error.InvalidPageNumber,
            error.InvalidPageType => error.InvalidPageType,
            error.InvalidTableCell => error.InvalidTableCell,
            error.Overflow => error.Overflow,
            error.PageOutOfBounds => error.PageOutOfBounds,
            error.PageTooSmall => error.PageTooSmall,
            error.RowNotFound => error.RowNotFound,
            error.VarintOverflow => error.VarintOverflow,
            error.VarintTooSmall => error.VarintTooSmall,
            else => error.UnsupportedSql,
        };
    };

    // ── Build the single result row ────────────────────────────────
    const values = try allocator.alloc(ResultCell, columns.len);
    errdefer allocator.free(values);
    var ai: usize = 0;
    for (stmt.projections, 0..) |p, i| {
        switch (p) {
            .count_star => values[i] = .{ .name = columns[i].name, .value = .{ .integer = total_count } },
            .aggregate => |ag| {
                const acc = accs.items[ai];
                ai += 1;
                const out_value: record.Value = switch (ag.func) {
                    .count => .{ .integer = acc.count },
                    .sum => if (acc.count == 0) .null else if (acc.any_real) .{ .real = acc.sum } else .{ .integer = acc.sum_int },
                    .avg => if (acc.count == 0) .null else .{ .real = acc.sum / @as(f64, @floatFromInt(acc.count)) },
                    .min => acc.min_v orelse .null,
                    .max => acc.max_v orelse .null,
                };
                values[i] = .{ .name = columns[i].name, .value = try dupValue(allocator, out_value) };
            },
            else => unreachable,
        }
    }

    var rows: std.ArrayList(ResultRow) = .empty;
    try rows.append(allocator, .{ .rowid = -1, .values = values });

    return .{
        .columns = columns,
        .table_info = try cloneTableInfo(allocator, info),
        .rows = try rows.toOwnedSlice(allocator),
    };
}

/// Copy a `TableInfo` from the arena into the caller's allocator so
/// it can outlive the query's arena.
fn cloneTableInfo(allocator: std.mem.Allocator, info: catalog.TableInfo) !catalog.TableInfo {
    const cols = try allocator.dupe(catalog.Column, info.columns);
    return .{
        .name = info.name,
        .root_page = info.root_page,
        .columns = cols,
        .integer_primary_key_index = info.integer_primary_key_index,
    };
}

fn primaryRowid(tuple: []const SourcedRow) i64 {
    for (tuple) |sr| if (sr.source_index == 0) return sr.row.rowid;
    return -1;
}

/// Build the cartesian product of every source's rows, applying each
/// JOIN's ON predicate as it's composed so the intermediate product
/// stays small. Source 0 is the FROM table; sources 1..N line up with
/// `joins[0..N-1]`.
fn buildTuples(
    allocator: std.mem.Allocator,
    sources: []const Source,
    scans: []const table.Table,
    joins: []const ast.JoinClause,
    out: *std.ArrayList([]SourcedRow),
    scratch: std.mem.Allocator,
) SqlError!void {
    std.debug.assert(sources.len == scans.len);
    // Seed with every row of source 0.
    for (scans[0].rows) |row| {
        const t = try allocator.alloc(SourcedRow, 1);
        t[0] = .{ .source_index = 0, .row = row };
        try out.append(allocator, t);
    }
    var join_i: usize = 0;
    while (join_i < joins.len) : (join_i += 1) {
        const src_idx = join_i + 1;
        const on_expr = joins[join_i].on;
        // Compile ON clause once per join — each combined row then
        // executes a flat instruction list instead of recursing the AST.
        const compiled_on = try compileExpr(on_expr, sources, scratch);
        var next: std.ArrayList([]SourcedRow) = .empty;
        errdefer {
            for (next.items) |t| allocator.free(t);
            next.deinit(allocator);
        }
        for (out.items) |partial| {
            for (scans[src_idx].rows) |row| {
                const combined = try allocator.alloc(SourcedRow, partial.len + 1);
                @memcpy(combined[0..partial.len], partial);
                combined[partial.len] = .{ .source_index = src_idx, .row = row };
                // Evaluate ON eagerly so non-matching pairs don't
                // participate in downstream joins.
                const v = try evalCompiled(&compiled_on, combined, scratch);
                if (!isTruthy(v)) {
                    allocator.free(combined);
                    continue;
                }
                try next.append(allocator, combined);
            }
        }
        // Replace `out` with `next`, freeing the old partials.
        for (out.items) |t| allocator.free(t);
        out.clearRetainingCapacity();
        try out.ensureTotalCapacity(allocator, next.items.len);
        for (next.items) |t| out.appendAssumeCapacity(t);
        next.deinit(allocator);
    }
}

fn resolveColumnSource(sources: []const Source, col: ast.ColumnRef) SqlError!usize {
    if (col.qualifier) |q| {
        for (sources, 0..) |s, i| if (s.matches(q)) return i;
        return error.ColumnNotFound;
    }
    // Unqualified: prefer the single matching source; if multiple
    // sources have a column of this name, require qualification.
    var found: ?usize = null;
    for (sources, 0..) |s, i| {
        if (asciiEql(col.name, "rowid")) {
            // `rowid` unqualified is ambiguous in a join but useful in
            // single-table queries. Match only source 0.
            if (i == 0) return 0;
            continue;
        }
        if (columnIndex(s.info, col.name) != null) {
            if (found != null) return error.UnsupportedSql; // ambiguous
            found = i;
        }
    }
    return found orelse error.ColumnNotFound;
}

fn evalColumn(sources: []const Source, tuple: []const SourcedRow, col: ast.ColumnRef) SqlError!record.Value {
    const src_idx = try resolveColumnSource(sources, col);
    // Locate this source's row in the tuple. Since `buildTuples`
    // appends in source order, `tuple[src_idx]` is usually correct,
    // but we don't rely on it.
    var row: ?table.Row = null;
    for (tuple) |sr| if (sr.source_index == src_idx) {
        row = sr.row;
        break;
    };
    const r = row orelse return .null;
    if (asciiEql(col.name, "rowid")) return .{ .integer = r.rowid };
    const info = sources[src_idx].info;
    const idx = columnIndex(info, col.name) orelse return error.ColumnNotFound;
    var v: record.Value = if (idx < r.values.len) r.values[idx] else .null;
    if (info.integer_primary_key_index) |ipk| {
        if (idx == ipk and v == .null) v = .{ .integer = r.rowid };
    }
    return v;
}

/// Evaluate an expression to a value. Predicates (boolean results)
/// also flow through here; they're coerced back to int 0/1. The
/// caller is responsible for freeing any `.text` / `.blob` returned
/// — except that right now every concat/arithmetic result that
/// produces a new string threads through `scratchAllocFor` and is
/// freed when the query arena winds down. For the executor's
/// predicate path we only ever look at numeric/bool coercions, so
/// this is a non-issue; projection has its own ownership rules.
fn evalExpr(expr: *ast.Expr, sources: []const Source, tuple: []const SourcedRow, scratch: std.mem.Allocator) SqlError!record.Value {
    return switch (expr.*) {
        .literal => |lit| switch (lit) {
            .null => .null,
            .integer => |v| .{ .integer = v },
            .text => |v| .{ .text = v },
        },
        .column => |c| try evalColumn(sources, tuple, c),
        .binary => |bin| try evalBinary(bin.op, bin.lhs, bin.rhs, sources, tuple, scratch),
        .unary => |u| try evalUnary(u.op, u.operand, sources, tuple, scratch),
        .in_list => |il| blk: {
            const v = try evalExpr(il.value, sources, tuple, scratch);
            var hit = false;
            for (il.items) |it| {
                const candidate = try evalExpr(it, sources, tuple, scratch);
                if (compareValues(v, candidate, .eq)) {
                    hit = true;
                    break;
                }
            }
            const matched = if (il.negated) !hit else hit;
            break :blk .{ .integer = if (matched) 1 else 0 };
        },
        .between => |bt| blk: {
            const v = try evalExpr(bt.value, sources, tuple, scratch);
            const low = try evalExpr(bt.low, sources, tuple, scratch);
            const high = try evalExpr(bt.high, sources, tuple, scratch);
            const in_range = compareValues(v, low, .ge) and compareValues(v, high, .le);
            const matched = if (bt.negated) !in_range else in_range;
            break :blk .{ .integer = if (matched) 1 else 0 };
        },
    };
}

fn evalBinary(op: ast.BinOp, lhs_expr: *ast.Expr, rhs_expr: *ast.Expr, sources: []const Source, tuple: []const SourcedRow, scratch: std.mem.Allocator) SqlError!record.Value {
    // Short-circuit logical ops BEFORE evaluating RHS so NULL
    // propagation and error-avoidance work.
    if (op == .and_ or op == .or_) {
        const l = try evalPredicate(lhs_expr, sources, tuple, scratch);
        const r_needed = if (op == .and_) l else !l;
        if (!r_needed) return .{ .integer = if (op == .or_ and l) 1 else 0 };
        const r = try evalPredicate(rhs_expr, sources, tuple, scratch);
        return .{ .integer = if (r) 1 else 0 };
    }
    const l = try evalExpr(lhs_expr, sources, tuple, scratch);
    const r = try evalExpr(rhs_expr, sources, tuple, scratch);
    return switch (op) {
        .eq, .ne, .lt, .le, .gt, .ge => .{ .integer = if (compareValues(l, r, op)) 1 else 0 },
        .add, .sub, .mul, .div, .mod => try evalArith(l, r, op),
        .concat => try evalConcat(l, r, scratch),
        .like => .{ .integer = if (evalLike(l, r)) 1 else 0 },
        .not_like => .{ .integer = if (!evalLike(l, r)) 1 else 0 },
        .and_, .or_, .is_null, .is_not_null, .neg, .not_ => unreachable,
    };
}

fn evalUnary(op: ast.BinOp, operand: *ast.Expr, sources: []const Source, tuple: []const SourcedRow, scratch: std.mem.Allocator) SqlError!record.Value {
    const v = try evalExpr(operand, sources, tuple, scratch);
    return switch (op) {
        .is_null => .{ .integer = if (v == .null) 1 else 0 },
        .is_not_null => .{ .integer = if (v != .null) 1 else 0 },
        .not_ => blk: {
            const tv = switch (v) {
                .null => false,
                .integer => |x| x != 0,
                .real => |x| x != 0.0,
                .text => |x| x.len != 0,
                .blob => |x| x.len != 0,
            };
            break :blk .{ .integer = if (!tv) 1 else 0 };
        },
        .neg => switch (v) {
            .integer => |x| .{ .integer = -x },
            .real => |x| .{ .real = -x },
            else => .null,
        },
        else => unreachable,
    };
}

fn evalArith(a: record.Value, b: record.Value, op: ast.BinOp) SqlError!record.Value {
    if (a == .null or b == .null) return .null;
    // If either operand is real, promote to real. Integer/integer
    // stays integer (/ is still integer division to mirror SQLite).
    const a_real: ?f64 = switch (a) {
        .real => |x| x,
        else => null,
    };
    const b_real: ?f64 = switch (b) {
        .real => |x| x,
        else => null,
    };
    if (a_real != null or b_real != null) {
        const af: f64 = a_real orelse switch (a) {
            .integer => |x| @floatFromInt(x),
            else => return .null,
        };
        const bf: f64 = b_real orelse switch (b) {
            .integer => |x| @floatFromInt(x),
            else => return .null,
        };
        return switch (op) {
            .add => .{ .real = af + bf },
            .sub => .{ .real = af - bf },
            .mul => .{ .real = af * bf },
            .div => if (bf == 0) .null else .{ .real = af / bf },
            .mod => if (bf == 0) .null else .{ .real = @mod(af, bf) },
            else => unreachable,
        };
    }
    const ai: i64 = switch (a) {
        .integer => |x| x,
        else => return .null,
    };
    const bi: i64 = switch (b) {
        .integer => |x| x,
        else => return .null,
    };
    return switch (op) {
        .add => .{ .integer = ai +% bi },
        .sub => .{ .integer = ai -% bi },
        .mul => .{ .integer = ai *% bi },
        .div => if (bi == 0) .null else .{ .integer = @divTrunc(ai, bi) },
        .mod => if (bi == 0) .null else .{ .integer = @rem(ai, bi) },
        else => unreachable,
    };
}

fn evalConcat(a: record.Value, b: record.Value, scratch: std.mem.Allocator) SqlError!record.Value {
    if (a == .null or b == .null) return .null;
    const as = try valueToText(a, scratch);
    const bs = try valueToText(b, scratch);
    const out = try scratch.alloc(u8, as.len + bs.len);
    @memcpy(out[0..as.len], as);
    @memcpy(out[as.len..], bs);
    return .{ .text = out };
}

fn valueToText(v: record.Value, scratch: std.mem.Allocator) SqlError![]const u8 {
    return switch (v) {
        .text => |t| t,
        .blob => |b| b,
        .integer => |i| try std.fmt.allocPrint(scratch, "{d}", .{i}),
        .real => |r| try std.fmt.allocPrint(scratch, "{d}", .{r}),
        .null => "",
    };
}

/// SQLite-compatible LIKE: `%` matches zero-or-more characters, `_`
/// matches exactly one. Case-insensitive for ASCII (matches default
/// SQLite `NOCASE` on the `LIKE` operator when the PRAGMA is
/// `case_sensitive_like = 0`, which is the default).
fn evalLike(value: record.Value, pattern: record.Value) bool {
    const v = switch (value) {
        .text => |t| t,
        .blob => |b| b,
        else => return false,
    };
    const p = switch (pattern) {
        .text => |t| t,
        .blob => |b| b,
        else => return false,
    };
    return likeMatch(v, p);
}

fn likeMatch(text: []const u8, pat: []const u8) bool {
    // Iterative walker with fallback (classic glob-match idiom).
    var ti: usize = 0;
    var pi: usize = 0;
    var star_ti: ?usize = null;
    var star_pi: usize = 0;
    while (ti < text.len) {
        if (pi < pat.len and pat[pi] == '%') {
            star_pi = pi;
            star_ti = ti;
            pi += 1;
            continue;
        }
        if (pi < pat.len and (pat[pi] == '_' or std.ascii.toLower(pat[pi]) == std.ascii.toLower(text[ti]))) {
            ti += 1;
            pi += 1;
            continue;
        }
        if (star_ti) |sti| {
            star_ti = sti + 1;
            ti = sti + 1;
            pi = star_pi + 1;
            continue;
        }
        return false;
    }
    while (pi < pat.len and pat[pi] == '%') pi += 1;
    return pi == pat.len;
}

/// Evaluate an expression tree as a boolean predicate. Everything
/// funnels through `evalExpr` and is coerced to a isTruthy/falsy value
/// using SQLite-ish rules (NULL is false, 0 is false, empty string is
/// false, anything else is true).
fn evalPredicate(expr: *ast.Expr, sources: []const Source, tuple: []const SourcedRow, scratch: std.mem.Allocator) SqlError!bool {
    const v = try evalExpr(expr, sources, tuple, scratch);
    return switch (v) {
        .null => false,
        .integer => |x| x != 0,
        .real => |x| x != 0.0,
        .text => |x| x.len != 0,
        .blob => |x| x.len != 0,
    };
}

/// Value comparison with SQLite-ish semantics: NULL always compares
/// as false (SQL NULL propagation would return NULL; we collapse
/// that to FALSE for predicate purposes). Mixed-type comparison is
/// false except for integer/real which are coerced.
fn compareValues(a: record.Value, b: record.Value, op: ast.BinOp) bool {
    if (a == .null or b == .null) return false;
    const af: ?f64 = switch (a) {
        .integer => |x| @floatFromInt(x),
        .real => |x| x,
        else => null,
    };
    const bf: ?f64 = switch (b) {
        .integer => |x| @floatFromInt(x),
        .real => |x| x,
        else => null,
    };
    if (af != null and bf != null) {
        const x = af.?;
        const y = bf.?;
        return switch (op) {
            .eq => x == y,
            .ne => x != y,
            .lt => x < y,
            .le => x <= y,
            .gt => x > y,
            .ge => x >= y,
            else => false,
        };
    }
    // TEXT comparison.
    const as: ?[]const u8 = switch (a) {
        .text => |x| x,
        .blob => |x| x,
        else => null,
    };
    const bs: ?[]const u8 = switch (b) {
        .text => |x| x,
        .blob => |x| x,
        else => null,
    };
    if (as) |x| if (bs) |y| {
        const cmp = std.mem.order(u8, x, y);
        return switch (op) {
            .eq => cmp == .eq,
            .ne => cmp != .eq,
            .lt => cmp == .lt,
            .le => cmp != .gt,
            .gt => cmp == .gt,
            .ge => cmp != .lt,
            else => false,
        };
    };
    return false;
}

// ── compiled expression VM ─────────────────────────────────────────────

/// A pre-resolved column reference. `source_index` and `column_index`
/// are pre-computed during compilation so expression evaluation is O(1)
/// instead of scanning `sources` and `columns` per reference per row.
const ResolvedColumn = struct {
    source_index: u8,
    column_index: u8,
    /// When true, a NULL at this column returns the rowid instead
    /// (SQLite INTEGER PRIMARY KEY behaviour).
    ipk: bool = false,
};

const InstrOp = enum(u8) {
    push_col, // a = index into cols[], b = unused
    push_null, // stack[sp++] = .null
    push_int, // a = index into ints[]
    push_text, // a = index into texts[]
    eq,
    ne,
    lt,
    le,
    gt,
    ge, // binary compare — pops 2, pushes int(0/1)
    add,
    sub,
    mul,
    div,
    mod, // binary arith
    concat, // string concat
    like,
    not_like,
    and_,
    or_, // logical — short-circuit NOT applied (pre-evaluated both sides)
    not_, // unary logical not
    is_null,
    is_not_null,
    neg, // unary arithmetic negation
};

const Instr = struct {
    op: InstrOp,
    a: u16, // meaning depends on op
    b: u16, // meaning depends on op
};

/// A "compiled" expression: a flat instruction list + literal storage,
/// produced once per query and evaluated per row with zero tree-walking.
pub const CompiledExpr = struct {
    instrs: []Instr,
    ints: []i64,
    texts: [][]const u8, // borrowed from arena
    cols: []ResolvedColumn,

    pub fn deinit(self: *CompiledExpr, alloc: std.mem.Allocator) void {
        alloc.free(self.instrs);
        alloc.free(self.ints);
        alloc.free(self.texts);
        alloc.free(self.cols);
    }
};

/// Walk an AST expression and produce a flat instruction list.
/// `sources` must stay alive for the lifetime of the returned `CompiledExpr`
/// — text literals point into the arena, column refs are pre-resolved.
pub fn compileExpr(expr: *ast.Expr, sources: []const Source, arena: std.mem.Allocator) SqlError!CompiledExpr {
    var c = CompileCtx{ .arena = arena, .sources = sources };
    _ = try c.compileNode(expr);
    return CompiledExpr{
        .instrs = try c.instrs.toOwnedSlice(arena),
        .ints = try c.ints.toOwnedSlice(arena),
        .texts = try c.texts.toOwnedSlice(arena),
        .cols = try c.cols.toOwnedSlice(arena),
    };
}

const CompileCtx = struct {
    arena: std.mem.Allocator,
    sources: []const Source,
    instrs: std.ArrayList(Instr) = .empty,
    ints: std.ArrayList(i64) = .empty,
    texts: std.ArrayList([]const u8) = .empty,
    cols: std.ArrayList(ResolvedColumn) = .empty,

    fn addInstr(c: *CompileCtx, op: InstrOp, a: u16, b: u16) !void {
        try c.instrs.append(c.arena, .{ .op = op, .a = a, .b = b });
    }

    fn pushInt(c: *CompileCtx, v: i64) !void {
        const idx: u16 = @intCast(c.ints.items.len);
        try c.ints.append(c.arena, v);
        try c.addInstr(.push_int, idx, 0);
    }

    fn pushText(c: *CompileCtx, v: []const u8) !void {
        const idx: u16 = @intCast(c.texts.items.len);
        try c.texts.append(c.arena, v);
        try c.addInstr(.push_text, idx, 0);
    }

    fn pushCol(c: *CompileCtx, col: ResolvedColumn) !void {
        const idx: u16 = @intCast(c.cols.items.len);
        try c.cols.append(c.arena, col);
        try c.addInstr(.push_col, idx, 0);
    }

    fn compileNode(c: *CompileCtx, expr: *ast.Expr) SqlError!void {
        switch (expr.*) {
            .literal => |lit| switch (lit) {
                .null => try c.addInstr(.push_null, 0, 0),
                .integer => |v| try c.pushInt(v),
                .text => |v| try c.pushText(v),
            },
            .column => |col| {
                const src = try resolveColumnSource(c.sources, col);
                const info = c.sources[src].info;
                const ci = columnIndex(info, col.name) orelse return error.ColumnNotFound;
                const ipk = if (info.integer_primary_key_index) |ipk_idx| ci == ipk_idx else false;
                try c.pushCol(.{ .source_index = @intCast(src), .column_index = @intCast(ci), .ipk = ipk });
            },
            .binary => |bin| {
                // Short-circuit AND/OR: compile both sides, emit logical op.
                // (At eval time, AND/OR assume both operands are already
                // isTruthy ints on the stack.)
                if (bin.op == .and_ or bin.op == .or_) {
                    try c.compileNode(bin.lhs);
                    try c.compileNode(bin.rhs);
                    try c.addInstr(if (bin.op == .and_) .and_ else .or_, 0, 0);
                    return;
                }
                // IS NULL / IS NOT NULL
                if (bin.op == .is_null) {
                    try c.compileNode(bin.lhs);
                    try c.addInstr(.is_null, 0, 0);
                    return;
                }
                if (bin.op == .is_not_null) {
                    try c.compileNode(bin.lhs);
                    try c.addInstr(.is_not_null, 0, 0);
                    return;
                }
                try c.compileNode(bin.lhs);
                try c.compileNode(bin.rhs);
                try c.addInstr(binOpToInstr(bin.op), 0, 0);
            },
            .unary => |u| {
                try c.compileNode(u.operand);
                try c.addInstr(switch (u.op) {
                    .not_ => .not_,
                    .neg => .neg,
                    else => return error.UnsupportedSql,
                }, 0, 0);
            },
            .in_list => |il| {
                // Compile to a sequence: push value, push each item, compare.
                // The VM evaluates this as a chain of eq checks followed by
                // logical ORs.
                try c.compileNode(il.value);
                for (il.items) |it| {
                    try c.compileNode(il.value); // re-evaluate anchor
                    try c.compileNode(it);
                    try c.addInstr(.eq, 0, 0);
                    try c.addInstr(.or_, 0, 0);
                }
                if (il.negated) try c.addInstr(.not_, 0, 0);
            },
            .between => |bt| {
                // Compile: (value >= low) AND (value <= high)
                try c.compileNode(bt.value);
                try c.compileNode(bt.low);
                try c.addInstr(.ge, 0, 0);
                try c.compileNode(bt.value);
                try c.compileNode(bt.high);
                try c.addInstr(.le, 0, 0);
                try c.addInstr(.and_, 0, 0);
                if (bt.negated) try c.addInstr(.not_, 0, 0);
            },
        }
    }
};

fn binOpToInstr(op: ast.BinOp) InstrOp {
    return switch (op) {
        .eq => .eq,
        .ne => .ne,
        .lt => .lt,
        .le => .le,
        .gt => .gt,
        .ge => .ge,
        .add => .add,
        .sub => .sub,
        .mul => .mul,
        .div => .div,
        .mod => .mod,
        .concat => .concat,
        .like => .like,
        .not_like => .not_like,
        else => unreachable,
    };
}

/// Search `tuple` for the row from `source_index`.
fn getRowForSource(tuple: []const SourcedRow, source_index: u8) ?table.Row {
    for (tuple) |sr| if (sr.source_index == source_index) return sr.row;
    return null;
}

/// Evaluate a pre-compiled expression against one row tuple (one SourcedRow
/// per source). Returns a `record.Value` — for predicates, callers then
/// coerce to isTruthy/falsy. Uses a fixed 16-slot stack (covers nearly every
/// real-world WHERE clause) with arena fallback for pathological cases.
pub fn evalCompiled(compiled: *const CompiledExpr, tuple: []const SourcedRow, scratch: std.mem.Allocator) SqlError!record.Value {
    var stack_buf: [16]record.Value = undefined;
    var sp: usize = 0;
    // Fallback for expressions that need >16 stack slots.
    const fallback: []record.Value = if (compiled.instrs.len > 50)
        try scratch.alloc(record.Value, compiled.instrs.len)
    else
        &.{};
    defer if (fallback.len > 0) scratch.free(fallback);

    const stack: []record.Value = if (fallback.len > 0) fallback else stack_buf[0..];

    for (compiled.instrs) |instr| {
        switch (instr.op) {
            .push_null => vmPush(stack, &sp, .null),
            .push_int => vmPush(stack, &sp, .{ .integer = compiled.ints[instr.a] }),
            .push_text => vmPush(stack, &sp, .{ .text = compiled.texts[instr.a] }),
            .push_col => {
                const rc = compiled.cols[instr.a];
                const row = getRowForSource(tuple, rc.source_index) orelse {
                    vmPush(stack, &sp, .null);
                    continue;
                };
                if (rc.ipk) {
                    vmPush(stack, &sp, .{ .integer = row.rowid });
                    continue;
                }
                const v: record.Value = if (rc.column_index < row.values.len)
                    row.values[rc.column_index]
                else
                    .null;
                vmPush(stack, &sp, v);
            },
            .eq, .ne, .lt, .le, .gt, .ge => {
                sp -= 2;
                const a = stack[sp];
                const b = stack[sp + 1];
                stack[sp] = switch (instr.op) {
                    .eq => intVal(compareValues(a, b, .eq)),
                    .ne => intVal(compareValues(a, b, .ne)),
                    .lt => intVal(compareValues(a, b, .lt)),
                    .le => intVal(compareValues(a, b, .le)),
                    .gt => intVal(compareValues(a, b, .gt)),
                    .ge => intVal(compareValues(a, b, .ge)),
                    else => unreachable,
                };
                sp += 1;
            },
            .add, .sub, .mul, .div, .mod => {
                sp -= 2;
                stack[sp] = evalArith(stack[sp], stack[sp + 1], arithInstrToBinOp(instr.op)) catch .null;
                sp += 1;
            },
            .concat => {
                sp -= 2;
                stack[sp] = evalConcat(stack[sp], stack[sp + 1], scratch) catch .null;
                sp += 1;
            },
            .like => {
                sp -= 2;
                stack[sp] = intVal(evalLike(stack[sp], stack[sp + 1]));
                sp += 1;
            },
            .not_like => {
                sp -= 2;
                stack[sp] = intVal(!evalLike(stack[sp], stack[sp + 1]));
                sp += 1;
            },
            .and_ => {
                sp -= 2;
                const l = isTruthy(stack[sp]);
                const r = isTruthy(stack[sp + 1]);
                stack[sp] = intVal(l and r);
                sp += 1;
            },
            .or_ => {
                sp -= 2;
                const l = isTruthy(stack[sp]);
                const r = isTruthy(stack[sp + 1]);
                stack[sp] = intVal(l or r);
                sp += 1;
            },
            .not_ => {
                const t = !isTruthy(stack[sp - 1]);
                stack[sp - 1] = intVal(t);
            },
            .is_null => {
                stack[sp - 1] = intVal(stack[sp - 1] == .null);
            },
            .is_not_null => {
                stack[sp - 1] = intVal(stack[sp - 1] != .null);
            },
            .neg => {
                switch (stack[sp - 1]) {
                    .integer => |x| stack[sp - 1] = .{ .integer = -x },
                    .real => |x| stack[sp - 1] = .{ .real = -x },
                    else => stack[sp - 1] = .null,
                }
            },
        }
    }
    return if (sp > 0) stack[sp - 1] else .null;
}

fn arithInstrToBinOp(op: InstrOp) ast.BinOp {
    return switch (op) {
        .add => .add,
        .sub => .sub,
        .mul => .mul,
        .div => .div,
        .mod => .mod,
        else => unreachable,
    };
}

inline fn vmPush(buf: []record.Value, sp: *usize, v: record.Value) void {
    const s = sp.*;
    if (s < buf.len) buf[s] = v else @panic("stack overflow");
    sp.* = s + 1;
}

inline fn intVal(b: bool) record.Value {
    return .{ .integer = if (b) 1 else 0 };
}

inline fn isTruthy(v: record.Value) bool {
    return switch (v) {
        .null => false,
        .integer => |x| x != 0,
        .real => |x| x != 0.0,
        .text => |x| x.len != 0,
        .blob => |x| x.len != 0,
    };
}

fn sortTuples(tuples: [][]SourcedRow, src_idx: usize, col_idx: usize, descending: bool, sources: []const Source) void {
    const ctx = SortContext{
        .src_idx = src_idx,
        .col_idx = col_idx,
        .descending = descending,
        .sources = sources,
    };
    std.mem.sort([]SourcedRow, tuples, ctx, SortContext.lessThan);
}

const SortContext = struct {
    src_idx: usize,
    col_idx: usize,
    descending: bool,
    sources: []const Source,

    fn lessThan(ctx: SortContext, a: []SourcedRow, b: []SourcedRow) bool {
        const va = valueAt(ctx, a);
        const vb = valueAt(ctx, b);
        const less = compareValues(va, vb, .lt);
        return if (ctx.descending) compareValues(va, vb, .gt) else less;
    }

    fn valueAt(ctx: SortContext, tuple: []SourcedRow) record.Value {
        for (tuple) |sr| if (sr.source_index == ctx.src_idx) {
            const r = sr.row;
            var v: record.Value = if (ctx.col_idx < r.values.len) r.values[ctx.col_idx] else .null;
            const info = ctx.sources[ctx.src_idx].info;
            if (info.integer_primary_key_index) |ipk| {
                if (ctx.col_idx == ipk and v == .null) v = .{ .integer = r.rowid };
            }
            return v;
        };
        return .null;
    }
};

fn buildResultColumns(
    allocator: std.mem.Allocator,
    projections: []const ast.Projection,
    sources: []const Source,
) SqlError![]ResultColumn {
    var out: std.ArrayList(ResultColumn) = .empty;
    errdefer out.deinit(allocator);

    for (projections) |p| {
        switch (p) {
            .star => {
                for (sources) |s| {
                    for (s.info.columns) |c| try out.append(allocator, .{ .name = c.name });
                }
            },
            .table_star => |qname| {
                const src_i = blk: {
                    for (sources, 0..) |s, i| if (s.matches(qname)) break :blk i;
                    return error.TableNotFound;
                };
                for (sources[src_i].info.columns) |c| try out.append(allocator, .{ .name = c.name });
            },
            .column => |col| {
                const name = col.alias orelse col.ref.name;
                try out.append(allocator, .{ .name = name });
            },
            .count_star => |cs| {
                try out.append(allocator, .{ .name = cs.alias orelse "COUNT(*)" });
            },
            .aggregate => |ag| {
                if (ag.alias) |a| {
                    try out.append(allocator, .{ .name = a });
                } else {
                    const label = switch (ag.func) {
                        .count => "COUNT",
                        .sum => "SUM",
                        .min => "MIN",
                        .max => "MAX",
                        .avg => "AVG",
                    };
                    try out.append(allocator, .{ .name = label });
                }
            },
            .expr => |e| try out.append(allocator, .{ .name = e.alias orelse "expr" }),
        }
    }
    return try out.toOwnedSlice(allocator);
}

/// Fold `filtered` into a single result row by computing each
/// aggregate projection across the rows.
fn reduceAggregates(
    allocator: std.mem.Allocator,
    projections: []const ast.Projection,
    sources: []const Source,
    filtered: []const []SourcedRow,
    columns: []const ResultColumn,
    scratch: std.mem.Allocator,
) SqlError![]ResultCell {
    _ = scratch;
    const values = try allocator.alloc(ResultCell, columns.len);
    errdefer allocator.free(values);

    for (projections, 0..) |p, i| {
        switch (p) {
            .count_star => values[i] = .{ .name = columns[i].name, .value = .{ .integer = @intCast(filtered.len) } },
            .star, .table_star, .column, .expr => unreachable,
            .aggregate => |ag| {
                const src_idx = try resolveColumnSource(sources, ag.column);
                const col_idx = columnIndex(sources[src_idx].info, ag.column.name) orelse return error.ColumnNotFound;
                var count: i64 = 0;
                var sum: f64 = 0;
                var any_real = false;
                var sum_int: i64 = 0;
                var min_v: ?record.Value = null;
                var max_v: ?record.Value = null;
                for (filtered) |tuple| {
                    var r: ?table.Row = null;
                    for (tuple) |sr| if (sr.source_index == src_idx) {
                        r = sr.row;
                        break;
                    };
                    const row = r orelse continue;
                    var v: record.Value = if (col_idx < row.values.len) row.values[col_idx] else .null;
                    if (sources[src_idx].info.integer_primary_key_index) |ipk| {
                        if (col_idx == ipk and v == .null) v = .{ .integer = row.rowid };
                    }
                    if (v == .null) continue;
                    count += 1;
                    switch (ag.func) {
                        .sum, .avg => switch (v) {
                            .integer => |x| {
                                if (!any_real) {
                                    sum_int +%= x;
                                }
                                sum += @floatFromInt(x);
                            },
                            .real => |x| {
                                any_real = true;
                                sum += x;
                            },
                            else => {},
                        },
                        .min => {
                            if (min_v == null or compareValues(v, min_v.?, .lt)) min_v = v;
                        },
                        .max => {
                            if (max_v == null or compareValues(v, max_v.?, .gt)) max_v = v;
                        },
                        .count => {},
                    }
                }
                const out_value: record.Value = switch (ag.func) {
                    .count => .{ .integer = count },
                    .sum => if (count == 0) .null else if (any_real) .{ .real = sum } else .{ .integer = sum_int },
                    .avg => if (count == 0) .null else .{ .real = sum / @as(f64, @floatFromInt(count)) },
                    .min => min_v orelse .null,
                    .max => max_v orelse .null,
                };
                // For text MIN/MAX we need to dupe the value since
                // the result row owns its buffers.
                values[i] = .{
                    .name = columns[i].name,
                    .value = try dupValue(allocator, out_value),
                };
            },
        }
    }
    return values;
}

fn projectTuple(
    allocator: std.mem.Allocator,
    projections: []const ast.Projection,
    sources: []const Source,
    tuple: []const SourcedRow,
    columns: []const ResultColumn,
    scratch: std.mem.Allocator,
) SqlError![]ResultCell {
    var out: std.ArrayList(ResultCell) = .empty;
    errdefer {
        for (out.items) |c| switch (c.value) {
            .text => |t| allocator.free(t),
            .blob => |b| allocator.free(b),
            else => {},
        };
        out.deinit(allocator);
    }
    try out.ensureTotalCapacity(allocator, columns.len);

    for (projections) |p| {
        switch (p) {
            .star => {
                for (sources, 0..) |s, src_i| {
                    // Find this source's row in the tuple (may be missing for a join miss).
                    var maybe_row: ?table.Row = null;
                    for (tuple) |sr| if (sr.source_index == src_i) {
                        maybe_row = sr.row;
                        break;
                    };
                    for (s.info.columns, 0..) |c, idx| {
                        var v: record.Value = .null;
                        if (maybe_row) |row| {
                            v = if (idx < row.values.len) row.values[idx] else .null;
                            if (s.info.integer_primary_key_index) |ipk| {
                                if (idx == ipk and v == .null) v = .{ .integer = row.rowid };
                            }
                        }
                        try out.append(allocator, .{ .name = c.name, .value = try dupValue(allocator, v) });
                    }
                }
            },
            .table_star => |qname| {
                const src_i = blk: {
                    for (sources, 0..) |s, i| if (s.matches(qname)) break :blk i;
                    return error.TableNotFound;
                };
                var maybe_row: ?table.Row = null;
                for (tuple) |sr| if (sr.source_index == src_i) {
                    maybe_row = sr.row;
                    break;
                };
                for (sources[src_i].info.columns, 0..) |c, idx| {
                    var v: record.Value = .null;
                    if (maybe_row) |row| {
                        v = if (idx < row.values.len) row.values[idx] else .null;
                        if (sources[src_i].info.integer_primary_key_index) |ipk| {
                            if (idx == ipk and v == .null) v = .{ .integer = row.rowid };
                        }
                    }
                    try out.append(allocator, .{ .name = c.name, .value = try dupValue(allocator, v) });
                }
            },
            .column => |col| {
                const v = try evalColumn(sources, tuple, col.ref);
                const label = col.alias orelse col.ref.name;
                try out.append(allocator, .{ .name = label, .value = try dupValue(allocator, v) });
            },
            .expr => |e| {
                const v = try evalExpr(e.expr, sources, tuple, scratch);
                const label = e.alias orelse "expr";
                try out.append(allocator, .{ .name = label, .value = try dupValue(allocator, v) });
            },
            .count_star, .aggregate => {
                // Aggregates never flow through projectTuple — they're
                // reduced up-front via `reduceAggregates`.
                unreachable;
            },
        }
    }
    return try out.toOwnedSlice(allocator);
}

fn projectionsAreSimpleSingleSource(projections: []const ast.Projection) bool {
    for (projections) |p| switch (p) {
        .star, .table_star, .column => {},
        else => return false,
    };
    return true;
}

fn projectSingleSourceRow(
    allocator: std.mem.Allocator,
    projections: []const ast.Projection,
    source: Source,
    rowid: i64,
    values: []const record.Value,
    columns: []const ResultColumn,
) SqlError![]ResultCell {
    const out = try allocator.alloc(ResultCell, columns.len);
    errdefer allocator.free(out);
    _ = try fillSingleSourceRowCells(allocator, projections, source, rowid, values, columns, out);
    return out;
}

fn fillSingleSourceRowCells(
    allocator: std.mem.Allocator,
    projections: []const ast.Projection,
    source: Source,
    rowid: i64,
    values: []const record.Value,
    columns: []const ResultColumn,
    out: []ResultCell,
) SqlError!bool {
    if (out.len != columns.len) return error.InvalidSelect;

    var out_idx: usize = 0;
    var initialized: usize = 0;
    var has_owned_payloads = false;
    errdefer freeResultCellPayloads(out[0..initialized], allocator);

    for (projections) |p| switch (p) {
        .star => {
            for (source.info.columns, 0..) |c, idx| {
                if (out_idx >= out.len) return error.InvalidSelect;
                const v = rowColumnValue(source.info, rowid, values, idx);
                const v_owned = try dupValue(allocator, v);
                switch (v_owned) {
                    .text, .blob => has_owned_payloads = true,
                    else => {},
                }
                out[out_idx] = .{ .name = c.name, .value = v_owned };
                out_idx += 1;
                initialized = out_idx;
            }
        },
        .table_star => |qname| {
            if (!source.matches(qname)) return error.TableNotFound;
            for (source.info.columns, 0..) |c, idx| {
                if (out_idx >= out.len) return error.InvalidSelect;
                const v = rowColumnValue(source.info, rowid, values, idx);
                const v_owned = try dupValue(allocator, v);
                switch (v_owned) {
                    .text, .blob => has_owned_payloads = true,
                    else => {},
                }
                out[out_idx] = .{ .name = c.name, .value = v_owned };
                out_idx += 1;
                initialized = out_idx;
            }
        },
        .column => |col| {
            if (col.ref.qualifier) |q| {
                if (!source.matches(q)) return error.ColumnNotFound;
            }
            if (out_idx >= out.len) return error.InvalidSelect;
            const v = if (asciiEql(col.ref.name, "rowid"))
                record.Value{ .integer = rowid }
            else blk: {
                const idx = columnIndex(source.info, col.ref.name) orelse return error.ColumnNotFound;
                break :blk rowColumnValue(source.info, rowid, values, idx);
            };
            const label = col.alias orelse col.ref.name;
            const v_owned = try dupValue(allocator, v);
            switch (v_owned) {
                .text, .blob => has_owned_payloads = true,
                else => {},
            }
            out[out_idx] = .{ .name = label, .value = v_owned };
            out_idx += 1;
            initialized = out_idx;
        },
        .expr, .count_star, .aggregate => unreachable,
    };

    if (out_idx != out.len) return error.InvalidSelect;
    return has_owned_payloads;
}

fn rowColumnValue(info: catalog.TableInfo, rowid: i64, values: []const record.Value, idx: usize) record.Value {
    var v: record.Value = if (idx < values.len) values[idx] else .null;
    if (info.integer_primary_key_index) |ipk| {
        if (idx == ipk and v == .null) v = .{ .integer = rowid };
    }
    return v;
}

fn dupValue(allocator: std.mem.Allocator, v: record.Value) !record.Value {
    return switch (v) {
        .text => |t| .{ .text = try allocator.dupe(u8, t) },
        .blob => |b| .{ .blob = try allocator.dupe(u8, b) },
        else => v,
    };
}

fn freeValue(allocator: std.mem.Allocator, v: record.Value) void {
    switch (v) {
        .text => |t| allocator.free(t),
        .blob => |b| allocator.free(b),
        else => {},
    }
}

/// Extract `col = literal` (or `col = literal`'s mirror) from an
/// expression tree. Returns null if the expression isn't shaped like
/// a single column-to-literal equality at the top level.
fn asIndexableEq(expr: *ast.Expr) ?struct { column_name: []const u8, value: Literal } {
    if (expr.* != .binary) return null;
    const b = expr.binary;
    if (b.op != .eq) return null;
    if (b.lhs.* == .column and b.rhs.* == .literal) {
        if (b.lhs.column.qualifier != null) return null;
        return .{ .column_name = b.lhs.column.name, .value = b.rhs.literal };
    }
    if (b.lhs.* == .literal and b.rhs.* == .column) {
        if (b.rhs.column.qualifier != null) return null;
        return .{ .column_name = b.rhs.column.name, .value = b.lhs.literal };
    }
    return null;
}

/// Extract `rowid = N` from an expression tree.
fn asSimpleRowidEq(expr: *ast.Expr) ?i64 {
    const ie = asIndexableEq(expr) orelse return null;
    if (!asciiEql(ie.column_name, "rowid")) return null;
    return switch (ie.value) {
        .integer => |v| v,
        else => null,
    };
}

/// Recognise `col <op> literal` (or its mirror) where `op` is one of
/// `=`, `<`, `<=`, `>`, `>=`. Returns the column name, op, and literal.
fn asColumnLiteralCmp(expr: *ast.Expr) ?struct {
    column_name: []const u8,
    op: ast.BinOp,
    value: Literal,
} {
    if (expr.* != .binary) return null;
    const b = expr.binary;
    const op = switch (b.op) {
        .eq, .lt, .le, .gt, .ge => b.op,
        else => return null,
    };
    if (b.lhs.* == .column and b.rhs.* == .literal) {
        if (b.lhs.column.qualifier != null) return null;
        return .{ .column_name = b.lhs.column.name, .op = op, .value = b.rhs.literal };
    }
    if (b.lhs.* == .literal and b.rhs.* == .column) {
        if (b.rhs.column.qualifier != null) return null;
        const flipped: ast.BinOp = switch (op) {
            .eq => .eq,
            .lt => .gt,
            .le => .ge,
            .gt => .lt,
            .ge => .le,
            else => unreachable,
        };
        return .{ .column_name = b.rhs.column.name, .op = flipped, .value = b.lhs.literal };
    }
    return null;
}

fn literalToLookup(lit: Literal) index_mod.LookupValue {
    return switch (lit) {
        .null => .null,
        .integer => |v| .{ .integer = v },
        .text => |v| .{ .text = v },
    };
}

const IndexableRange = struct {
    column_name: []const u8,
    low: index_mod.IndexBound,
    high: index_mod.IndexBound,
};

/// Recognise predicates of the form `col [op] lit`, `col BETWEEN a AND
/// b`, or two such comparisons AND-ed together (`col >= a AND col < b`).
/// Returns the column and the resulting low/high bounds, or null if
/// the shape doesn't fit.
fn asIndexableRange(expr: *ast.Expr) ?IndexableRange {
    if (expr.* == .between) {
        const bt = expr.between;
        if (bt.negated) return null;
        if (bt.value.* != .column or bt.value.column.qualifier != null) return null;
        if (bt.low.* != .literal or bt.high.* != .literal) return null;
        return .{
            .column_name = bt.value.column.name,
            .low = .{ .inclusive = literalToLookup(bt.low.literal) },
            .high = .{ .inclusive = literalToLookup(bt.high.literal) },
        };
    }

    if (asColumnLiteralCmp(expr)) |c| {
        const lookup = literalToLookup(c.value);
        return switch (c.op) {
            .eq => .{ .column_name = c.column_name, .low = .{ .inclusive = lookup }, .high = .{ .inclusive = lookup } },
            .lt => .{ .column_name = c.column_name, .low = .none, .high = .{ .exclusive = lookup } },
            .le => .{ .column_name = c.column_name, .low = .none, .high = .{ .inclusive = lookup } },
            .gt => .{ .column_name = c.column_name, .low = .{ .exclusive = lookup }, .high = .none },
            .ge => .{ .column_name = c.column_name, .low = .{ .inclusive = lookup }, .high = .none },
            else => null,
        };
    }

    if (expr.* == .binary and expr.binary.op == .and_) {
        const left = asIndexableRange(expr.binary.lhs) orelse return null;
        const right = asIndexableRange(expr.binary.rhs) orelse return null;
        if (!asciiEql(left.column_name, right.column_name)) return null;
        // Take the tighter of each side.
        const merged_low = mergeLow(left.low, right.low);
        const merged_high = mergeHigh(left.high, right.high);
        return .{ .column_name = left.column_name, .low = merged_low, .high = merged_high };
    }

    return null;
}

fn boundValue(b: index_mod.IndexBound) ?index_mod.LookupValue {
    return switch (b) {
        .none => null,
        .inclusive, .exclusive => |v| v,
    };
}

fn lookupCmp(a: index_mod.LookupValue, b: index_mod.LookupValue) ?std.math.Order {
    return switch (a) {
        .integer => |ai| switch (b) {
            .integer => |bi| std.math.order(ai, bi),
            else => null,
        },
        .text => |at| switch (b) {
            .text => |bt| std.mem.order(u8, at, bt),
            else => null,
        },
        .null => switch (b) {
            .null => .eq,
            else => null,
        },
    };
}

fn mergeLow(a: index_mod.IndexBound, b: index_mod.IndexBound) index_mod.IndexBound {
    const av = boundValue(a) orelse return b;
    const bv = boundValue(b) orelse return a;
    const cmp = lookupCmp(av, bv) orelse return a;
    if (cmp == .lt) return b;
    if (cmp == .gt) return a;
    // Equal values; pick the stricter (exclusive) form.
    return if (a == .exclusive or b == .exclusive) .{ .exclusive = av } else .{ .inclusive = av };
}

fn mergeHigh(a: index_mod.IndexBound, b: index_mod.IndexBound) index_mod.IndexBound {
    const av = boundValue(a) orelse return b;
    const bv = boundValue(b) orelse return a;
    const cmp = lookupCmp(av, bv) orelse return a;
    if (cmp == .gt) return b;
    if (cmp == .lt) return a;
    return if (a == .exclusive or b == .exclusive) .{ .exclusive = av } else .{ .inclusive = av };
}

const IndexableIn = struct {
    column_name: []const u8,
    items: []Literal,
};

/// Recognise `col IN (lit, lit, ...)` (non-negated). Returns the column
/// and the literal list. The returned slice is allocated in `allocator`.
fn asIndexableIn(expr: *ast.Expr, allocator: std.mem.Allocator) SqlError!?IndexableIn {
    if (expr.* != .in_list) return null;
    const il = expr.in_list;
    if (il.negated) return null;
    if (il.value.* != .column or il.value.column.qualifier != null) return null;
    if (il.items.len == 0) return null;
    const items = try allocator.alloc(Literal, il.items.len);
    for (il.items, 0..) |it, i| {
        if (it.* != .literal) return null;
        items[i] = it.literal;
    }
    return IndexableIn{ .column_name = il.value.column.name, .items = items };
}

/// Resolve a range predicate to a sorted list of rowids by walking the
/// index. Returns null when no usable index exists for the column.
pub fn indexedRowidsForRange(
    reader: page.PageReader,
    db_schema: schema.Schema,
    info: catalog.TableInfo,
    range: IndexableRange,
    limit: ?usize,
    allocator: std.mem.Allocator,
) SqlError!?[]i64 {
    if (asciiEql(range.column_name, "rowid")) return null;
    const index_entry = findIndexForColumn(db_schema, info, range.column_name) orelse return null;
    return try index_mod.rowidsForFirstColumnRange(
        reader,
        @intCast(index_entry.root_page),
        range.low,
        range.high,
        limit,
        allocator,
    );
}

const CoveringValueSource = enum {
    rowid,
    first_indexed_value,
};

const max_covering_slab_rows = 100_000;

/// Attempt a covering-index scan. Returns null when the query shape
/// or projection list isn't covered by an available index. When this
/// path fires we serve the entire result from index entries and never
/// touch the table b-tree.
///
/// The covered shapes are: every projection is either `rowid` (or the
/// integer primary key column) or the first indexed column; the WHERE
/// clause is either absent or a range/equality/IN-list over that same
/// indexed column; the ORDER BY (if any) is on the indexed column or
/// rowid (rowid order is implicit only when WHERE collapses to a
/// single value of the indexed column).
fn tryCoveringIndexScan(
    reader: page.PageReader,
    db_schema: schema.Schema,
    info: catalog.TableInfo,
    stmt: SelectStatement,
    sources: []const Source,
    allocator: std.mem.Allocator,
    ascratch: std.mem.Allocator,
) SqlError!?QueryResult {
    if (stmt.joins.len != 0) return null;
    if (stmt.projections.len == 0) return null;

    // Pull a candidate indexed column out of WHERE (eq/range/IN) or
    // ORDER BY. All branches must agree on the same column.
    var indexed_col: ?[]const u8 = null;
    var range_pred: ?IndexableRange = null;
    var in_pred: ?IndexableIn = null;

    if (stmt.where_expr) |w| {
        if (asIndexableRange(w)) |r| {
            indexed_col = r.column_name;
            range_pred = r;
        } else if (try asIndexableIn(w, ascratch)) |il| {
            indexed_col = il.column_name;
            in_pred = il;
        } else return null;
    }

    var descending = false;
    if (stmt.order_by) |ob| {
        if (ob.column.qualifier != null and !sources[0].matches(ob.column.qualifier.?)) return null;
        if (asciiEql(ob.column.name, "rowid")) {
            // ASC rowid only is natural — we'd need to re-sort the
            // index walk by rowid otherwise. Bail out for non-natural
            // orderings.
            if (ob.descending) return null;
            // Rowid ordering only safe if WHERE is equality on the
            // indexed col (so all rowids are within one index bucket
            // and come out in ascending order from the index).
            if (range_pred) |rp| {
                if (!isEqualityRange(rp)) return null;
            } else if (in_pred != null) {
                return null;
            }
        } else {
            if (indexed_col) |c| {
                if (!asciiEql(c, ob.column.name)) return null;
            } else {
                indexed_col = ob.column.name;
            }
            if (in_pred != null) return null; // IN can't satisfy an order-by without a sort.
            descending = ob.descending;
        }
    }

    const col_name = indexed_col orelse return null;
    if (asciiEql(col_name, "rowid")) return null;

    const index_entry = findIndexForColumn(db_schema, info, col_name) orelse return null;
    const ipk_col_name: ?[]const u8 = if (info.integer_primary_key_index) |ipk| info.columns[ipk].name else null;

    // Verify every projection is rowid or the indexed column, and compile
    // that into a tiny source map so emit() does no name matching per row.
    const value_sources = try ascratch.alloc(CoveringValueSource, stmt.projections.len);
    for (stmt.projections, 0..) |p, i| {
        switch (p) {
            .column => |col| {
                if (col.ref.qualifier != null and !sources[0].matches(col.ref.qualifier.?)) return null;
                const name = col.ref.name;
                if (asciiEql(name, "rowid")) {
                    value_sources[i] = .rowid;
                    continue;
                }
                if (ipk_col_name) |pk| {
                    if (asciiEql(name, pk)) {
                        value_sources[i] = .rowid;
                        continue;
                    }
                }
                if (asciiEql(name, col_name)) {
                    value_sources[i] = .first_indexed_value;
                    continue;
                }
                return null;
            },
            else => return null,
        }
    }

    const limit_n: usize = if (stmt.limit) |l|
        (if (l > 0) @as(usize, @intCast(l)) else return null)
    else
        std.math.maxInt(usize);

    const columns = try buildResultColumns(allocator, stmt.projections, sources);
    errdefer allocator.free(columns);

    var cell_slab: ?[]ResultCell = null;
    errdefer if (cell_slab) |slab| allocator.free(slab);

    var rows: std.ArrayList(ResultRow) = .empty;
    errdefer {
        for (rows.items) |r| {
            freeResultCellPayloads(r.values, allocator);
            if (r.values_owned) allocator.free(r.values);
        }
        rows.deinit(allocator);
    }

    if (limit_n != std.math.maxInt(usize) and limit_n <= max_covering_slab_rows) {
        if (stmt.projections.len > std.math.maxInt(usize) / limit_n) return error.OutOfMemory;
        const cell_count = limit_n * stmt.projections.len;
        cell_slab = try allocator.alloc(ResultCell, cell_count);
        try rows.ensureTotalCapacity(allocator, limit_n);
    }

    const Collector = struct {
        allocator: std.mem.Allocator,
        rows: *std.ArrayList(ResultRow),
        value_sources: []const CoveringValueSource,
        columns: []const ResultColumn,
        cell_slab: ?[]ResultCell,
        cell_slab_used: usize,
        has_owned_payloads: bool,
        limit: usize,
        emitted: usize,
        stop_after: bool,
        oom: bool,

        fn emit(self: *@This(), entry: index_mod.IndexEntryView) index_mod.IndexError!void {
            if (self.emitted >= self.limit) {
                self.stop_after = true;
                return;
            }
            const slab_start = self.cell_slab_used;
            const out: []ResultCell = if (self.cell_slab) |slab| blk: {
                const end = slab_start + self.value_sources.len;
                if (end > slab.len) {
                    self.stop_after = true;
                    return;
                }
                self.cell_slab_used = end;
                break :blk slab[slab_start..end];
            } else self.allocator.alloc(ResultCell, self.value_sources.len) catch {
                self.oom = true;
                self.stop_after = true;
                return error.OutOfMemory;
            };
            var initialized: usize = 0;
            errdefer {
                freeResultCellPayloads(out[0..initialized], self.allocator);
                if (self.cell_slab == null) {
                    self.allocator.free(out);
                } else {
                    self.cell_slab_used = slab_start;
                }
            }
            for (self.value_sources, 0..) |source, i| {
                const v_src: record.Value = switch (source) {
                    .rowid => .{ .integer = entry.rowid },
                    .first_indexed_value => entry.first_value,
                };
                const v_owned = dupValue(self.allocator, v_src) catch {
                    self.oom = true;
                    self.stop_after = true;
                    return error.OutOfMemory;
                };
                switch (v_owned) {
                    .text, .blob => self.has_owned_payloads = true,
                    else => {},
                }
                out[i] = .{ .name = self.columns[i].name, .value = v_owned };
                initialized += 1;
            }
            self.rows.append(self.allocator, .{ .rowid = entry.rowid, .values = out, .values_owned = self.cell_slab == null }) catch {
                self.oom = true;
                self.stop_after = true;
                return error.OutOfMemory;
            };
            self.emitted += 1;
            if (self.emitted >= self.limit) self.stop_after = true;
        }
    };

    var collector: Collector = .{
        .allocator = allocator,
        .rows = &rows,
        .value_sources = value_sources,
        .columns = columns,
        .cell_slab = cell_slab,
        .cell_slab_used = 0,
        .has_owned_payloads = false,
        .limit = limit_n,
        .emitted = 0,
        .stop_after = false,
        .oom = false,
    };

    const root_page: u32 = @intCast(index_entry.root_page);

    if (in_pred) |ip| {
        for (ip.items) |lit| {
            if (collector.stop_after) break;
            const lookup = literalToLookup(lit);
            try index_mod.walkIndexFirstColumnRange(
                reader,
                root_page,
                .{ .low = .{ .inclusive = lookup }, .high = .{ .inclusive = lookup } },
                ascratch,
                &collector,
                Collector.emit,
            );
        }
    } else {
        const low: index_mod.IndexBound = if (range_pred) |rp| rp.low else .none;
        const high: index_mod.IndexBound = if (range_pred) |rp| rp.high else .none;
        try index_mod.walkIndexFirstColumnRange(
            reader,
            root_page,
            .{ .low = low, .high = high, .reverse = descending },
            ascratch,
            &collector,
            Collector.emit,
        );
    }

    if (collector.oom) return error.OutOfMemory;

    return .{
        .columns = columns,
        .table_info = try cloneTableInfo(allocator, info),
        .rows = try rows.toOwnedSlice(allocator),
        .cell_slab = cell_slab,
        .values_have_owned_payloads = if (cell_slab != null) collector.has_owned_payloads else true,
    };
}

fn isEqualityRange(r: IndexableRange) bool {
    const lv = boundValue(r.low) orelse return false;
    const hv = boundValue(r.high) orelse return false;
    if (r.low != .inclusive or r.high != .inclusive) return false;
    const cmp = lookupCmp(lv, hv) orelse return false;
    return cmp == .eq;
}

/// Walk an index b-tree in ascending or descending first-column order
/// and collect at most `limit` rowids. Used for indexed
/// `ORDER BY indexed_col [DESC] LIMIT N` plans.
pub fn collectIndexOrderedRowids(
    reader: page.PageReader,
    root_page: u32,
    low: index_mod.IndexBound,
    high: index_mod.IndexBound,
    descending: bool,
    limit: usize,
    allocator: std.mem.Allocator,
) SqlError![]i64 {
    const Collector = struct {
        list: std.ArrayList(i64),
        allocator: std.mem.Allocator,
        limit: usize,
        stop_after: bool,

        fn append(self: *@This(), entry: index_mod.IndexEntryView) index_mod.IndexError!void {
            try self.list.append(self.allocator, entry.rowid);
            if (self.list.items.len >= self.limit) self.stop_after = true;
        }
    };
    var collector: Collector = .{
        .list = .empty,
        .allocator = allocator,
        .limit = limit,
        .stop_after = false,
    };
    errdefer collector.list.deinit(allocator);
    try index_mod.walkIndexFirstColumnRange(
        reader,
        root_page,
        .{ .low = low, .high = high, .reverse = descending },
        allocator,
        &collector,
        Collector.append,
    );
    return try collector.list.toOwnedSlice(allocator);
}

/// Resolve `col IN (...)` to a deduplicated rowid list, in input order.
pub fn indexedRowidsForIn(
    reader: page.PageReader,
    db_schema: schema.Schema,
    info: catalog.TableInfo,
    in_pred: IndexableIn,
    limit: ?usize,
    allocator: std.mem.Allocator,
) SqlError!?[]i64 {
    if (asciiEql(in_pred.column_name, "rowid")) return null;
    const index_entry = findIndexForColumn(db_schema, info, in_pred.column_name) orelse return null;
    var out: std.ArrayList(i64) = .empty;
    errdefer out.deinit(allocator);
    for (in_pred.items) |lit| {
        const lookup = literalToLookup(lit);
        const rids = try index_mod.rowidsForFirstColumnEquals(reader, @intCast(index_entry.root_page), lookup, allocator);
        defer allocator.free(rids);
        for (rids) |rid| {
            try out.append(allocator, rid);
            if (limit) |lim| if (out.items.len >= lim) {
                return try out.toOwnedSlice(allocator);
            };
        }
    }
    return try out.toOwnedSlice(allocator);
}

fn isNaturalRowidAscOrder(order_by: ast.OrderBy, source: Source) bool {
    if (order_by.descending) return false;
    if (order_by.column.qualifier) |q| {
        if (!source.matches(q)) return false;
    }
    if (asciiEql(order_by.column.name, "rowid")) return true;
    const idx = columnIndex(source.info, order_by.column.name) orelse return false;
    return if (source.info.integer_primary_key_index) |ipk| idx == ipk else false;
}

/// Single-table SELECT fast-path planner: takes a direct rowid or a
/// pre-computed rowid list (from an index lookup), fetches matching
/// rows, projects them. Transient allocs go to `ascratch`; only the
/// `QueryResult` shell + result rows escape via `allocator`.
fn buildFromSingleTable(
    reader: page.PageReader,
    db_schema: schema.Schema,
    stmt: SelectStatement,
    sources: []const Source,
    sources_list: *std.ArrayList(Source),
    info: catalog.TableInfo,
    direct_rowid: ?i64,
    indexed_rowids: ?[]i64,
    allocator: std.mem.Allocator,
    ascratch: std.mem.Allocator,
) SqlError!QueryResult {
    _ = db_schema;
    _ = sources_list;

    const columns = try buildResultColumns(allocator, stmt.projections, sources);
    errdefer allocator.free(columns);

    var cell_slab: ?[]ResultCell = null;
    errdefer if (cell_slab) |slab| allocator.free(slab);

    var rows: std.ArrayList(ResultRow) = .empty;
    errdefer {
        for (rows.items) |r| r.deinit(allocator);
        rows.deinit(allocator);
    }

    const limit = stmt.limit orelse std.math.maxInt(i64);
    const simple_projection = projectionsAreSimpleSingleSource(stmt.projections);
    var row_mask = record.ProjectionMask.empty();
    var projected_fetch = simple_projection and sources.len == 1;
    if (projected_fetch) projected_fetch = try buildProjectionMaskFromProjections(stmt.projections, sources[0], &row_mask);

    // COUNT(*) path short-circuits enumerating projections per row.
    var has_count = false;
    for (stmt.projections) |p| if (p == .count_star) {
        has_count = true;
        break;
    };
    if (has_count) {
        for (stmt.projections) |p| if (p != .count_star) return error.UnsupportedSql;
        var n: i64 = 0;
        if (direct_rowid) |rid| {
            if (try table.rowidExists(reader, info.root_page, rid)) n = 1;
        } else if (indexed_rowids) |rids| {
            n = @intCast(rids.len);
        }
        const values = try allocator.alloc(ResultCell, columns.len);
        for (values, 0..) |*v, i| v.* = .{ .name = columns[i].name, .value = .{ .integer = n } };
        try rows.append(allocator, .{ .rowid = -1, .values = values });
        return .{
            .columns = columns,
            .table_info = try cloneTableInfo(allocator, info),
            .rows = try rows.toOwnedSlice(allocator),
        };
    }

    var cell_slab_used: usize = 0;
    var slab_has_owned_payloads = false;
    if (simple_projection and columns.len > 0) {
        const row_capacity: usize = if (direct_rowid != null)
            (if (limit > 0) 1 else 0)
        else if (indexed_rowids) |rids|
            (if (limit > 0) @min(rids.len, @as(usize, @intCast(limit))) else 0)
        else
            0;
        if (row_capacity > 0) {
            try rows.ensureTotalCapacity(allocator, row_capacity);
            if (row_capacity <= max_covering_slab_rows) {
                if (columns.len > std.math.maxInt(usize) / row_capacity) return error.OutOfMemory;
                cell_slab = try allocator.alloc(ResultCell, row_capacity * columns.len);
            }
        }
    }

    // Helper: project one backing-table row through the projection list.
    const pushRow = struct {
        fn call(
            out_alloc: std.mem.Allocator,
            scratch_alloc: std.mem.Allocator,
            sources_inner: []const Source,
            stmt_inner: SelectStatement,
            columns_inner: []const ResultColumn,
            simple_projection_inner: bool,
            row: table.Row,
            rows_out: *std.ArrayList(ResultRow),
            cell_slab_inner: ?[]ResultCell,
            cell_slab_used_inner: *usize,
            slab_has_owned_payloads_inner: *bool,
        ) SqlError!void {
            if (simple_projection_inner) {
                if (cell_slab_inner) |slab| {
                    const slab_start = cell_slab_used_inner.*;
                    const end = slab_start + columns_inner.len;
                    if (end > slab.len) return error.OutOfMemory;
                    const out = slab[slab_start..end];
                    cell_slab_used_inner.* = end;
                    var filled = false;
                    errdefer {
                        if (filled) freeResultCellPayloads(out, out_alloc);
                        cell_slab_used_inner.* = slab_start;
                    }
                    const has_owned = try fillSingleSourceRowCells(out_alloc, stmt_inner.projections, sources_inner[0], row.rowid, row.values, columns_inner, out);
                    filled = true;
                    try rows_out.append(out_alloc, .{ .rowid = row.rowid, .values = out, .values_owned = false });
                    if (has_owned) slab_has_owned_payloads_inner.* = true;
                    return;
                }
                const values = try projectSingleSourceRow(out_alloc, stmt_inner.projections, sources_inner[0], row.rowid, row.values, columns_inner);
                errdefer {
                    freeResultCellPayloads(values, out_alloc);
                    out_alloc.free(values);
                }
                try rows_out.append(out_alloc, .{ .rowid = row.rowid, .values = values });
                return;
            }

            var tuple_buf: [1]SourcedRow = .{.{ .source_index = 0, .row = row }};
            const values = try projectTuple(out_alloc, stmt_inner.projections, sources_inner, &tuple_buf, columns_inner, scratch_alloc);
            errdefer {
                freeResultCellPayloads(values, out_alloc);
                out_alloc.free(values);
            }
            try rows_out.append(out_alloc, .{ .rowid = row.rowid, .values = values });
        }
    }.call;

    if (direct_rowid) |rid| {
        if (limit > 0) {
            if (try findRowByRowidMaybeProjected(reader, info.root_page, rid, ascratch, projected_fetch, row_mask)) |found| {
                try pushRow(allocator, ascratch, sources, stmt, columns, simple_projection, found, &rows, cell_slab, &cell_slab_used, &slab_has_owned_payloads);
            }
        }
    } else if (indexed_rowids) |rids| {
        var emitted: i64 = 0;
        for (rids) |rid| {
            if (emitted >= limit) break;
            if (try findRowByRowidMaybeProjected(reader, info.root_page, rid, ascratch, projected_fetch, row_mask)) |found| {
                try pushRow(allocator, ascratch, sources, stmt, columns, simple_projection, found, &rows, cell_slab, &cell_slab_used, &slab_has_owned_payloads);
                emitted += 1;
            }
        }
    }

    return .{
        .columns = columns,
        .table_info = try cloneTableInfo(allocator, info),
        .rows = try rows.toOwnedSlice(allocator),
        .cell_slab = cell_slab,
        .values_have_owned_payloads = if (cell_slab != null) slab_has_owned_payloads else true,
    };
}

fn findRowByRowidMaybeProjected(
    reader: page.PageReader,
    root_page: u32,
    rowid: i64,
    allocator: std.mem.Allocator,
    projected_fetch: bool,
    mask: record.ProjectionMask,
) SqlError!?table.Row {
    return if (projected_fetch)
        try table.findRowByRowidProjected(reader, root_page, rowid, allocator, mask)
    else
        try table.findRowByRowid(reader, root_page, rowid, allocator);
}

fn cloneNamedValues(values: []const catalog.NamedValue, allocator: std.mem.Allocator) SqlError![]catalog.NamedValue {
    const out = try allocator.alloc(catalog.NamedValue, values.len);
    errdefer allocator.free(out);
    var initialized: usize = 0;
    errdefer {
        for (out[0..initialized]) |value| {
            switch (value.value) {
                .text => |text| allocator.free(text),
                .blob => |blob| allocator.free(blob),
                else => {},
            }
        }
    }

    for (values, 0..) |value, i| {
        out[i] = .{
            .name = value.name,
            .value = switch (value.value) {
                .text => |text| .{ .text = try allocator.dupe(u8, text) },
                .blob => |blob| .{ .blob = try allocator.dupe(u8, blob) },
                else => value.value,
            },
        };
        initialized += 1;
    }
    return out;
}

fn freeNamedValues(values: []catalog.NamedValue, allocator: std.mem.Allocator) void {
    for (values) |value| {
        switch (value.value) {
            .text => |text| allocator.free(text),
            .blob => |blob| allocator.free(blob),
            else => {},
        }
    }
    allocator.free(values);
}

pub fn indexedRowids(reader: page.PageReader, db_schema: schema.Schema, info: catalog.TableInfo, where: WhereClause, allocator: std.mem.Allocator) SqlError!?[]i64 {
    return try indexedRowidsForColumn(reader, db_schema, info, where.column_name, where.value, allocator);
}

/// Primary variant used by the rich planner: given a raw column name
/// and literal, return the list of rowids whose first index column
/// matches, or `null` if no index is available.
pub fn indexedRowidsForColumn(
    reader: page.PageReader,
    db_schema: schema.Schema,
    info: catalog.TableInfo,
    column_name: []const u8,
    value: Literal,
    allocator: std.mem.Allocator,
) SqlError!?[]i64 {
    if (asciiEql(column_name, "rowid")) return null;
    const index_entry = findIndexForColumn(db_schema, info, column_name) orelse return null;
    const lookup: index_mod.LookupValue = switch (value) {
        .null => .null,
        .integer => |v| .{ .integer = v },
        .text => |v| .{ .text = v },
    };
    return try index_mod.rowidsForFirstColumnEquals(reader, @intCast(index_entry.root_page), lookup, allocator);
}

/// LIMIT-aware variant of `indexedRowidsForColumn`. Stops walking the
/// index b-tree once `limit` rowids have been collected, which keeps
/// `WHERE col = ? LIMIT 1` from materialising every matching rowid in
/// large index buckets.
pub fn indexedRowidsForColumnWithLimit(
    reader: page.PageReader,
    db_schema: schema.Schema,
    info: catalog.TableInfo,
    column_name: []const u8,
    value: Literal,
    limit: usize,
    allocator: std.mem.Allocator,
) SqlError!?[]i64 {
    if (asciiEql(column_name, "rowid")) return null;
    const index_entry = findIndexForColumn(db_schema, info, column_name) orelse return null;
    const lookup: index_mod.LookupValue = switch (value) {
        .null => .null,
        .integer => |v| .{ .integer = v },
        .text => |v| .{ .text = v },
    };
    return try index_mod.rowidsForFirstColumnEqualsLimit(reader, @intCast(index_entry.root_page), lookup, limit, allocator);
}

pub fn indexedCountForColumn(
    reader: page.PageReader,
    db_schema: schema.Schema,
    info: catalog.TableInfo,
    column_name: []const u8,
    value: Literal,
    allocator: std.mem.Allocator,
) SqlError!?u64 {
    if (asciiEql(column_name, "rowid")) return null;
    const index_entry = findIndexForColumn(db_schema, info, column_name) orelse return null;
    const lookup: index_mod.LookupValue = switch (value) {
        .null => .null,
        .integer => |v| .{ .integer = v },
        .text => |v| .{ .text = v },
    };
    return try index_mod.countEntriesForFirstColumnEquals(reader, @intCast(index_entry.root_page), lookup, allocator);
}

pub fn indexedCountForRange(
    reader: page.PageReader,
    db_schema: schema.Schema,
    info: catalog.TableInfo,
    range: IndexableRange,
    allocator: std.mem.Allocator,
) SqlError!?u64 {
    if (asciiEql(range.column_name, "rowid")) return null;
    const index_entry = findIndexForColumn(db_schema, info, range.column_name) orelse return null;
    return try index_mod.countEntriesForFirstColumnRange(
        reader,
        @intCast(index_entry.root_page),
        range.low,
        range.high,
        allocator,
    );
}

pub fn indexedCountForIn(
    reader: page.PageReader,
    db_schema: schema.Schema,
    info: catalog.TableInfo,
    in_pred: IndexableIn,
    allocator: std.mem.Allocator,
) SqlError!?u64 {
    if (asciiEql(in_pred.column_name, "rowid")) return null;
    const index_entry = findIndexForColumn(db_schema, info, in_pred.column_name) orelse return null;
    var total: u64 = 0;
    for (in_pred.items, 0..) |lit, i| {
        var seen = false;
        for (in_pred.items[0..i]) |prev| {
            if (literalEql(prev, lit)) {
                seen = true;
                break;
            }
        }
        if (seen) continue;
        const n = try index_mod.countEntriesForFirstColumnEquals(reader, @intCast(index_entry.root_page), literalToLookup(lit), allocator);
        total = std.math.add(u64, total, n) catch return error.Overflow;
    }
    return total;
}

fn findIndexForColumn(db_schema: schema.Schema, info: catalog.TableInfo, column_name: []const u8) ?schema.SchemaEntry {
    for (db_schema.entries) |entry| {
        if (!entry.isIndex() or entry.root_page <= 0) continue;
        if (!asciiEql(entry.table_name, info.name)) continue;
        if (entry.sql.len == 0) {
            // Implicit autoindex: SQLite emits `sqlite_autoindex_<table>_<n>`
            // for every UNIQUE / PRIMARY KEY constraint that is NOT an INTEGER
            // PRIMARY KEY (which aliases rowid). For our scope we only match
            // single-column non-integer PRIMARY KEY tables.
            if (!std.mem.startsWith(u8, entry.name, "sqlite_autoindex_")) continue;
            if (info.integer_primary_key_index != null) continue;
            const pk_col = singlePrimaryKeyColumn(db_schema, info.name) orelse continue;
            if (asciiEql(pk_col, column_name)) return entry;
            continue;
        }
        if (containsSqlKeyword(entry.sql, "WHERE")) continue;
        const indexed_column = parseFirstIndexColumn(entry.sql) orelse continue;
        if (asciiEql(indexed_column, column_name)) return entry;
    }
    return null;
}

/// Return the name of the table's lone single-column PRIMARY KEY column,
/// excluding INTEGER PRIMARY KEY (which is the rowid alias and has no
/// implicit autoindex). Returns null if there isn't exactly one matching
/// column or if the table SQL can't be located.
fn singlePrimaryKeyColumn(db_schema: schema.Schema, table_name: []const u8) ?[]const u8 {
    const table_entry = db_schema.findTable(table_name) orelse return null;
    const sql = table_entry.sql;
    if (sql.len == 0) return null;
    const open = std.mem.indexOfScalar(u8, sql, '(') orelse return null;
    const close = findCreateTableClose(sql, open) orelse return null;
    const body = sql[open + 1 .. close];

    var found: ?[]const u8 = null;
    var pos: usize = 0;
    while (pos < body.len) {
        const start = pos;
        pos = findColumnDefEnd(body, pos);
        const part = std.mem.trim(u8, body[start..pos], " \t\r\n");
        if (pos < body.len and body[pos] == ',') pos += 1;
        if (part.len == 0) continue;
        if (startsWithKeywordCi(part, "CONSTRAINT") or
            startsWithKeywordCi(part, "PRIMARY") or
            startsWithKeywordCi(part, "FOREIGN") or
            startsWithKeywordCi(part, "UNIQUE") or
            startsWithKeywordCi(part, "CHECK"))
        {
            // A composite PRIMARY KEY constraint at table level disqualifies
            // a single-column autoindex match.
            if (startsWithKeywordCi(part, "PRIMARY")) return null;
            continue;
        }
        const name = parseColumnNameFromDef(part) orelse continue;
        if (!hasColumnPrimaryKey(part)) continue;
        if (isIntegerAffinity(part)) continue;
        if (found != null) return null;
        found = name;
    }
    return found;
}

fn findCreateTableClose(sql: []const u8, open: usize) ?usize {
    var depth: usize = 0;
    var quote: ?u8 = null;
    var i = open;
    while (i < sql.len) : (i += 1) {
        const c = sql[i];
        if (quote) |q| {
            if (c == q) quote = null;
            continue;
        }
        if (c == '\'' or c == '"' or c == '`') {
            quote = c;
            continue;
        }
        if (c == '(') depth += 1;
        if (c == ')') {
            depth -= 1;
            if (depth == 0) return i;
        }
    }
    return null;
}

fn findColumnDefEnd(body: []const u8, start: usize) usize {
    var depth: usize = 0;
    var quote: ?u8 = null;
    var i = start;
    while (i < body.len) : (i += 1) {
        const c = body[i];
        if (quote) |q| {
            if (c == q) quote = null;
            continue;
        }
        if (c == '\'' or c == '"' or c == '`') {
            quote = c;
            continue;
        }
        if (c == '(') depth += 1;
        if (c == ')' and depth > 0) depth -= 1;
        if (c == ',' and depth == 0) return i;
    }
    return body.len;
}

fn parseColumnNameFromDef(def: []const u8) ?[]const u8 {
    if (def.len == 0) return null;
    if (def[0] == '"' or def[0] == '`' or def[0] == '[') {
        const close: u8 = if (def[0] == '[') ']' else def[0];
        const end = std.mem.indexOfScalarPos(u8, def, 1, close) orelse return null;
        return def[1..end];
    }
    var end: usize = 0;
    while (end < def.len and !std.ascii.isWhitespace(def[end]) and def[end] != ',') : (end += 1) {}
    if (end == 0) return null;
    return def[0..end];
}

fn hasColumnPrimaryKey(def: []const u8) bool {
    var pos: usize = 0;
    while (pos < def.len) : (pos += 1) {
        if (startsKeywordAtCi(def, pos, "PRIMARY")) {
            var after = pos + "PRIMARY".len;
            while (after < def.len and std.ascii.isWhitespace(def[after])) after += 1;
            if (startsKeywordAtCi(def, after, "KEY")) return true;
        }
    }
    return false;
}

fn isIntegerAffinity(def: []const u8) bool {
    var pos: usize = 0;
    if (pos < def.len and (def[pos] == '"' or def[pos] == '`' or def[pos] == '[')) {
        const close: u8 = if (def[pos] == '[') ']' else def[pos];
        pos += 1;
        while (pos < def.len and def[pos] != close) pos += 1;
        if (pos < def.len) pos += 1;
    } else {
        while (pos < def.len and !std.ascii.isWhitespace(def[pos])) pos += 1;
    }
    while (pos < def.len and std.ascii.isWhitespace(def[pos])) pos += 1;
    const type_start = pos;
    var depth: usize = 0;
    while (pos < def.len) : (pos += 1) {
        const c = def[pos];
        if (c == '(') depth += 1;
        if (c == ')' and depth > 0) depth -= 1;
        if (depth == 0 and (startsKeywordAtCi(def, pos, "PRIMARY") or
            startsKeywordAtCi(def, pos, "NOT") or
            startsKeywordAtCi(def, pos, "NULL") or
            startsKeywordAtCi(def, pos, "DEFAULT") or
            startsKeywordAtCi(def, pos, "COLLATE") or
            startsKeywordAtCi(def, pos, "REFERENCES") or
            startsKeywordAtCi(def, pos, "CHECK") or
            startsKeywordAtCi(def, pos, "UNIQUE"))) break;
    }
    const type_name = std.mem.trim(u8, def[type_start..pos], " \t\r\n");
    var upper_buf: [128]u8 = undefined;
    const len = @min(type_name.len, upper_buf.len);
    for (type_name[0..len], 0..) |c, i| upper_buf[i] = std.ascii.toUpper(c);
    return std.mem.indexOf(u8, upper_buf[0..len], "INT") != null;
}

fn startsWithKeywordCi(bytes: []const u8, keyword: []const u8) bool {
    return startsKeywordAtCi(bytes, 0, keyword);
}

fn startsKeywordAtCi(bytes: []const u8, pos: usize, keyword: []const u8) bool {
    if (pos + keyword.len > bytes.len) return false;
    if (pos > 0 and isIdent(bytes[pos - 1])) return false;
    if (pos + keyword.len < bytes.len and isIdent(bytes[pos + keyword.len])) return false;
    for (keyword, 0..) |c, i| {
        if (std.ascii.toUpper(bytes[pos + i]) != c) return false;
    }
    return true;
}

fn parseFirstIndexColumn(sql: []const u8) ?[]const u8 {
    const open = std.mem.indexOfScalar(u8, sql, '(') orelse return null;
    var pos = open + 1;
    while (pos < sql.len and std.ascii.isWhitespace(sql[pos])) pos += 1;
    if (pos >= sql.len) return null;
    if (sql[pos] == '"' or sql[pos] == '`' or sql[pos] == '[') {
        const close: u8 = if (sql[pos] == '[') ']' else sql[pos];
        pos += 1;
        const start = pos;
        while (pos < sql.len and sql[pos] != close) pos += 1;
        if (pos >= sql.len) return null;
        return sql[start..pos];
    }
    const start = pos;
    while (pos < sql.len and isIdent(sql[pos])) pos += 1;
    if (pos == start) return null;
    return sql[start..pos];
}

fn rowMatches(info: catalog.TableInfo, row: table.Row, where: WhereClause) SqlError!bool {
    if (asciiEql(where.column_name, "rowid")) return literalMatches(.{ .integer = row.rowid }, where.value);
    const idx = columnIndex(info, where.column_name) orelse return error.ColumnNotFound;
    var value: record.Value = if (idx < row.values.len) row.values[idx] else .null;
    if (info.integer_primary_key_index) |ipk| {
        if (idx == ipk and value == .null) value = .{ .integer = row.rowid };
    }
    return literalMatches(value, where.value);
}

pub fn columnIndex(info: catalog.TableInfo, column_name: []const u8) ?usize {
    for (info.columns, 0..) |column, i| {
        if (asciiEql(column.name, column_name)) return i;
    }
    return null;
}

fn literalMatches(value: record.Value, literal: Literal) bool {
    return switch (literal) {
        .null => value == .null,
        .integer => |expected| switch (value) {
            .integer => |actual| actual == expected,
            else => false,
        },
        .text => |expected| switch (value) {
            .text => |actual| std.mem.eql(u8, actual, expected),
            else => false,
        },
    };
}

fn literalEql(a: Literal, b: Literal) bool {
    return switch (a) {
        .null => b == .null,
        .integer => |ai| switch (b) {
            .integer => |bi| ai == bi,
            else => false,
        },
        .text => |at| switch (b) {
            .text => |bt| std.mem.eql(u8, at, bt),
            else => false,
        },
    };
}

fn mapParseError(err: parser_mod.ParseError) SqlError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidSelect, error.InvalidSql => error.InvalidSelect,
        error.UnsupportedWhere => error.UnsupportedWhere,
        else => error.UnsupportedSql,
    };
}

fn asciiEql(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

/// Public wrapper for `main.zig`'s bench-read planner.
pub fn asciiEqlPub(a: []const u8, b: []const u8) bool {
    return asciiEql(a, b);
}

fn containsSqlKeyword(sql: []const u8, keyword: []const u8) bool {
    var pos: usize = 0;
    while (pos < sql.len) : (pos += 1) {
        const before_ok = pos == 0 or !isIdent(sql[pos - 1]);
        if (before_ok and startsWithKeyword(sql[pos..], keyword)) return true;
    }
    return false;
}

fn startsWithKeyword(text: []const u8, keyword: []const u8) bool {
    if (text.len < keyword.len) return false;
    if (text.len > keyword.len and isIdent(text[keyword.len])) return false;
    for (keyword, 0..) |c, i| {
        if (std.ascii.toUpper(text[i]) != c) return false;
    }
    return true;
}

fn isIdent(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

const testing = std.testing;

fn skipIfNoSqlite() !void {
    const result = std.process.run(testing.allocator, testing.io, .{
        .argv = &.{ "sqlite3", "-version" },
    }) catch return error.SkipZigTest;
    defer testing.allocator.free(result.stdout);
    defer testing.allocator.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) return error.SkipZigTest;
}

fn buildSqliteFixture(db_path: []const u8, schema_sql: []const u8) !void {
    const result = try std.process.run(testing.allocator, testing.io, .{
        .argv = &.{ "sqlite3", db_path, schema_sql },
    });
    defer testing.allocator.free(result.stdout);
    defer testing.allocator.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) return error.SqliteFixtureFailed;
}

fn tmpDbPath(allocator: std.mem.Allocator, tmp: testing.TmpDir, name: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/{s}", .{ tmp.sub_path, name });
}

test "parse indexed column from create index" {
    try std.testing.expectEqualStrings("name", parseFirstIndexColumn("CREATE INDEX idx_users_name ON users(name)").?);
    try std.testing.expectEqualStrings("user name", parseFirstIndexColumn("CREATE INDEX idx ON users(\"user name\")").?);
}

test "covering index scan uses scalar slab for bounded integer output" {
    try skipIfNoSqlite();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const db_path = try tmpDbPath(testing.allocator, tmp, "covering-int.db");
    defer testing.allocator.free(db_path);

    try buildSqliteFixture(db_path,
        \\CREATE TABLE t(id INTEGER PRIMARY KEY, year INTEGER, name TEXT);
        \\CREATE INDEX idx_t_year ON t(year);
        \\INSERT INTO t(id, year, name) VALUES
        \\  (1, 2020, 'a'),
        \\  (2, 2021, 'b'),
        \\  (3, 2022, 'c'),
        \\  (4, 2023, 'd');
    );

    const bytes = try std.Io.Dir.cwd().readFileAlloc(testing.io, db_path, testing.allocator, .limited(1024 * 1024));
    defer testing.allocator.free(bytes);
    const reader = try page.PageReader.init(bytes);
    const db_schema = try schema.readSchema(reader, testing.allocator);
    defer db_schema.deinit(testing.allocator);

    const result = try executeSelect(reader, db_schema, "SELECT id, year FROM t WHERE year BETWEEN 2020 AND 2022 LIMIT 3", testing.allocator);
    defer result.deinit(testing.allocator);

    try testing.expect(result.cell_slab != null);
    try testing.expect(!result.values_have_owned_payloads);
    try testing.expectEqual(@as(usize, 3), result.rows.len);
    try testing.expect(!result.rows[0].values_owned);
    try testing.expectEqual(@as(i64, 1), result.rows[0].values[0].value.integer);
    try testing.expectEqual(@as(i64, 2020), result.rows[0].values[1].value.integer);
    try testing.expectEqual(@as(i64, 3), result.rows[2].values[0].value.integer);
    try testing.expectEqual(@as(i64, 2022), result.rows[2].values[1].value.integer);
}

test "covering index scan slab frees duplicated text payloads" {
    try skipIfNoSqlite();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const db_path = try tmpDbPath(testing.allocator, tmp, "covering-text.db");
    defer testing.allocator.free(db_path);

    try buildSqliteFixture(db_path,
        \\CREATE TABLE people(id INTEGER PRIMARY KEY, speaker TEXT, body TEXT);
        \\CREATE INDEX idx_people_speaker ON people(speaker);
        \\INSERT INTO people(id, speaker, body) VALUES
        \\  (1, 'Alice', 'first'),
        \\  (2, 'Alice', 'second'),
        \\  (3, 'Bob', 'third');
    );

    const bytes = try std.Io.Dir.cwd().readFileAlloc(testing.io, db_path, testing.allocator, .limited(1024 * 1024));
    defer testing.allocator.free(bytes);
    const reader = try page.PageReader.init(bytes);
    const db_schema = try schema.readSchema(reader, testing.allocator);
    defer db_schema.deinit(testing.allocator);

    const result = try executeSelect(reader, db_schema, "SELECT speaker FROM people WHERE speaker = 'Alice' LIMIT 2", testing.allocator);
    defer result.deinit(testing.allocator);

    try testing.expect(result.cell_slab != null);
    try testing.expect(result.values_have_owned_payloads);
    try testing.expectEqual(@as(usize, 2), result.rows.len);
    try testing.expect(!result.rows[0].values_owned);
    try testing.expectEqualStrings("Alice", result.rows[0].values[0].value.text);
    try testing.expectEqualStrings("Alice", result.rows[1].values[0].value.text);
}

test "hydrated indexed scan reuses scalar result slab" {
    try skipIfNoSqlite();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const db_path = try tmpDbPath(testing.allocator, tmp, "hydrated-slab.db");
    defer testing.allocator.free(db_path);

    try buildSqliteFixture(db_path,
        \\CREATE TABLE t(id INTEGER PRIMARY KEY, year INTEGER, rank INTEGER, name TEXT);
        \\CREATE INDEX idx_t_year ON t(year);
        \\INSERT INTO t(id, year, rank, name) VALUES
        \\  (1, 2020, 10, 'a'),
        \\  (2, 2021, 20, 'b'),
        \\  (3, 2022, 30, 'c'),
        \\  (4, 2023, 40, 'd');
    );

    const bytes = try std.Io.Dir.cwd().readFileAlloc(testing.io, db_path, testing.allocator, .limited(1024 * 1024));
    defer testing.allocator.free(bytes);
    const reader = try page.PageReader.init(bytes);
    const db_schema = try schema.readSchema(reader, testing.allocator);
    defer db_schema.deinit(testing.allocator);

    const result = try executeSelect(reader, db_schema, "SELECT id, year, rank FROM t WHERE year BETWEEN 2020 AND 2022 LIMIT 3", testing.allocator);
    defer result.deinit(testing.allocator);

    try testing.expect(result.cell_slab != null);
    try testing.expect(!result.values_have_owned_payloads);
    try testing.expectEqual(@as(usize, 3), result.rows.len);
    try testing.expect(!result.rows[0].values_owned);
    try testing.expectEqual(@as(i64, 1), result.rows[0].values[0].value.integer);
    try testing.expectEqual(@as(i64, 2020), result.rows[0].values[1].value.integer);
    try testing.expectEqual(@as(i64, 10), result.rows[0].values[2].value.integer);
    try testing.expectEqual(@as(i64, 3), result.rows[2].values[0].value.integer);
    try testing.expectEqual(@as(i64, 2022), result.rows[2].values[1].value.integer);
    try testing.expectEqual(@as(i64, 30), result.rows[2].values[2].value.integer);

    const text_result = try executeSelect(reader, db_schema, "SELECT id, year, name FROM t WHERE year BETWEEN 2020 AND 2021 LIMIT 2", testing.allocator);
    defer text_result.deinit(testing.allocator);

    try testing.expect(text_result.cell_slab != null);
    try testing.expect(text_result.values_have_owned_payloads);
    try testing.expectEqual(@as(usize, 2), text_result.rows.len);
    try testing.expect(!text_result.rows[0].values_owned);
    try testing.expectEqualStrings("a", text_result.rows[0].values[2].value.text);
    try testing.expectEqualStrings("b", text_result.rows[1].values[2].value.text);
}

test "filtered count uses indexed range and in-list counts" {
    try skipIfNoSqlite();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const db_path = try tmpDbPath(testing.allocator, tmp, "count-indexed.db");
    defer testing.allocator.free(db_path);

    try buildSqliteFixture(db_path,
        \\CREATE TABLE t(id INTEGER PRIMARY KEY, year INTEGER, name TEXT);
        \\CREATE INDEX idx_t_year ON t(year);
        \\INSERT INTO t(id, year, name) VALUES
        \\  (1, 2019, 'a'),
        \\  (2, 2020, 'b'),
        \\  (3, 2021, 'c'),
        \\  (4, 2021, 'd'),
        \\  (5, 2022, 'e'),
        \\  (6, 2023, 'f');
    );

    const bytes = try std.Io.Dir.cwd().readFileAlloc(testing.io, db_path, testing.allocator, .limited(1024 * 1024));
    defer testing.allocator.free(bytes);
    const reader = try page.PageReader.init(bytes);
    const db_schema = try schema.readSchema(reader, testing.allocator);
    defer db_schema.deinit(testing.allocator);

    const range_result = try executeSelect(reader, db_schema, "SELECT COUNT(*) FROM t WHERE year BETWEEN 2020 AND 2022", testing.allocator);
    defer range_result.deinit(testing.allocator);
    try testing.expectEqual(@as(i64, 4), range_result.rows[0].values[0].value.integer);

    const in_result = try executeSelect(reader, db_schema, "SELECT COUNT(*) FROM t WHERE year IN (2020, 2021, 2021, 2024)", testing.allocator);
    defer in_result.deinit(testing.allocator);
    try testing.expectEqual(@as(i64, 3), in_result.rows[0].values[0].value.integer);
}

test "prepared select can execute repeatedly without reparsing" {
    try skipIfNoSqlite();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const db_path = try tmpDbPath(testing.allocator, tmp, "prepared-select.db");
    defer testing.allocator.free(db_path);

    try buildSqliteFixture(db_path,
        \\CREATE TABLE t(id INTEGER PRIMARY KEY, year INTEGER, name TEXT);
        \\CREATE INDEX idx_t_year ON t(year);
        \\INSERT INTO t(id, year, name) VALUES
        \\  (1, 2020, 'a'),
        \\  (2, 2021, 'b'),
        \\  (3, 2022, 'c');
    );

    const bytes = try std.Io.Dir.cwd().readFileAlloc(testing.io, db_path, testing.allocator, .limited(1024 * 1024));
    defer testing.allocator.free(bytes);
    const reader = try page.PageReader.init(bytes);
    const db_schema = try schema.readSchema(reader, testing.allocator);
    defer db_schema.deinit(testing.allocator);

    var prepared = try prepareSelectForSchema(db_schema, "SELECT MAX(year) FROM t", testing.allocator);
    defer prepared.deinit();

    const first = try executePreparedSelect(reader, db_schema, &prepared, testing.allocator);
    defer first.deinit(testing.allocator);
    const second = try executePreparedSelect(reader, db_schema, &prepared, testing.allocator);
    defer second.deinit(testing.allocator);

    try testing.expectEqual(@as(i64, 2022), first.rows[0].values[0].value.integer);
    try testing.expectEqual(@as(i64, 2022), second.rows[0].values[0].value.integer);
}

test "findIndexForColumn skips partial indexes" {
    var entries = [_]schema.SchemaEntry{
        .{
            .rowid = 1,
            .object_type = "index",
            .name = "idx_partial",
            .table_name = "users",
            .root_page = 3,
            .sql = "CREATE INDEX idx_partial ON users(name) WHERE active = 1",
        },
        .{
            .rowid = 2,
            .object_type = "index",
            .name = "idx_name",
            .table_name = "users",
            .root_page = 4,
            .sql = "CREATE INDEX idx_name ON users(name)",
        },
    };
    const db_schema = schema.Schema{ .entries = entries[0..] };
    var columns = [_]catalog.Column{
        .{ .name = "id", .affinity = .integer, .is_integer_primary_key = true },
        .{ .name = "name", .affinity = .text },
    };
    const info = catalog.TableInfo{
        .name = "users",
        .root_page = 2,
        .columns = columns[0..],
        .integer_primary_key_index = 0,
    };
    const entry = findIndexForColumn(db_schema, info, "name").?;
    try std.testing.expectEqualStrings("idx_name", entry.name);
}

test "findIndexForColumn matches sqlite_autoindex for TEXT PRIMARY KEY" {
    var entries = [_]schema.SchemaEntry{
        .{
            .rowid = 1,
            .object_type = "table",
            .name = "judgments",
            .table_name = "judgments",
            .root_page = 2,
            .sql = "CREATE TABLE judgments (citation TEXT PRIMARY KEY, court TEXT)",
        },
        .{
            .rowid = 2,
            .object_type = "index",
            .name = "sqlite_autoindex_judgments_1",
            .table_name = "judgments",
            .root_page = 5,
            .sql = "",
        },
    };
    const db_schema = schema.Schema{ .entries = entries[0..] };
    var columns = [_]catalog.Column{
        .{ .name = "citation", .affinity = .text },
        .{ .name = "court", .affinity = .text },
    };
    const info = catalog.TableInfo{
        .name = "judgments",
        .root_page = 2,
        .columns = columns[0..],
        .integer_primary_key_index = null,
    };
    const entry = findIndexForColumn(db_schema, info, "citation").?;
    try std.testing.expectEqualStrings("sqlite_autoindex_judgments_1", entry.name);
    try std.testing.expectEqual(@as(?schema.SchemaEntry, null), findIndexForColumn(db_schema, info, "court"));
}

test "findIndexForColumn skips autoindex for INTEGER PRIMARY KEY tables" {
    var entries = [_]schema.SchemaEntry{
        .{
            .rowid = 1,
            .object_type = "table",
            .name = "users",
            .table_name = "users",
            .root_page = 2,
            .sql = "CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)",
        },
        .{
            .rowid = 2,
            .object_type = "index",
            .name = "sqlite_autoindex_users_1",
            .table_name = "users",
            .root_page = 5,
            .sql = "",
        },
    };
    const db_schema = schema.Schema{ .entries = entries[0..] };
    var columns = [_]catalog.Column{
        .{ .name = "id", .affinity = .integer, .is_integer_primary_key = true },
        .{ .name = "name", .affinity = .text },
    };
    const info = catalog.TableInfo{
        .name = "users",
        .root_page = 2,
        .columns = columns[0..],
        .integer_primary_key_index = 0,
    };
    try std.testing.expectEqual(@as(?schema.SchemaEntry, null), findIndexForColumn(db_schema, info, "id"));
}

test "natural rowid order recognizes rowid and integer primary key asc" {
    var columns = [_]catalog.Column{
        .{ .name = "id", .affinity = .integer, .is_integer_primary_key = true },
        .{ .name = "name", .affinity = .text },
    };
    const source = Source{
        .info = .{
            .name = "users",
            .root_page = 2,
            .columns = columns[0..],
            .integer_primary_key_index = 0,
        },
        .alias = "u",
    };

    try std.testing.expect(isNaturalRowidAscOrder(.{
        .column = .{ .qualifier = null, .name = "rowid" },
        .descending = false,
    }, source));
    try std.testing.expect(isNaturalRowidAscOrder(.{
        .column = .{ .qualifier = "u", .name = "id" },
        .descending = false,
    }, source));
    try std.testing.expect(!isNaturalRowidAscOrder(.{
        .column = .{ .qualifier = "other", .name = "id" },
        .descending = false,
    }, source));
    try std.testing.expect(!isNaturalRowidAscOrder(.{
        .column = .{ .qualifier = null, .name = "id" },
        .descending = true,
    }, source));
}
