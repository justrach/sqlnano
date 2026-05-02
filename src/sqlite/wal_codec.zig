//! Binary codec for sqlnano WAL payloads.
//!
//! Each top-level row op (insert / update / delete) gets serialised into a
//! self-describing little-endian byte stream that the recovery driver can
//! turn back into the original AST-level operation.
//!
//! Value encoding (`Value`):
//!   [u8 tag] [body]
//!     tag 0 -> null,    body empty
//!     tag 1 -> integer, body i64 LE
//!     tag 2 -> text,    body u32 LE length + bytes
//!
//! Lengths use u32 LE; on encode we error if a length exceeds u32_max.
//!
//! All decoders take a borrowed payload slice and return either a fully
//! borrowed view (text slices alias the payload) or, for the row-insert
//! values array, an allocator-owned slice of `InsertValue` whose `text`
//! variants still alias into the payload — the caller frees the slice but
//! must keep the payload alive for the duration of use.

const std = @import("std");
const ast = @import("ast.zig");
const write = @import("write.zig");

pub const CodecError = error{
    OutOfMemory,
    PayloadTruncated,
    InvalidValueTag,
    PayloadTooLarge,
};

const TAG_NULL: u8 = 0;
const TAG_INTEGER: u8 = 1;
const TAG_TEXT: u8 = 2;

// ── encode ────────────────────────────────────────────────────────────────

pub fn encodeInsert(
    allocator: std.mem.Allocator,
    table_name: []const u8,
    rowid: i64,
    values: []const write.InsertValue,
) CodecError![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try writeBytes(&buf, allocator, table_name);
    try writeI64(&buf, allocator, rowid);
    if (values.len > std.math.maxInt(u32)) return error.PayloadTooLarge;
    try writeU32(&buf, allocator, @intCast(values.len));
    for (values) |v| try writeValue(&buf, allocator, v);
    return buf.toOwnedSlice(allocator);
}

pub fn encodeUpdate(
    allocator: std.mem.Allocator,
    stmt: ast.UpdateStatement,
) CodecError![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try writeBytes(&buf, allocator, stmt.table_name);
    try writeBytes(&buf, allocator, stmt.assignment.column_name);
    try writeLiteralValue(&buf, allocator, stmt.assignment.value);
    try writeBytes(&buf, allocator, stmt.where_clause.column_name);
    try writeLiteralValue(&buf, allocator, stmt.where_clause.value);
    return buf.toOwnedSlice(allocator);
}

pub fn encodeDelete(
    allocator: std.mem.Allocator,
    stmt: ast.DeleteStatement,
) CodecError![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try writeBytes(&buf, allocator, stmt.table_name);
    try writeBytes(&buf, allocator, stmt.where_clause.column_name);
    try writeLiteralValue(&buf, allocator, stmt.where_clause.value);
    return buf.toOwnedSlice(allocator);
}

// ── decode ────────────────────────────────────────────────────────────────

pub const DecodedInsert = struct {
    table_name: []const u8,
    rowid: i64,
    values: []write.InsertValue,

    pub fn deinit(self: DecodedInsert, allocator: std.mem.Allocator) void {
        allocator.free(self.values);
    }
};

pub const DecodedUpdate = struct {
    statement: ast.UpdateStatement,
};

pub const DecodedDelete = struct {
    statement: ast.DeleteStatement,
};

pub fn decodeInsert(allocator: std.mem.Allocator, payload: []const u8) CodecError!DecodedInsert {
    var cur = Cursor{ .data = payload };
    const table_name = try cur.readBytes();
    const rowid = try cur.readI64();
    const count = try cur.readU32();
    const values = try allocator.alloc(write.InsertValue, count);
    errdefer allocator.free(values);
    var i: usize = 0;
    while (i < count) : (i += 1) values[i] = try cur.readValue();
    return .{ .table_name = table_name, .rowid = rowid, .values = values };
}

pub fn decodeUpdate(payload: []const u8) CodecError!DecodedUpdate {
    var cur = Cursor{ .data = payload };
    const table_name = try cur.readBytes();
    const assign_col = try cur.readBytes();
    const assign_val = try cur.readLiteral();
    const where_col = try cur.readBytes();
    const where_val = try cur.readLiteral();
    return .{ .statement = .{
        .table_name = table_name,
        .assignment = .{ .column_name = assign_col, .value = assign_val },
        .where_clause = .{ .column_name = where_col, .value = where_val },
    } };
}

pub fn decodeDelete(payload: []const u8) CodecError!DecodedDelete {
    var cur = Cursor{ .data = payload };
    const table_name = try cur.readBytes();
    const where_col = try cur.readBytes();
    const where_val = try cur.readLiteral();
    return .{ .statement = .{
        .table_name = table_name,
        .where_clause = .{ .column_name = where_col, .value = where_val },
    } };
}

// ── internals ─────────────────────────────────────────────────────────────

fn writeU32(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, value: u32) CodecError!void {
    var tmp: [4]u8 = undefined;
    std.mem.writeInt(u32, &tmp, value, .little);
    try buf.appendSlice(allocator, &tmp);
}

fn writeI64(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, value: i64) CodecError!void {
    var tmp: [8]u8 = undefined;
    std.mem.writeInt(i64, &tmp, value, .little);
    try buf.appendSlice(allocator, &tmp);
}

