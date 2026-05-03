const std = @import("std");
const schema = @import("schema.zig");
const record = @import("record.zig");

pub const CatalogError = error{
    OutOfMemory,
    InvalidCreateTableSql,
    UnsupportedColumnType,
};

pub const ColumnAffinity = enum {
    integer,
    text,
    blob,
    real,
    numeric,
};

pub const Column = struct {
    name: []const u8,
    affinity: ColumnAffinity,
    is_integer_primary_key: bool = false,
};

pub const TableInfo = struct {
    name: []const u8,
    root_page: u32,
    columns: []Column,
    integer_primary_key_index: ?usize,

    pub fn deinit(self: TableInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.columns);
    }
};

pub const NamedValue = struct {
    name: []const u8,
    value: record.Value,
};

pub const ProjectedRow = struct {
    rowid: i64,
    values: []NamedValue,

    pub fn deinit(self: ProjectedRow, allocator: std.mem.Allocator) void {
        allocator.free(self.values);
    }
};

pub fn tableInfo(entry: schema.SchemaEntry, allocator: std.mem.Allocator) CatalogError!TableInfo {
    if (!entry.isTable()) return error.InvalidCreateTableSql;
    const columns = try parseCreateTableColumns(entry.sql, allocator);
    errdefer allocator.free(columns);

    var ipk_index: ?usize = null;
    for (columns, 0..) |column, i| {
        if (column.is_integer_primary_key) {
            ipk_index = i;
            break;
        }
    }

    return .{
        .name = entry.name,
        .root_page = @intCast(entry.root_page),
        .columns = columns,
        .integer_primary_key_index = ipk_index,
    };
}

pub fn projectRow(info: TableInfo, row: anytype, allocator: std.mem.Allocator) CatalogError!ProjectedRow {
    const values = try allocator.alloc(NamedValue, info.columns.len);
    errdefer allocator.free(values);

    for (info.columns, 0..) |column, i| {
        var value: record.Value = if (i < row.values.len) row.values[i] else .null;
        if (info.integer_primary_key_index) |ipk| {
            if (i == ipk and value == .null) value = .{ .integer = row.rowid };
        }
        values[i] = .{ .name = column.name, .value = value };
    }

    return .{ .rowid = row.rowid, .values = values };
}

fn parseCreateTableColumns(sql: []const u8, allocator: std.mem.Allocator) CatalogError![]Column {
    const open = std.mem.indexOfScalar(u8, sql, '(') orelse return error.InvalidCreateTableSql;
    const close = findMatchingClose(sql, open) orelse return error.InvalidCreateTableSql;
    const body = sql[open + 1 .. close];

    var columns: std.ArrayList(Column) = .empty;
    errdefer columns.deinit(allocator);

    var pos: usize = 0;
    while (pos < body.len) {
        const start = pos;
        pos = findNextComma(body, pos);
        const part = trimSqlComments(body[start..pos]);
        if (part.len != 0 and !isTableConstraint(part)) {
            try columns.append(allocator, try parseColumn(part));
        }
        if (pos < body.len and body[pos] == ',') pos += 1;
    }

    return columns.toOwnedSlice(allocator);
}

fn parseColumn(def: []const u8) CatalogError!Column {
    var rest = std.mem.trim(u8, def, " \t\r\n");
    const parsed_name = parseIdentifier(rest) orelse return error.InvalidCreateTableSql;
    rest = std.mem.trim(u8, rest[parsed_name.len..], " \t\r\n");

    const type_end = typeNameEnd(rest);
    const type_name = std.mem.trim(u8, rest[0..type_end], " \t\r\n");
    const tail = rest[type_end..];

    const affinity = columnAffinity(type_name);
    const is_ipk = affinity == .integer and containsKeywordPair(tail, "PRIMARY", "KEY");
    return .{ .name = parsed_name.name, .affinity = affinity, .is_integer_primary_key = is_ipk };
}

const ParsedIdentifier = struct { name: []const u8, len: usize };

