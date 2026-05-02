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

    pub fn deinit(self: ResultRow, allocator: std.mem.Allocator) void {
        for (self.values) |value| {
            switch (value.value) {
                .text => |text| allocator.free(text),
                .blob => |blob| allocator.free(blob),
                else => {},
            }
        }
        allocator.free(self.values);
    }
};

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

    pub fn deinit(self: QueryResult, allocator: std.mem.Allocator) void {
        for (self.rows) |row| row.deinit(allocator);
        allocator.free(self.rows);
        allocator.free(self.columns);
        self.table_info.deinit(allocator);
    }
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

pub fn executeSelect(reader: page.PageReader, db_schema: schema.Schema, sql: []const u8, allocator: std.mem.Allocator) SqlError!QueryResult {
    const stmt = try parseSelect(sql, allocator);
    defer stmt.deinit(allocator);

    // Query-scoped arena for any transient strings produced by
    // evaluation (concat results, LIKE patterns materialised from
    // non-text values, etc.). Freed in bulk when this function
    // returns.
    var query_arena = std.heap.ArenaAllocator.init(allocator);
    defer query_arena.deinit();
    const qscratch = query_arena.allocator();

    // --- Resolve every FROM / JOIN table into a Source list. The
    // primary (first) source also gets preserved on QueryResult.table_info
    // so the CLI has a default "table header" to print. ---
    var sources: std.ArrayList(Source) = .empty;
    errdefer {
        for (sources.items) |s| s.info.deinit(allocator);
        sources.deinit(allocator);
    }

    const primary_entry = db_schema.findTable(stmt.table_name) orelse return error.TableNotFound;
    const primary_info = try catalog.tableInfo(primary_entry, allocator);
    try sources.append(allocator, .{ .info = primary_info, .alias = stmt.table_alias });

    for (stmt.joins) |j| {
        const jentry = db_schema.findTable(j.table_name) orelse return error.TableNotFound;
        const jinfo = try catalog.tableInfo(jentry, allocator);
        try sources.append(allocator, .{ .info = jinfo, .alias = j.alias });
    }

    // The fast path only handles COUNT(*) among aggregates; if the
    // query mentions SUM/MIN/MAX/AVG/COUNT(col) fall through to the
    // general scan so reduceAggregates can do the math.
    var has_non_count_agg = false;
    for (stmt.projections) |p| if (p == .aggregate) {
        has_non_count_agg = true;
        break;
    };

    // --- Fast path: single-table, WHERE is either `rowid = N` or an
    // indexed-column equality. The legacy planner already handles
    // these well; fall through to the full scan otherwise. ---
    if (!has_non_count_agg and sources.items.len == 1 and stmt.where_expr != null) {
        if (asSimpleRowidEq(stmt.where_expr.?)) |rid| {
            return try buildFromSingleTable(reader, db_schema, stmt, sources.items, &sources, primary_info, rid, null, allocator);
        }
        if (asIndexableEq(stmt.where_expr.?)) |ieq| {
            const rowids = try indexedRowidsForColumn(reader, db_schema, primary_info, ieq.column_name, ieq.value, allocator);
            if (rowids) |rids| {
                return try buildFromSingleTable(reader, db_schema, stmt, sources.items, &sources, primary_info, null, rids, allocator);
            }
        }
    }

    // --- General path: scan every source once, build cartesian-product
    // rows, filter by WHERE + JOIN ON predicates, project, ORDER BY,
    // LIMIT. Works for any combination of single-table scan, JOIN,
    // WHERE, ORDER BY, LIMIT. ---
    var source_scans: std.ArrayList(table.Table) = .empty;
    errdefer {
        for (source_scans.items) |s| s.deinit(allocator);
        source_scans.deinit(allocator);
    }
    for (sources.items) |src| {
        const scanned = try table.scanTable(reader, src.info.root_page, allocator);
        try source_scans.append(allocator, scanned);
    }
    defer {
        for (source_scans.items) |s| s.deinit(allocator);
        source_scans.deinit(allocator);
    }

    // Build the cartesian product. For the common single-table case
    // this is just the scan rows directly; for INNER JOIN we compose
    // rows from each source and filter by the join's ON predicate
    // incrementally to avoid materialising the full product.
    var tuples: std.ArrayList([]SourcedRow) = .empty;
    errdefer {
        for (tuples.items) |t| allocator.free(t);
        tuples.deinit(allocator);
    }
    try buildTuples(allocator, sources.items, source_scans.items, stmt.joins, &tuples, qscratch);
    defer {
        for (tuples.items) |t| allocator.free(t);
        tuples.deinit(allocator);
    }

    // Apply WHERE.
    var filtered: std.ArrayList([]SourcedRow) = .empty;
    defer filtered.deinit(allocator);
    if (stmt.where_expr) |w| {
        for (tuples.items) |t| {
            if (try evalPredicate(w, sources.items, t, qscratch)) try filtered.append(allocator, t);
        }
    } else {
        for (tuples.items) |t| try filtered.append(allocator, t);
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
        const values = try reduceAggregates(allocator, stmt.projections, sources.items, filtered.items, columns, qscratch);
        try rows.append(allocator, .{ .rowid = -1, .values = values });
    } else {
        const limit = stmt.limit orelse std.math.maxInt(i64);
        var emitted: i64 = 0;
        for (filtered.items) |t| {
            if (emitted >= limit) break;
            emitted += 1;
            const values = try projectTuple(allocator, stmt.projections, sources.items, t, columns, qscratch);
            try rows.append(allocator, .{ .rowid = primaryRowid(t), .values = values });
        }
    }

    // We've already stored `primary_info` in `sources[0]`; transfer
    // ownership to the result and release the remaining sources.
    const out_info = sources.items[0].info;
    for (sources.items[1..]) |s| s.info.deinit(allocator);
    sources.deinit(allocator);

    return .{
        .columns = columns,
        .table_info = out_info,
        .rows = try rows.toOwnedSlice(allocator),
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
                const ok = try evalPredicate(on_expr, sources, combined, scratch);
                if (!ok) {
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
            const truthy = switch (v) {
                .null => false,
                .integer => |x| x != 0,
                .real => |x| x != 0.0,
                .text => |x| x.len != 0,
                .blob => |x| x.len != 0,
            };
            break :blk .{ .integer = if (!truthy) 1 else 0 };
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
/// funnels through `evalExpr` and is coerced to a truthy/falsy value
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
    _ = columns;
    var out: std.ArrayList(ResultCell) = .empty;
    errdefer {
        for (out.items) |c| switch (c.value) {
            .text => |t| allocator.free(t),
            .blob => |b| allocator.free(b),
            else => {},
        };
        out.deinit(allocator);
    }

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

fn dupValue(allocator: std.mem.Allocator, v: record.Value) !record.Value {
    return switch (v) {
        .text => |t| .{ .text = try allocator.dupe(u8, t) },
        .blob => |b| .{ .blob = try allocator.dupe(u8, b) },
        else => v,
    };
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

/// Take ownership of `sources` from the caller and build a single-
/// table `SELECT`'s result either from a direct rowid lookup (when
/// `direct_rowid` is set) or from a pre-computed list of rowids (when
/// `indexed_rowids` is set). The projection / ORDER / LIMIT still
/// come from `stmt`.
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
) SqlError!QueryResult {
    _ = db_schema;
    defer if (indexed_rowids) |rids| allocator.free(rids);

    const columns = try buildResultColumns(allocator, stmt.projections, sources);
    errdefer allocator.free(columns);

    var rows: std.ArrayList(ResultRow) = .empty;
    errdefer {
        for (rows.items) |r| r.deinit(allocator);
        rows.deinit(allocator);
    }

    const limit = stmt.limit orelse std.math.maxInt(i64);

    // Helper to push a single backing-table row through projection.
    const pushRow = struct {
        fn call(
            a: std.mem.Allocator,
            sources_inner: []const Source,
            stmt_inner: SelectStatement,
            row: table.Row,
            rows_out: *std.ArrayList(ResultRow),
        ) SqlError!void {
            const tuple = try a.alloc(SourcedRow, 1);
            defer a.free(tuple);
            tuple[0] = .{ .source_index = 0, .row = row };
            // Fast-path's transient strings from concat/etc. use `a`
            // itself — the query-scope allocator isn't threaded here
            // since the single-table planner pre-dates it. Any
            // allocations leak until the final result deinit, which
            // is fine for the rare LIKE/concat-in-projection case.
            const values = try projectTuple(a, stmt_inner.projections, sources_inner, tuple, &.{}, a);
            try rows_out.append(a, .{ .rowid = row.rowid, .values = values });
        }
    }.call;

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
            if (try table.findRowByRowid(reader, info.root_page, rid, allocator)) |r| {
                n = 1;
                r.deinit(allocator);
            }
        } else if (indexed_rowids) |rids| {
            for (rids) |rid| {
                if (try table.findRowByRowid(reader, info.root_page, rid, allocator)) |r| {
                    n += 1;
                    r.deinit(allocator);
                }
            }
        }
        const values = try allocator.alloc(ResultCell, columns.len);
        for (values, 0..) |*v, i| v.* = .{ .name = columns[i].name, .value = .{ .integer = n } };
        try rows.append(allocator, .{ .rowid = -1, .values = values });

        const out_info = sources_list.items[0].info;
        for (sources_list.items[1..]) |s| s.info.deinit(allocator);
        sources_list.deinit(allocator);
        return .{ .columns = columns, .table_info = out_info, .rows = try rows.toOwnedSlice(allocator) };
    }

    if (direct_rowid) |rid| {
        if (try table.findRowByRowid(reader, info.root_page, rid, allocator)) |found| {
            defer found.deinit(allocator);
            try pushRow(allocator, sources, stmt, found, &rows);
        }
    } else if (indexed_rowids) |rids| {
        var emitted: i64 = 0;
        for (rids) |rid| {
            if (emitted >= limit) break;
            if (try table.findRowByRowid(reader, info.root_page, rid, allocator)) |found| {
                defer found.deinit(allocator);
                try pushRow(allocator, sources, stmt, found, &rows);
                emitted += 1;
            }
        }
    }

    const out_info = sources_list.items[0].info;
    for (sources_list.items[1..]) |s| s.info.deinit(allocator);
    sources_list.deinit(allocator);
    return .{ .columns = columns, .table_info = out_info, .rows = try rows.toOwnedSlice(allocator) };
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
    const index_entry = findIndexForColumn(db_schema, info.name, column_name) orelse return null;
    const scanned = try index_mod.scanIndex(reader, @intCast(index_entry.root_page), allocator);
    defer scanned.deinit(allocator);

    var rowids: std.ArrayList(i64) = .empty;
    errdefer rowids.deinit(allocator);
    for (scanned.entries) |entry| {
        if (entry.values.len < 2) continue;
        if (!literalMatches(entry.values[0], value)) continue;
        if (entry.rowid()) |rowid| try rowids.append(allocator, rowid);
    }
    return try rowids.toOwnedSlice(allocator);
}

fn findIndexForColumn(db_schema: schema.Schema, table_name: []const u8, column_name: []const u8) ?schema.SchemaEntry {
    for (db_schema.entries) |entry| {
        if (!entry.isIndex() or entry.root_page <= 0) continue;
        if (!asciiEql(entry.table_name, table_name)) continue;
        if (entry.sql.len == 0) continue;
        const indexed_column = parseFirstIndexColumn(entry.sql) orelse continue;
        if (asciiEql(indexed_column, column_name)) return entry;
    }
    return null;
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

fn isIdent(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

test "parse indexed column from create index" {
    try std.testing.expectEqualStrings("name", parseFirstIndexColumn("CREATE INDEX idx_users_name ON users(name)").?);
    try std.testing.expectEqualStrings("user name", parseFirstIndexColumn("CREATE INDEX idx ON users(\"user name\")").?);
}

