const std = @import("std");
const btree = @import("btree.zig");
const page = @import("page.zig");
const record = @import("record.zig");
const varint = @import("varint.zig");

pub const IndexError = error{
    OutOfMemory,
    UnsupportedIndexBTree,
    InvalidIndexCell,
    InvalidOverflowPage,
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
    TooManyColumns,
};

pub const IndexEntry = struct {
    values: []record.Value,
    owned_payload: ?[]u8 = null,

    pub fn rowid(self: IndexEntry) ?i64 {
        if (self.values.len == 0) return null;
        return switch (self.values[self.values.len - 1]) {
            .integer => |v| v,
            else => null,
        };
    }

    pub fn deinit(self: IndexEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.values);
        if (self.owned_payload) |payload| allocator.free(payload);
    }
};

pub const Index = struct {
    entries: []IndexEntry,

    pub fn deinit(self: Index, allocator: std.mem.Allocator) void {
        for (self.entries) |entry| entry.deinit(allocator);
        allocator.free(self.entries);
    }
};

pub const LookupValue = union(enum) {
    null,
    integer: i64,
    text: []const u8,
};

const IndexCellView = struct {
    values: []const record.Value,
    owned: ?IndexEntry = null,

    fn deinit(self: IndexCellView, allocator: std.mem.Allocator) void {
        if (self.owned) |entry| entry.deinit(allocator);
    }
};

pub fn scanIndex(reader: page.PageReader, root_page: u32, allocator: std.mem.Allocator) IndexError!Index {
    var entries: std.ArrayList(IndexEntry) = .empty;
    errdefer {
        for (entries.items) |entry| entry.deinit(allocator);
        entries.deinit(allocator);
    }

    try scanIndexPage(reader, root_page, allocator, &entries);
    return .{ .entries = try entries.toOwnedSlice(allocator) };
}

pub fn rowidsForFirstColumnEquals(
    reader: page.PageReader,
    root_page: u32,
    value: LookupValue,
    allocator: std.mem.Allocator,
) IndexError![]i64 {
    var rowids: std.ArrayList(i64) = .empty;
    errdefer rowids.deinit(allocator);
    try rowidsForFirstColumnEqualsPage(reader, root_page, value, allocator, &rowids);
    return try rowids.toOwnedSlice(allocator);
}

fn scanIndexPage(reader: page.PageReader, page_number: u32, allocator: std.mem.Allocator, entries: *std.ArrayList(IndexEntry)) IndexError!void {
    const ref = try reader.page(page_number);
    const header = try btree.PageHeader.parse(ref);
    if (!header.page_type.isIndex()) return error.UnsupportedIndexBTree;

    if (header.page_type == .index_interior) {
        var i: usize = 0;
        while (i < header.cell_count) : (i += 1) {
            const cell = try header.cell(ref, i);
            if (cell.len < 4) return error.InvalidIndexCell;
            const left_child = readU32(cell[0..4]);
            try scanIndexPage(reader, left_child, allocator, entries);
            const entry = try parseIndexCellWithReader(reader, cell[4..], allocator);
            errdefer entry.deinit(allocator);
            try entries.append(allocator, entry);
        }
        const right = header.right_most_pointer orelse return error.InvalidIndexCell;
        try scanIndexPage(reader, right, allocator, entries);
        return;
    }

    var i: usize = 0;
    while (i < header.cell_count) : (i += 1) {
        const cell = try header.cell(ref, i);
        const entry = try parseIndexCellWithReader(reader, cell, allocator);
        errdefer entry.deinit(allocator);
        try entries.append(allocator, entry);
    }
}

fn rowidsForFirstColumnEqualsPage(
    reader: page.PageReader,
    page_number: u32,
    value: LookupValue,
    allocator: std.mem.Allocator,
    rowids: *std.ArrayList(i64),
) IndexError!void {
    const ref = try reader.page(page_number);
    const header = try btree.PageHeader.parse(ref);
    if (!header.page_type.isIndex()) return error.UnsupportedIndexBTree;

    if (header.page_type == .index_leaf) {
        return rowidsForFirstColumnEqualsLeaf(reader, ref, header, value, allocator, rowids);
    }

    var i: usize = 0;
    while (i < header.cell_count) : (i += 1) {
        const cell = try header.cell(ref, i);
        if (cell.len < 4) return error.InvalidIndexCell;
        const left_child = readU32(cell[0..4]);
        var inline_rec: record.InlineRecord = undefined;
        const entry = try parseIndexCellView(reader, cell[4..], allocator, &inline_rec);
        defer entry.deinit(allocator);
        const cmp = compareFirstValueToLookup(entry.values, value);

        if (cmp >= 0) {
            try rowidsForFirstColumnEqualsPage(reader, left_child, value, allocator, rowids);
        }
        if (cmp == 0) {
            if (rowidFromValues(entry.values)) |rowid| try rowids.append(allocator, rowid);
        }
        if (cmp > 0) return;
    }

    const right = header.right_most_pointer orelse return error.InvalidIndexCell;
    try rowidsForFirstColumnEqualsPage(reader, right, value, allocator, rowids);
}