fn parseIdentifier(bytes: []const u8) ?ParsedIdentifier {
    if (bytes.len == 0) return null;
    if (bytes[0] == '"' or bytes[0] == '`' or bytes[0] == '[') {
        const close: u8 = if (bytes[0] == '[') ']' else bytes[0];
        const end = std.mem.indexOfScalarPos(u8, bytes, 1, close) orelse return null;
        return .{ .name = bytes[1..end], .len = end + 1 };
    }

    var end: usize = 0;
    while (end < bytes.len and !std.ascii.isWhitespace(bytes[end]) and bytes[end] != ',') : (end += 1) {}
    if (end == 0) return null;
    return .{ .name = bytes[0..end], .len = end };
}

fn typeNameEnd(bytes: []const u8) usize {
    var pos: usize = 0;
    var paren_depth: usize = 0;
    while (pos < bytes.len) : (pos += 1) {
        const c = bytes[pos];
        if (c == '(') paren_depth += 1;
        if (c == ')' and paren_depth > 0) paren_depth -= 1;
        if (paren_depth == 0 and startsKeywordAt(bytes, pos, "PRIMARY")) return pos;
        if (paren_depth == 0 and startsKeywordAt(bytes, pos, "NOT")) return pos;
        if (paren_depth == 0 and startsKeywordAt(bytes, pos, "NULL")) return pos;
        if (paren_depth == 0 and startsKeywordAt(bytes, pos, "DEFAULT")) return pos;
        if (paren_depth == 0 and startsKeywordAt(bytes, pos, "COLLATE")) return pos;
        if (paren_depth == 0 and startsKeywordAt(bytes, pos, "REFERENCES")) return pos;
        if (paren_depth == 0 and startsKeywordAt(bytes, pos, "CHECK")) return pos;
        if (paren_depth == 0 and startsKeywordAt(bytes, pos, "UNIQUE")) return pos;
    }
    return pos;
}

fn columnAffinity(type_name: []const u8) ColumnAffinity {
    if (type_name.len == 0) return .blob;
    var upper_buf: [128]u8 = undefined;
    const len = @min(type_name.len, upper_buf.len);
    for (type_name[0..len], 0..) |c, i| upper_buf[i] = std.ascii.toUpper(c);
    const upper = upper_buf[0..len];

    if (std.mem.indexOf(u8, upper, "INT") != null) return .integer;
    if (std.mem.indexOf(u8, upper, "CHAR") != null or std.mem.indexOf(u8, upper, "CLOB") != null or std.mem.indexOf(u8, upper, "TEXT") != null) return .text;
    if (std.mem.indexOf(u8, upper, "BLOB") != null) return .blob;
    if (std.mem.indexOf(u8, upper, "REAL") != null or std.mem.indexOf(u8, upper, "FLOA") != null or std.mem.indexOf(u8, upper, "DOUB") != null) return .real;
    return .numeric;
}

fn isTableConstraint(part: []const u8) bool {
    return startsKeywordAt(part, 0, "CONSTRAINT") or startsKeywordAt(part, 0, "PRIMARY") or startsKeywordAt(part, 0, "FOREIGN") or startsKeywordAt(part, 0, "UNIQUE") or startsKeywordAt(part, 0, "CHECK");
}