fn writeBytes(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, bytes: []const u8) CodecError!void {
    if (bytes.len > std.math.maxInt(u32)) return error.PayloadTooLarge;
    try writeU32(buf, allocator, @intCast(bytes.len));
    try buf.appendSlice(allocator, bytes);
}

fn writeValue(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, value: write.InsertValue) CodecError!void {
    switch (value) {
        .null => try buf.append(allocator, TAG_NULL),
        .integer => |v| {
            try buf.append(allocator, TAG_INTEGER);
            try writeI64(buf, allocator, v);
        },
        .text => |t| {
            try buf.append(allocator, TAG_TEXT);
            try writeBytes(buf, allocator, t);
        },
    }
}

fn writeLiteralValue(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, lit: ast.Literal) CodecError!void {
    switch (lit) {
        .null => try buf.append(allocator, TAG_NULL),
        .integer => |v| {
            try buf.append(allocator, TAG_INTEGER);
            try writeI64(buf, allocator, v);
        },
        .text => |t| {
            try buf.append(allocator, TAG_TEXT);
            try writeBytes(buf, allocator, t);
        },
    }
}

const Cursor = struct {
    data: []const u8,
    pos: usize = 0,

    fn need(self: *Cursor, n: usize) CodecError!void {
        if (self.pos + n > self.data.len) return error.PayloadTruncated;
    }

    fn readU32(self: *Cursor) CodecError!u32 {
        try self.need(4);
        const v = std.mem.readInt(u32, self.data[self.pos..][0..4], .little);
        self.pos += 4;
        return v;
    }

    fn readI64(self: *Cursor) CodecError!i64 {
        try self.need(8);
        const v = std.mem.readInt(i64, self.data[self.pos..][0..8], .little);
        self.pos += 8;
        return v;
    }

    fn readBytes(self: *Cursor) CodecError![]const u8 {
        const len = try self.readU32();
        try self.need(len);
        const out = self.data[self.pos..][0..len];
        self.pos += len;
        return out;
    }

    fn readValue(self: *Cursor) CodecError!write.InsertValue {
        try self.need(1);
        const tag = self.data[self.pos];
        self.pos += 1;
        return switch (tag) {
            TAG_NULL => .null,
            TAG_INTEGER => .{ .integer = try self.readI64() },
            TAG_TEXT => .{ .text = try self.readBytes() },
            else => error.InvalidValueTag,
        };
    }

    fn readLiteral(self: *Cursor) CodecError!ast.Literal {
        try self.need(1);
        const tag = self.data[self.pos];
        self.pos += 1;
        return switch (tag) {
            TAG_NULL => .null,
            TAG_INTEGER => .{ .integer = try self.readI64() },
            TAG_TEXT => .{ .text = try self.readBytes() },
            else => error.InvalidValueTag,
        };
    }
};

// ── tests ─────────────────────────────────────────────────────────────────

const testing = std.testing;

test "insert payload roundtrip" {
    const vals = [_]write.InsertValue{ .{ .integer = 7 }, .{ .text = "alice" }, .null };
    const buf = try encodeInsert(testing.allocator, "users", 7, &vals);
    defer testing.allocator.free(buf);
    const dec = try decodeInsert(testing.allocator, buf);
    defer dec.deinit(testing.allocator);
    try testing.expectEqualStrings("users", dec.table_name);
    try testing.expectEqual(@as(i64, 7), dec.rowid);
    try testing.expectEqual(@as(usize, 3), dec.values.len);
    try testing.expectEqual(@as(i64, 7), dec.values[0].integer);
    try testing.expectEqualStrings("alice", dec.values[1].text);
    try testing.expect(dec.values[2] == .null);
}

test "update payload roundtrip" {
    const stmt = ast.UpdateStatement{
        .table_name = "t",
        .assignment = .{ .column_name = "name", .value = .{ .text = "bob" } },
        .where_clause = .{ .column_name = "id", .value = .{ .integer = 3 } },
    };
    const buf = try encodeUpdate(testing.allocator, stmt);
    defer testing.allocator.free(buf);
    const dec = try decodeUpdate(buf);
    try testing.expectEqualStrings("t", dec.statement.table_name);
    try testing.expectEqualStrings("name", dec.statement.assignment.column_name);
    try testing.expectEqualStrings("bob", dec.statement.assignment.value.text);
    try testing.expectEqualStrings("id", dec.statement.where_clause.column_name);
    try testing.expectEqual(@as(i64, 3), dec.statement.where_clause.value.integer);
}

test "delete payload roundtrip" {
    const stmt = ast.DeleteStatement{
        .table_name = "t",
        .where_clause = .{ .column_name = "id", .value = .{ .integer = 9 } },
    };
    const buf = try encodeDelete(testing.allocator, stmt);
    defer testing.allocator.free(buf);
    const dec = try decodeDelete(buf);
    try testing.expectEqualStrings("t", dec.statement.table_name);
    try testing.expectEqualStrings("id", dec.statement.where_clause.column_name);
    try testing.expectEqual(@as(i64, 9), dec.statement.where_clause.value.integer);
}

test "truncated payload rejected" {
    const vals = [_]write.InsertValue{.{ .text = "alice" }};
    const buf = try encodeInsert(testing.allocator, "users", 1, &vals);
    defer testing.allocator.free(buf);
    try testing.expectError(error.PayloadTruncated, decodeInsert(testing.allocator, buf[0 .. buf.len - 1]));
}