fn rowidsForFirstColumnEqualsLeaf(
    reader: page.PageReader,
    ref: page.PageRef,
    header: btree.PageHeader,
    value: LookupValue,
    allocator: std.mem.Allocator,
    rowids: *std.ArrayList(i64),
) IndexError!void {
    var lo: usize = 0;
    var hi: usize = header.cell_count;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const cell = try header.cell(ref, mid);
        var inline_rec: record.InlineRecord = undefined;
        const entry = try parseIndexCellView(reader, cell, allocator, &inline_rec);
        defer entry.deinit(allocator);
        if (compareFirstValueToLookup(entry.values, value) < 0) {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }

    var i = lo;
    while (i < header.cell_count) : (i += 1) {
        const cell = try header.cell(ref, i);
        var inline_rec: record.InlineRecord = undefined;
        const entry = try parseIndexCellView(reader, cell, allocator, &inline_rec);
        defer entry.deinit(allocator);
        const cmp = compareFirstValueToLookup(entry.values, value);
        if (cmp > 0) break;
        if (cmp == 0 and valuesMatchLookup(entry.values, value)) {
            if (rowidFromValues(entry.values)) |rowid| try rowids.append(allocator, rowid);
        }
    }
}

fn parseIndexCellWithReader(reader: page.PageReader, cell: []const u8, allocator: std.mem.Allocator) IndexError!IndexEntry {
    const payload_size_v = try parseVarint(cell);
    const payload_size: usize = @intCast(payload_size_v.value);
    const payload_start: usize = payload_size_v.len;
    const payload_info = btree.indexPayloadInfo(payload_size, reader.usableSize());
    if (payload_start + payload_info.local_len > cell.len) return error.InvalidIndexCell;

    if (payload_info.overflow_page == null) {
        const rec = try record.parse(cell[payload_start..][0..payload_size], allocator);
        return .{ .values = rec.values };
    }

    if (payload_start + payload_info.local_len + 4 > cell.len) return error.InvalidIndexCell;
    const payload = try allocator.alloc(u8, payload_size);
    errdefer allocator.free(payload);
    @memcpy(payload[0..payload_info.local_len], cell[payload_start..][0..payload_info.local_len]);

    var written = payload_info.local_len;
    var next_page = readU32(cell[payload_start + payload_info.local_len ..][0..4]);
    while (written < payload.len) {
        if (next_page == 0) return error.InvalidOverflowPage;
        const overflow = try reader.page(next_page);
        const usable_end = overflow.bytes.len - overflow.reserved_space;
        if (usable_end < 4) return error.InvalidOverflowPage;
        const overflow_payload = overflow.bytes[4..usable_end];
        const n = @min(overflow_payload.len, payload.len - written);
        @memcpy(payload[written..][0..n], overflow_payload[0..n]);
        written += n;
        next_page = readU32(overflow.bytes[0..4]);
    }

    const rec = try record.parse(payload, allocator);
    errdefer rec.deinit(allocator);
    return .{ .values = rec.values, .owned_payload = payload };
}

fn parseIndexCellView(
    reader: page.PageReader,
    cell: []const u8,
    allocator: std.mem.Allocator,
    inline_rec: *record.InlineRecord,
) IndexError!IndexCellView {
    const payload_size_v = try parseVarint(cell);
    const payload_size: usize = @intCast(payload_size_v.value);
    const payload_start: usize = payload_size_v.len;
    const payload_info = btree.indexPayloadInfo(payload_size, reader.usableSize());
    if (payload_start + payload_info.local_len > cell.len) return error.InvalidIndexCell;

    if (payload_info.overflow_page == null) {
        try record.parseInline(cell[payload_start..][0..payload_size], inline_rec);
        return .{ .values = inline_rec.slice() };
    }

    const entry = try parseIndexCellWithReader(reader, cell, allocator);
    return .{ .values = entry.values, .owned = entry };
}

fn rowidFromValues(values: []const record.Value) ?i64 {
    if (values.len == 0) return null;
    return switch (values[values.len - 1]) {
        .integer => |v| v,
        else => null,
    };
}

fn valuesMatchLookup(values: []const record.Value, value: LookupValue) bool {
    if (values.len == 0) return false;
    return switch (value) {
        .null => values[0] == .null,
        .integer => |expected| switch (values[0]) {
            .integer => |actual| actual == expected,
            else => false,
        },
        .text => |expected| switch (values[0]) {
            .text => |actual| std.mem.eql(u8, actual, expected),
            else => false,
        },
    };
}

