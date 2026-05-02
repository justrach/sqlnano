const std = @import("std");
const header = @import("header.zig");

pub const PageError = error{
    InvalidPageNumber,
    PageOutOfBounds,
};

pub const PageRef = struct {
    number: u32,
    bytes: []const u8,
    header_offset: usize,
    reserved_space: u8,

    pub fn isFirstPage(self: PageRef) bool {
        return self.number == 1;
    }

    pub fn usableBytes(self: PageRef) []const u8 {
        const start = self.header_offset;
        const end = self.bytes.len - self.reserved_space;
        return self.bytes[start..end];
    }
};

pub const PageReader = struct {
    bytes: []const u8,
    db_header: header.Header,

    pub fn init(bytes: []const u8) header.HeaderError!PageReader {
        const db_header = try header.Header.parse(bytes);
        return .{
            .bytes = bytes,
            .db_header = db_header,
        };
    }

    pub fn pageCount(self: PageReader) u32 {
        if (self.db_header.database_page_count != 0) return self.db_header.database_page_count;
        return @intCast(self.bytes.len / self.db_header.page_size);
    }

    pub fn usableSize(self: PageReader) usize {
        return self.db_header.page_size - self.db_header.reserved_space;
    }

    pub fn page(self: PageReader, number: u32) PageError!PageRef {
        if (number == 0) return error.InvalidPageNumber;

        const page_size: usize = self.db_header.page_size;
        const start = (@as(usize, number) - 1) * page_size;
        const end = start + page_size;
        if (end > self.bytes.len) return error.PageOutOfBounds;

        return .{
            .number = number,
            .bytes = self.bytes[start..end],
            .header_offset = if (number == 1) header.HEADER_SIZE else 0,
            .reserved_space = self.db_header.reserved_space,
        };
    }
};

test "read first page from sqlite image" {
    var bytes = [_]u8{0} ** 4096;
    @memcpy(bytes[0..16], header.MAGIC);
    bytes[16] = 0x10;
    bytes[17] = 0x00;
    bytes[18] = 1;
    bytes[19] = 1;
    bytes[21] = 64;
    bytes[22] = 32;
    bytes[23] = 32;
    bytes[31] = 1; // database page count = 1

    const reader = try PageReader.init(&bytes);
    try std.testing.expectEqual(@as(u32, 1), reader.pageCount());

    const first = try reader.page(1);
    try std.testing.expect(first.isFirstPage());
    try std.testing.expectEqual(@as(usize, 4096), first.bytes.len);
    try std.testing.expectEqual(@as(usize, 3996), first.usableBytes().len);
}

test "reject out of bounds page" {
    var bytes = [_]u8{0} ** 4096;
    @memcpy(bytes[0..16], header.MAGIC);
    bytes[16] = 0x10;
    bytes[17] = 0x00;
    bytes[18] = 1;
    bytes[19] = 1;
    bytes[21] = 64;
    bytes[22] = 32;
    bytes[23] = 32;

    const reader = try PageReader.init(&bytes);
    try std.testing.expectError(error.PageOutOfBounds, reader.page(2));
    try std.testing.expectError(error.InvalidPageNumber, reader.page(0));
}
