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