fn findMatchingClose(sql: []const u8, open: usize) ?usize {
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

fn findNextComma(bytes: []const u8, start: usize) usize {
    var depth: usize = 0;
    var quote: ?u8 = null;
    var i = start;
    while (i < bytes.len) : (i += 1) {
        const c = bytes[i];
        if (quote) |q| {
            if (c == q) quote = null;
            continue;
        }
        if (c == '-' and i + 1 < bytes.len and bytes[i + 1] == '-') {
            i += 2;
            while (i < bytes.len and bytes[i] != '\n') : (i += 1) {}
            if (i >= bytes.len) return bytes.len;
            continue;
        }
        if (c == '/' and i + 1 < bytes.len and bytes[i + 1] == '*') {
            i += 2;
            while (i + 1 < bytes.len and !(bytes[i] == '*' and bytes[i + 1] == '/')) : (i += 1) {}
            if (i + 1 >= bytes.len) return bytes.len;
            i += 1;
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
    return bytes.len;
}

fn trimSqlComments(bytes: []const u8) []const u8 {
    var rest = std.mem.trim(u8, bytes, " \t\r\n");
    while (true) {
        if (std.mem.startsWith(u8, rest, "--")) {
            const newline = std.mem.indexOfScalar(u8, rest, '\n') orelse return "";
            rest = std.mem.trim(u8, rest[newline + 1 ..], " \t\r\n");
            continue;
        }
        if (std.mem.startsWith(u8, rest, "/*")) {
            const close = std.mem.indexOf(u8, rest, "*/") orelse return "";
            rest = std.mem.trim(u8, rest[close + 2 ..], " \t\r\n");
            continue;
        }
        return rest;
    }
}

fn containsKeywordPair(bytes: []const u8, first: []const u8, second: []const u8) bool {
    var pos: usize = 0;
    while (pos < bytes.len) : (pos += 1) {
        if (startsKeywordAt(bytes, pos, first)) {
            var after = pos + first.len;
            while (after < bytes.len and std.ascii.isWhitespace(bytes[after])) after += 1;
            if (startsKeywordAt(bytes, after, second)) return true;
        }
    }
    return false;
}

fn startsKeywordAt(bytes: []const u8, pos: usize, keyword: []const u8) bool {
    if (pos + keyword.len > bytes.len) return false;
    if (pos > 0 and isIdent(bytes[pos - 1])) return false;
    if (pos + keyword.len < bytes.len and isIdent(bytes[pos + keyword.len])) return false;
    for (keyword, 0..) |c, i| {
        if (std.ascii.toUpper(bytes[pos + i]) != c) return false;
    }
    return true;
}

fn isIdent(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

test "parse create table columns and integer primary key" {
    const entry = schema.SchemaEntry{
        .rowid = 1,
        .object_type = "table",
        .name = "users",
        .table_name = "users",
        .root_page = 2,
        .sql = "CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT, age INTEGER)",
    };
    const info = try tableInfo(entry, std.testing.allocator);
    defer info.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 3), info.columns.len);
    try std.testing.expectEqualStrings("id", info.columns[0].name);
    try std.testing.expectEqual(ColumnAffinity.integer, info.columns[0].affinity);
    try std.testing.expect(info.columns[0].is_integer_primary_key);
    try std.testing.expectEqual(@as(?usize, 0), info.integer_primary_key_index);
}

test "parse create table columns with line comments between definitions" {
    const entry = schema.SchemaEntry{
        .rowid = 1,
        .object_type = "table",
        .name = "judgments",
        .table_name = "judgments",
        .root_page = 2,
        .sql =
        \\CREATE TABLE judgments (
        \\    citation        TEXT PRIMARY KEY,        -- e.g. "2026_SGHC_88"
        \\    neutral_cite    TEXT,                    -- e.g. "[2026] SGHC 88"
        \\    court           TEXT,
        \\    year            INTEGER,
        \\    case_no         TEXT                     -- no trailing comma
        \\)
        ,
    };
    const info = try tableInfo(entry, std.testing.allocator);
    defer info.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 5), info.columns.len);
    try std.testing.expectEqualStrings("citation", info.columns[0].name);
    try std.testing.expectEqualStrings("neutral_cite", info.columns[1].name);
    try std.testing.expectEqualStrings("court", info.columns[2].name);
    try std.testing.expectEqualStrings("year", info.columns[3].name);
    try std.testing.expectEqualStrings("case_no", info.columns[4].name);
}

test "project integer primary key from rowid" {
    const entry = schema.SchemaEntry{
        .rowid = 1,
        .object_type = "table",
        .name = "users",
        .table_name = "users",
        .root_page = 2,
        .sql = "CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)",
    };
    const info = try tableInfo(entry, std.testing.allocator);
    defer info.deinit(std.testing.allocator);

    const vals = [_]record.Value{ .null, .{ .text = "alice" } };
    const row = struct { rowid: i64, values: []const record.Value }{ .rowid = 7, .values = &vals };
    const projected = try projectRow(info, row, std.testing.allocator);
    defer projected.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(i64, 7), projected.values[0].value.integer);
    try std.testing.expectEqualStrings("name", projected.values[1].name);
}
