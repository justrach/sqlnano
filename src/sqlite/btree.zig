const std = @import("std");
const sqlite_page = @import("page.zig");

pub const BTreeError = error{
    PageTooSmall,
    InvalidPageType,
    InvalidCellIndex,
    CellOffsetOutOfBounds,
    InvalidPageHeader,
};

pub const PayloadInfo = struct {
    local_len: usize,
    overflow_page: ?u32,
};

pub const PageType = enum(u8) {
    table_interior = 0x05,
    index_interior = 0x02,
    table_leaf = 0x0d,
    index_leaf = 0x0a,

    pub fn fromByte(value: u8) BTreeError!PageType {
        return switch (value) {
            0x05 => .table_interior,
            0x02 => .index_interior,
            0x0d => .table_leaf,
            0x0a => .index_leaf,
            else => error.InvalidPageType,
        };
    }

    pub fn isLeaf(self: PageType) bool {
        return self == .table_leaf or self == .index_leaf;
    }

    pub fn isTable(self: PageType) bool {
        return self == .table_leaf or self == .table_interior;
    }

    pub fn isIndex(self: PageType) bool {
        return self == .index_leaf or self == .index_interior;
    }
};

pub const PageHeader = struct {
    page_type: PageType,
    first_freeblock: u16,
    cell_count: u16,
    cell_content_start: u32,
    fragmented_free_bytes: u8,
    right_most_pointer: ?u32,
    header_size: usize,

    pub fn parse(page: sqlite_page.PageRef) BTreeError!PageHeader {
        const data = page.bytes;
        const base = page.header_offset;
        const usable_end = data.len - page.reserved_space;
        if (base + 8 > usable_end) return error.PageTooSmall;

        const page_type = try PageType.fromByte(data[base]);
        const header_size: usize = if (page_type.isLeaf()) 8 else 12;
        if (base + header_size > usable_end) return error.PageTooSmall;

        const first_freeblock = readU16(data[base + 1 .. base + 3]);
        const cell_count = readU16(data[base + 3 .. base + 5]);
        const raw_cell_content_start = readU16(data[base + 5 .. base + 7]);
        const cell_content_start: u32 = if (raw_cell_content_start == 0) 65536 else raw_cell_content_start;
        const fragmented_free_bytes = data[base + 7];
        const right_most_pointer: ?u32 = if (page_type.isLeaf()) null else readU32(data[base + 8 .. base + 12]);

        const pointer_array_end = base + header_size + @as(usize, cell_count) * 2;
        if (pointer_array_end > usable_end) return error.InvalidPageHeader;
        if (cell_content_start != 65536 and cell_content_start > usable_end) return error.InvalidPageHeader;

        return .{
            .page_type = page_type,
            .first_freeblock = first_freeblock,
            .cell_count = cell_count,
            .cell_content_start = cell_content_start,
            .fragmented_free_bytes = fragmented_free_bytes,
            .right_most_pointer = right_most_pointer,
            .header_size = header_size,
        };
    }

    pub fn cellPointer(self: PageHeader, page: sqlite_page.PageRef, index: usize) BTreeError!u16 {
        if (index >= self.cell_count) return error.InvalidCellIndex;
        const data = page.bytes;
        const off = page.header_offset + self.header_size + index * 2;
        if (off + 2 > data.len - page.reserved_space) return error.InvalidCellIndex;
        const ptr = readU16(data[off .. off + 2]);
        if (ptr >= data.len - page.reserved_space) return error.CellOffsetOutOfBounds;
        return ptr;
    }

    pub fn cell(self: PageHeader, page: sqlite_page.PageRef, index: usize) BTreeError![]const u8 {
        const data = page.bytes;
        const ptr = try self.cellPointer(page, index);
        return data[ptr .. data.len - page.reserved_space];
    }
};

fn readU16(bytes: []const u8) u16 {
    return std.mem.readInt(u16, bytes[0..2], .big);
}

fn readU32(bytes: []const u8) u32 {
    return std.mem.readInt(u32, bytes[0..4], .big);
}

pub fn tableLeafPayloadInfo(payload_size: usize, usable_size: usize) PayloadInfo {
    return payloadInfo(payload_size, usable_size, usable_size - 35, ((usable_size - 12) * 32 / 255) - 23);
}

pub fn indexPayloadInfo(payload_size: usize, usable_size: usize) PayloadInfo {
    return payloadInfo(payload_size, usable_size, ((usable_size - 12) * 64 / 255) - 23, ((usable_size - 12) * 32 / 255) - 23);
}

fn payloadInfo(payload_size: usize, usable_size: usize, max_local: usize, min_local: usize) PayloadInfo {
    if (payload_size <= max_local) return .{ .local_len = payload_size, .overflow_page = null };

    const surplus = min_local + ((payload_size - min_local) % (usable_size - 4));
    const local_len = if (surplus <= max_local) surplus else min_local;
    return .{ .local_len = local_len, .overflow_page = 0 };
}

test "parse table leaf btree page header" {
    var bytes = [_]u8{0} ** 4096;
    bytes[0] = @intFromEnum(PageType.table_leaf);
    bytes[3] = 0;
    bytes[4] = 1;
    bytes[5] = 0x0f;
    bytes[6] = 0xf0;
    bytes[8] = 0x0f;
    bytes[9] = 0xf0;

    const page = sqlite_page.PageRef{ .number = 2, .bytes = &bytes, .header_offset = 0, .reserved_space = 0 };
    const parsed = try PageHeader.parse(page);
    try std.testing.expectEqual(PageType.table_leaf, parsed.page_type);
    try std.testing.expectEqual(@as(u16, 1), parsed.cell_count);
    try std.testing.expectEqual(@as(u16, 0x0ff0), parsed.cellPointer(page, 0));
}

test "parse table interior btree page header" {
    var bytes = [_]u8{0} ** 4096;
    bytes[0] = @intFromEnum(PageType.table_interior);
    bytes[3] = 0;
    bytes[4] = 0;
    bytes[5] = 0x10;
    bytes[6] = 0x00;
    bytes[8] = 0;
    bytes[9] = 0;
    bytes[10] = 0;
    bytes[11] = 7;

    const page = sqlite_page.PageRef{ .number = 2, .bytes = &bytes, .header_offset = 0, .reserved_space = 0 };
    const parsed = try PageHeader.parse(page);
    try std.testing.expectEqual(PageType.table_interior, parsed.page_type);
    try std.testing.expectEqual(@as(?u32, 7), parsed.right_most_pointer);
    try std.testing.expectEqual(@as(usize, 12), parsed.header_size);
}

test "reject invalid btree page type" {
    var bytes = [_]u8{0} ** 4096;
    bytes[0] = 0xff;
    const page = sqlite_page.PageRef{ .number = 2, .bytes = &bytes, .header_offset = 0, .reserved_space = 0 };
    try std.testing.expectError(error.InvalidPageType, PageHeader.parse(page));
}
