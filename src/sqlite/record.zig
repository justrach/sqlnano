const std = @import("std");
const varint = @import("varint.zig");

pub const RecordError = error{
    OutOfMemory,
    InvalidHeaderSize,
    InvalidSerialType,
    ValueOutOfBounds,
    VarintTooSmall,
    VarintOverflow,
    TooManyColumns,
};

pub const Value = union(enum) {
    null,
    integer: i64,
    real: f64,
    text: []const u8,
    blob: []const u8,
};

pub const Record = struct {
    values: []Value,

    pub fn deinit(self: Record, allocator: std.mem.Allocator) void {
        allocator.free(self.values);
    }
};

/// Maximum column count the zero-alloc `parseInline` path will accept.
/// Real-world SQLite schemas are effectively always under this — the
/// engine's own hard limit is 2000 but 99% of tables are <20 cols.
pub const MAX_INLINE_VALUES = 64;

/// Stack-allocated record view. Fields are valid only as long as the
/// backing cell bytes outlive the view.
pub const InlineRecord = struct {
    values: [MAX_INLINE_VALUES]Value,
    len: usize,

    pub fn slice(self: *const InlineRecord) []const Value {
        return self.values[0..self.len];
    }
};

/// Parse a SQLite record into a stack-allocated buffer — no heap
/// allocation at all. Returns `error.TooManyColumns` when the record
/// has more than `MAX_INLINE_VALUES` columns; the caller should fall
/// back to the heap-based `parse` for wide rows. Decoded text/blob
/// values point directly into `bytes`.
pub fn parseInline(bytes: []const u8, out: *InlineRecord) RecordError!void {
    const header_size_varint = try parseVarint(bytes);
    const header_size: usize = @intCast(header_size_varint.value);
    if (header_size == 0 or header_size > bytes.len) return error.InvalidHeaderSize;

    var header_pos: usize = header_size_varint.len;
    var body_pos = header_size;
    var n: usize = 0;
    while (header_pos < header_size) {
        if (n >= MAX_INLINE_VALUES) return error.TooManyColumns;
        const serial = try parseVarint(bytes[header_pos..header_size]);
        header_pos += serial.len;
        // Inline decode — avoid per-column function call + switch dispatch.
        // Common case (serial 0-9) has no body bytes; text/blob compute
        // len from serial type formula inline.
        const v, const advance: usize = switch (serial.value) {
            0 => .{ Value.null, 0 },
            1 => blk: {
                @branchHint(.likely);
                break :blk .{ Value{ .integer = try readSigned(bytes[body_pos..], 1) }, 1 };
            },
            2 => .{ Value{ .integer = try readSigned(bytes[body_pos..], 2) }, 2 },
            3 => .{ Value{ .integer = try readSigned(bytes[body_pos..], 3) }, 3 },
            4 => .{ Value{ .integer = try readSigned(bytes[body_pos..], 4) }, 4 },
            5 => .{ Value{ .integer = try readSigned(bytes[body_pos..], 6) }, 6 },
            6 => blk: {
                @branchHint(.likely);
                break :blk .{ Value{ .integer = try readSigned(bytes[body_pos..], 8) }, 8 };
            },
            7 => blk: {
                if (bytes.len - body_pos < 8) {
                    @branchHint(.cold);
                    return error.ValueOutOfBounds;
                }
                const raw = std.mem.readInt(u64, bytes[body_pos..][0..8], .big);
                break :blk .{ Value{ .real = @bitCast(raw) }, 8 };
            },
            8 => blk: {
                @branchHint(.likely);
                break :blk .{ Value{ .integer = 0 }, 0 };
            },
            9 => blk: {
                @branchHint(.likely);
                break :blk .{ Value{ .integer = 1 }, 0 };
            },
            10, 11 => {
                @branchHint(.cold);
                return error.InvalidSerialType;
            },
            else => blk: {
                @branchHint(.likely);
                const len: usize = if (serial.value % 2 == 0)
                    @intCast((serial.value - 12) / 2)
                else
                    @intCast((serial.value - 13) / 2);
                if (bytes.len - body_pos < len) {
                    @branchHint(.cold);
                    return error.ValueOutOfBounds;
                }
                if (serial.value % 2 == 0) {
                    break :blk .{ Value{ .blob = bytes[body_pos..][0..len] }, len };
                } else {
                    break :blk .{ Value{ .text = bytes[body_pos..][0..len] }, len };
                }
            },
        };
        out.values[n] = v;
        body_pos += advance;
        n += 1;
    }
    if (header_pos != header_size) return error.InvalidHeaderSize;
    out.len = n;
}

