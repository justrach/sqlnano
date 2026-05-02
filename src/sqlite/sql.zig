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
};

pub const SelectStatement = ast.SelectStatement;
pub const WhereClause = ast.WhereClause;
pub const Literal = ast.Literal;

pub const ResultRow = struct {
    rowid: i64,
    values: []catalog.NamedValue,

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

pub const QueryResult = struct {
    table_info: catalog.TableInfo,
    rows: []ResultRow,

    pub fn deinit(self: QueryResult, allocator: std.mem.Allocator) void {
        for (self.rows) |row| row.deinit(allocator);
        allocator.free(self.rows);
        self.table_info.deinit(allocator);
    }
};

pub fn parseSelect(sql: []const u8) SqlError!SelectStatement {
    return parser_mod.parseSelect(sql) catch |err| return mapParseError(err);
}

pub fn executeSelect(reader: page.PageReader, db_schema: schema.Schema, sql: []const u8, allocator: std.mem.Allocator) SqlError!QueryResult {
    const stmt = try parseSelect(sql);
    const entry = db_schema.findTable(stmt.table_name) orelse return error.TableNotFound;
    var info = try catalog.tableInfo(entry, allocator);
    errdefer info.deinit(allocator);

    const index_rowids = if (stmt.where_clause) |where|
        try indexedRowids(reader, db_schema, info, where, allocator)
    else
        null;
    defer if (index_rowids) |rowids| allocator.free(rowids);

    if (index_rowids) |rowids| {
        return try executeRowidListSelect(reader, info, rowids, allocator);
    }

    if (stmt.where_clause) |where| {
        if (whereRowidEquals(where)) |rowid| {
            return try executeSingleRowidSelect(reader, info, rowid, allocator);
        }
    }

    const scanned = try table.scanTable(reader, info.root_page, allocator);
    defer scanned.deinit(allocator);

    var rows: std.ArrayList(ResultRow) = .empty;
    errdefer {
        for (rows.items) |row| row.deinit(allocator);
        rows.deinit(allocator);
    }

    for (scanned.rows) |row| {
        if (stmt.where_clause) |where| {
            if (!try rowMatches(info, row, where)) continue;
        }
        const projected = try catalog.projectRow(info, row, allocator);
        defer projected.deinit(allocator);
        const owned_values = try cloneNamedValues(projected.values, allocator);
        errdefer freeNamedValues(owned_values, allocator);
        try rows.append(allocator, .{ .rowid = projected.rowid, .values = owned_values });
    }

    return .{ .table_info = info, .rows = try rows.toOwnedSlice(allocator) };
}

fn executeRowidListSelect(reader: page.PageReader, info: catalog.TableInfo, rowids: []const i64, allocator: std.mem.Allocator) SqlError!QueryResult {
    var rows: std.ArrayList(ResultRow) = .empty;
    errdefer {
        for (rows.items) |row| row.deinit(allocator);
        rows.deinit(allocator);
    }

    for (rowids) |rowid| {
        const found = try table.findRowByRowid(reader, info.root_page, rowid, allocator) orelse continue;
        defer found.deinit(allocator);
        const projected = try catalog.projectRow(info, found, allocator);
        defer projected.deinit(allocator);
        const owned_values = try cloneNamedValues(projected.values, allocator);
        errdefer freeNamedValues(owned_values, allocator);
        try rows.append(allocator, .{ .rowid = projected.rowid, .values = owned_values });
    }

    return .{ .table_info = info, .rows = try rows.toOwnedSlice(allocator) };
}

fn executeSingleRowidSelect(reader: page.PageReader, info: catalog.TableInfo, rowid: i64, allocator: std.mem.Allocator) SqlError!QueryResult {
    var rows: std.ArrayList(ResultRow) = .empty;
    errdefer {
        for (rows.items) |row| row.deinit(allocator);
        rows.deinit(allocator);
    }

    if (try table.findRowByRowid(reader, info.root_page, rowid, allocator)) |found| {
        defer found.deinit(allocator);
        const projected = try catalog.projectRow(info, found, allocator);
        defer projected.deinit(allocator);
        const owned_values = try cloneNamedValues(projected.values, allocator);
        errdefer freeNamedValues(owned_values, allocator);
        try rows.append(allocator, .{ .rowid = projected.rowid, .values = owned_values });
    }

    return .{ .table_info = info, .rows = try rows.toOwnedSlice(allocator) };
}

pub fn whereRowidEquals(where: WhereClause) ?i64 {
    if (!asciiEql(where.column_name, "rowid")) return null;
    return switch (where.value) {
        .integer => |rowid| rowid,
        else => null,
    };
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
    if (asciiEql(where.column_name, "rowid")) return null;
    const index_entry = findIndexForColumn(db_schema, info.name, where.column_name) orelse return null;
    const scanned = try index_mod.scanIndex(reader, @intCast(index_entry.root_page), allocator);
    defer scanned.deinit(allocator);

    var rowids: std.ArrayList(i64) = .empty;
    errdefer rowids.deinit(allocator);
    for (scanned.entries) |entry| {
        if (entry.values.len < 2) continue;
        if (!literalMatches(entry.values[0], where.value)) continue;
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

fn isIdent(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

test "parse basic select" {
    const stmt = try parseSelect("SELECT * FROM users WHERE rowid = 1;");
    try std.testing.expectEqualStrings("users", stmt.table_name);
    try std.testing.expectEqualStrings("rowid", stmt.where_clause.?.column_name);
    try std.testing.expectEqual(@as(i64, 1), stmt.where_clause.?.value.integer);
}

test "parse quoted text where" {
    const stmt = try parseSelect("select * from users where name = 'alice'");
    try std.testing.expectEqualStrings("users", stmt.table_name);
    try std.testing.expectEqualStrings("alice", stmt.where_clause.?.value.text);
}

test "parse quoted identifier and comments" {
    const stmt = try parseSelect("-- leading comment\nselect * from [user table] where `name` = 'alice';");
    try std.testing.expectEqualStrings("user table", stmt.table_name);
    try std.testing.expectEqualStrings("name", stmt.where_clause.?.column_name);
}

test "parse indexed column from create index" {
    try std.testing.expectEqualStrings("name", parseFirstIndexColumn("CREATE INDEX idx_users_name ON users(name)").?);
    try std.testing.expectEqualStrings("user name", parseFirstIndexColumn("CREATE INDEX idx ON users(\"user name\")").?);
}

