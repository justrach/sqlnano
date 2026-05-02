const std = @import("std");
const btree = @import("btree.zig");
const page = @import("page.zig");
const record = @import("record.zig");
const varint = @import("varint.zig");

pub const SchemaError = error{
    InvalidSchemaPage,
    InvalidSchemaCell,
    UnsupportedSchemaBTree,
    UnsupportedSchemaRecord,
    OutOfMemory,
    PageOutOfBounds,
    InvalidPageNumber,
    PageTooSmall,
    InvalidPageType,
    InvalidCellIndex,
    CellOffsetOutOfBounds,
    InvalidPageHeader,
    TooSmall,
    Overflow,
    InvalidHeaderSize,
    InvalidSerialType,
    ValueOutOfBounds,
    VarintTooSmall,
    VarintOverflow,
};

pub const SchemaEntry = struct {
    rowid: i64,
    object_type: []const u8,
    name: []const u8,
    table_name: []const u8,
    root_page: i64,
    sql: []const u8,

    pub fn isTable(self: SchemaEntry) bool {
        return std.mem.eql(u8, self.object_type, "table");
    }

    pub fn isIndex(self: SchemaEntry) bool {
        return std.mem.eql(u8, self.object_type, "index");
    }
};

pub const Schema = struct {
    entries: []SchemaEntry,

    pub fn deinit(self: Schema, allocator: std.mem.Allocator) void {
        allocator.free(self.entries);
    }

    pub fn findTable(self: Schema, table_name: []const u8) ?SchemaEntry {
        for (self.entries) |entry| {
            if (entry.isTable() and std.mem.eql(u8, entry.name, table_name)) return entry;
        }
        return null;
    }

    pub fn findIndex(self: Schema, index_name: []const u8) ?SchemaEntry {
        for (self.entries) |entry| {
            if (entry.isIndex() and std.mem.eql(u8, entry.name, index_name)) return entry;
        }
        return null;
    }

    pub fn firstIndexForTable(self: Schema, table_name: []const u8) ?SchemaEntry {
        for (self.entries) |entry| {
            if (entry.isIndex() and std.mem.eql(u8, entry.table_name, table_name) and entry.root_page > 0) return entry;
        }
        return null;
    }

    pub fn indexesForTable(self: Schema, table_name: []const u8) []const SchemaEntry {
        _ = table_name;
        return self.entries;
    }
};

pub fn readSchema(reader: page.PageReader, allocator: std.mem.Allocator) SchemaError!Schema {
    const root = try reader.page(1);
    const root_header = try btree.PageHeader.parse(root);
    if (root_header.page_type != .table_leaf) return error.UnsupportedSchemaBTree;

    var entries: std.ArrayList(SchemaEntry) = .empty;
    errdefer entries.deinit(allocator);

    var i: usize = 0;
    while (i < root_header.cell_count) : (i += 1) {
        const cell = try root_header.cell(root, i);
        const entry = try parseSchemaCell(cell, allocator);
        try entries.append(allocator, entry);
    }

    return .{ .entries = try entries.toOwnedSlice(allocator) };
}

fn parseSchemaCell(cell: []const u8, allocator: std.mem.Allocator) SchemaError!SchemaEntry {
    const payload_size_v = try parseVarint(cell);
    const rowid_v = try parseVarint(cell[payload_size_v.len..]);
    const payload_start = @as(usize, payload_size_v.len) + rowid_v.len;
    const payload_size: usize = @intCast(payload_size_v.value);
    if (payload_start + payload_size > cell.len) return error.InvalidSchemaCell;

    const rec = try record.parse(cell[payload_start .. payload_start + payload_size], allocator);
    defer rec.deinit(allocator);
    if (rec.values.len < 5) return error.UnsupportedSchemaRecord;

    return .{
        .rowid = @intCast(rowid_v.value),
        .object_type = try expectText(rec.values[0]),
        .name = try expectText(rec.values[1]),
        .table_name = try expectText(rec.values[2]),
        .root_page = try expectInteger(rec.values[3]),
        .sql = try expectTextOrEmpty(rec.values[4]),
    };
}

fn expectTextOrEmpty(value: record.Value) SchemaError![]const u8 {
    return switch (value) {
        .text => |text| text,
        .null => "",
        else => error.UnsupportedSchemaRecord,
    };
}

fn expectText(value: record.Value) SchemaError![]const u8 {
    return switch (value) {
        .text => |text| text,
        else => error.UnsupportedSchemaRecord,
    };
}

fn expectInteger(value: record.Value) SchemaError!i64 {
    return switch (value) {
        .integer => |int| int,
        else => error.UnsupportedSchemaRecord,
    };
}

fn parseVarint(bytes: []const u8) SchemaError!varint.Varint {
    return varint.parse(bytes) catch |err| switch (err) {
        error.TooSmall => error.VarintTooSmall,
        error.Overflow => error.VarintOverflow,
    };
}

test "read one sqlite_schema entry from page 1" {
    var bytes = [_]u8{0} ** 4096;
    @memcpy(bytes[0..16], @import("header.zig").MAGIC);
    bytes[16] = 0x10;
    bytes[17] = 0x00;
    bytes[18] = 1;
    bytes[19] = 1;
    bytes[21] = 64;
    bytes[22] = 32;
    bytes[23] = 32;
    bytes[31] = 1;

    const page_base = 100;
    bytes[page_base + 0] = @intFromEnum(btree.PageType.table_leaf);
    bytes[page_base + 3] = 0;
    bytes[page_base + 4] = 1;
    bytes[page_base + 5] = 0x0f;
    bytes[page_base + 6] = 0xd3;
    bytes[page_base + 8] = 0x0f;
    bytes[page_base + 9] = 0xd3;

    const cell_off = 0x0fd3;
    const cell = [_]u8{
        43, // payload size
        1, // rowid
        6, // record header size
        23, // text len 5: table
        23, // text len 5: users
        23, // text len 5: users
        1, // rootpage int8
        55, // text len 21: CREATE TABLE users(x)
        't', 'a', 'b', 'l', 'e',
        'u', 's', 'e', 'r', 's',
        'u', 's', 'e', 'r', 's',
        2,
        'C', 'R', 'E', 'A', 'T', 'E', ' ', 'T', 'A', 'B', 'L', 'E', ' ', 'u', 's', 'e', 'r', 's', '(', 'x', ')',
    };
    @memcpy(bytes[cell_off..][0..cell.len], &cell);

    const reader = try page.PageReader.init(&bytes);
    const schema = try readSchema(reader, std.testing.allocator);
    defer schema.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), schema.entries.len);
    try std.testing.expectEqualStrings("table", schema.entries[0].object_type);
    try std.testing.expectEqualStrings("users", schema.entries[0].name);
    try std.testing.expectEqual(@as(i64, 2), schema.entries[0].root_page);
}