pub fn parse(bytes: []const u8, allocator: std.mem.Allocator) RecordError!Record {
    const header_size_varint = try parseVarint(bytes);
    const header_size: usize = @intCast(header_size_varint.value);
    if (header_size == 0 or header_size > bytes.len) return error.InvalidHeaderSize;

    var serial_types: std.ArrayList(u64) = .empty;
    defer serial_types.deinit(allocator);

    var header_pos: usize = header_size_varint.len;
    while (header_pos < header_size) {
        const serial = try parseVarint(bytes[header_pos..header_size]);
        try serial_types.append(allocator, serial.value);
        header_pos += serial.len;
    }
    if (header_pos != header_size) return error.InvalidHeaderSize;

    const values = try allocator.alloc(Value, serial_types.items.len);
    errdefer allocator.free(values);

    var body_pos = header_size;
    for (serial_types.items, 0..) |serial, i| {
        const decoded = try decodeValue(serial, bytes[body_pos..]);
        values[i] = decoded.value;
        body_pos += decoded.len;
    }

    return .{ .values = values };
}

fn parseVarint(bytes: []const u8) RecordError!varint.Varint {
    return varint.parse(bytes) catch |err| switch (err) {
        error.TooSmall => error.VarintTooSmall,
        error.Overflow => error.VarintOverflow,
    };
}

const DecodedValue = struct {
    value: Value,
    len: usize,
};

fn decodeValue(serial: u64, bytes: []const u8) RecordError!DecodedValue {
    return switch (serial) {
        0 => .{ .value = .null, .len = 0 },
        1 => blk: {
            @branchHint(.likely);
            break :blk .{ .value = .{ .integer = try readSigned(bytes, 1) }, .len = 1 };
        },
        2 => .{ .value = .{ .integer = try readSigned(bytes, 2) }, .len = 2 },
        3 => .{ .value = .{ .integer = try readSigned(bytes, 3) }, .len = 3 },
        4 => .{ .value = .{ .integer = try readSigned(bytes, 4) }, .len = 4 },
        5 => .{ .value = .{ .integer = try readSigned(bytes, 6) }, .len = 6 },
        6 => blk: {
            @branchHint(.likely);
            break :blk .{ .value = .{ .integer = try readSigned(bytes, 8) }, .len = 8 };
        },
        7 => blk: {
            if (bytes.len < 8) {
                @branchHint(.cold);
                return error.ValueOutOfBounds;
            }
            const raw = std.mem.readInt(u64, bytes[0..8], .big);
            break :blk .{ .value = .{ .real = @bitCast(raw) }, .len = 8 };
        },
        8 => blk: {
            @branchHint(.likely);
            break :blk .{ .value = .{ .integer = 0 }, .len = 0 };
        },
        9 => blk: {
            @branchHint(.likely);
            break :blk .{ .value = .{ .integer = 1 }, .len = 0 };
        },
        10, 11 => blk: {
            @branchHint(.cold);
            break :blk error.InvalidSerialType;
        },
        else => blk: {
            @branchHint(.likely);
            const len: usize = if (serial % 2 == 0) @intCast((serial - 12) / 2) else @intCast((serial - 13) / 2);
            if (bytes.len < len) {
                @branchHint(.cold);
                return error.ValueOutOfBounds;
            }
            if (serial % 2 == 0) {
                break :blk .{ .value = .{ .blob = bytes[0..len] }, .len = len };
            } else {
                break :blk .{ .value = .{ .text = bytes[0..len] }, .len = len };
            }
        },
    };
}

fn readSigned(bytes: []const u8, len: usize) RecordError!i64 {
    if (bytes.len < len) return error.ValueOutOfBounds;
    var value: i64 = if ((bytes[0] & 0x80) != 0) -1 else 0;
    for (bytes[0..len]) |b| {
        value = (value << 8) | @as(i64, b);
    }
    return value;
}

test "parse simple sqlite record" {
    // header size=3, serials: int8 + 5-byte text, body: 42 + alice
    const bytes = [_]u8{ 3, 1, 23, 42, 'a', 'l', 'i', 'c', 'e' };
    const rec = try parse(&bytes, std.testing.allocator);
    defer rec.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), rec.values.len);
    try std.testing.expectEqual(@as(i64, 42), rec.values[0].integer);
    try std.testing.expectEqualStrings("alice", rec.values[1].text);
}

test "parse null and integer constants" {
    const bytes = [_]u8{ 4, 0, 8, 9 };
    const rec = try parse(&bytes, std.testing.allocator);
    defer rec.deinit(std.testing.allocator);

    try std.testing.expect(rec.values[0] == .null);
    try std.testing.expectEqual(@as(i64, 0), rec.values[1].integer);
    try std.testing.expectEqual(@as(i64, 1), rec.values[2].integer);
}
