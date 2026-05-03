const std = @import("std");

pub const VarintError = error{
    TooSmall,
    Overflow,
};

pub const Varint = struct {
    value: u64,
    len: u8,
};

pub fn parse(bytes: []const u8) VarintError!Varint {
    // Fast path: 1-2 bytes cover >99% of SQLite serial types and header sizes.
    if (bytes.len >= 2) {
        const b0 = bytes[0];
        if ((b0 & 0x80) == 0) return .{ .value = b0, .len = 1 };
        const b1 = bytes[1];
        const v2: u64 = (@as(u64, b0 & 0x7f) << 7) | @as(u64, b1 & 0x7f);
        if ((b1 & 0x80) == 0) return .{ .value = v2, .len = 2 };
        // 3+ bytes — fall through to full loop.
    } else if (bytes.len >= 1) {
        const b0 = bytes[0];
        if ((b0 & 0x80) == 0) return .{ .value = b0, .len = 1 };
    }

    var value: u64 = 0;
    var i: usize = 0;
    while (i < bytes.len and i < 9) : (i += 1) {
        const b = bytes[i];
        if (i == 8) {
            value = (value << 8) | b;
            return .{ .value = value, .len = 9 };
        }

        value = (value << 7) | (b & 0x7f);
        if ((b & 0x80) == 0) return .{ .value = value, .len = @intCast(i + 1) };
    }

    return if (bytes.len < 9) error.TooSmall else error.Overflow;
}

test "parse one byte varint" {
    const v = try parse(&[_]u8{0x7f});
    try std.testing.expectEqual(@as(u64, 127), v.value);
    try std.testing.expectEqual(@as(u8, 1), v.len);
}

test "parse multi byte varint" {
    const v = try parse(&[_]u8{ 0x81, 0x00 });
    try std.testing.expectEqual(@as(u64, 128), v.value);
    try std.testing.expectEqual(@as(u8, 2), v.len);
}

test "parse nine byte varint" {
    const v = try parse(&[_]u8{ 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff });
    try std.testing.expectEqual(@as(u8, 9), v.len);
    try std.testing.expectEqual(@as(u64, std.math.maxInt(u64)), v.value);
}