fn compareFirstValueToLookup(values: []const record.Value, lookup: LookupValue) i8 {
    const first: record.Value = if (values.len > 0) values[0] else .null;
    const first_rank = recordValueRank(first);
    const lookup_rank = lookupValueRank(lookup);
    if (first_rank < lookup_rank) return -1;
    if (first_rank > lookup_rank) return 1;

    return switch (lookup) {
        .null => 0,
        .integer => |expected| switch (first) {
            .integer => |actual| if (actual < expected) -1 else if (actual > expected) 1 else 0,
            .real => |actual| blk: {
                const expected_f: f64 = @floatFromInt(expected);
                break :blk if (actual < expected_f) -1 else if (actual > expected_f) 1 else 0;
            },
            else => 0,
        },
        .text => |expected| switch (first) {
            .text => |actual| orderToI8(std.mem.order(u8, actual, expected)),
            else => 0,
        },
    };
}

fn recordValueRank(value: record.Value) u8 {
    return switch (value) {
        .null => 0,
        .integer, .real => 1,
        .text => 3,
        .blob => 4,
    };
}

fn lookupValueRank(value: LookupValue) u8 {
    return switch (value) {
        .null => 0,
        .integer => 1,
        .text => 3,
    };
}

fn orderToI8(order: std.math.Order) i8 {
    return switch (order) {
        .lt => -1,
        .eq => 0,
        .gt => 1,
    };
}

fn parseVarint(bytes: []const u8) IndexError!varint.Varint {
    return varint.parse(bytes) catch |err| switch (err) {
        error.TooSmall => error.VarintTooSmall,
        error.Overflow => error.VarintOverflow,
    };
}

fn readU32(bytes: []const u8) u32 {
    return std.mem.readInt(u32, bytes[0..4], .big);
}

test "scan index leaf page" {
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
    bytes[page_base + 0] = @intFromEnum(btree.PageType.index_leaf);
    bytes[page_base + 3] = 0;
    bytes[page_base + 4] = 1;
    bytes[page_base + 5] = 0x0f;
    bytes[page_base + 6] = 0xf6;
    bytes[page_base + 8] = 0x0f;
    bytes[page_base + 9] = 0xf6;

    const cell_off = 0x0ff6;
    const cell = [_]u8{ 9, 3, 19, 1, 'b', 'o', 'b', 7 };
    @memcpy(bytes[cell_off..][0..cell.len], &cell);

    const reader = try page.PageReader.init(&bytes);
    const idx = try scanIndex(reader, 1, std.testing.allocator);
    defer idx.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), idx.entries.len);
    try std.testing.expectEqualStrings("bob", idx.entries[0].values[0].text);
    try std.testing.expectEqual(@as(?i64, 7), idx.entries[0].rowid());
}

test "rowidsForFirstColumnEquals returns only matching leaf range" {
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
    bytes[page_base + 0] = @intFromEnum(btree.PageType.index_leaf);
    bytes[page_base + 3] = 0;
    bytes[page_base + 4] = 4;

    const cells = [_][]const u8{
        &.{ 8, 3, 23, 9, 'a', 'l', 'i', 'c', 'e' },
        &.{ 9, 3, 19, 1, 'b', 'o', 'b', 7 },
        &.{ 9, 3, 19, 1, 'b', 'o', 'b', 8 },
        &.{ 9, 3, 19, 1, 'z', 'e', 'd', 9 },
    };

    var off: usize = bytes.len;
    for (cells, 0..) |cell, i| {
        off -= cell.len;
        @memcpy(bytes[off..][0..cell.len], cell);
        std.mem.writeInt(u16, bytes[page_base + 8 + i * 2 ..][0..2], @intCast(off), .big);
    }
    std.mem.writeInt(u16, bytes[page_base + 5 ..][0..2], @intCast(off), .big);

    const reader = try page.PageReader.init(&bytes);
    const rowids = try rowidsForFirstColumnEquals(reader, 1, .{ .text = "bob" }, std.testing.allocator);
    defer std.testing.allocator.free(rowids);
    try std.testing.expectEqual(@as(usize, 2), rowids.len);
    try std.testing.expectEqual(@as(i64, 7), rowids[0]);
    try std.testing.expectEqual(@as(i64, 8), rowids[1]);

    const missing = try rowidsForFirstColumnEquals(reader, 1, .{ .text = "carol" }, std.testing.allocator);
    defer std.testing.allocator.free(missing);
    try std.testing.expectEqual(@as(usize, 0), missing.len);
}
