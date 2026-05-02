const std = @import("std");
const btree = @import("btree.zig");
const page = @import("page.zig");
const record = @import("record.zig");
const varint = @import("varint.zig");

pub const TableError = error{
    OutOfMemory,
    UnsupportedTableBTree,
    InvalidTableCell,
    InvalidOverflowPage,
    PayloadOverflowUnsupported,
    PageOutOfBounds,
    InvalidPageNumber,
    PageTooSmall,
    InvalidPageType,
    InvalidCellIndex,
    CellOffsetOutOfBounds,
    InvalidPageHeader,
    RowNotFound,
    TooSmall,
    Overflow,
    InvalidHeaderSize,
    InvalidSerialType,
    ValueOutOfBounds,
    VarintTooSmall,
    VarintOverflow,
};

pub const Row = struct {
    rowid: i64,
    values: []record.Value,
    owned_payload: ?[]u8 = null,

    pub fn deinit(self: Row, allocator: std.mem.Allocator) void {
        allocator.free(self.values);
        if (self.owned_payload) |payload| allocator.free(payload);
    }
};

pub const Table = struct {
    rows: []Row,

    pub fn deinit(self: Table, allocator: std.mem.Allocator) void {
        for (self.rows) |row| row.deinit(allocator);
        allocator.free(self.rows);
    }
};

pub fn scanTable(reader: page.PageReader, root_page: u32, allocator: std.mem.Allocator) TableError!Table {
    var rows: std.ArrayList(Row) = .empty;
    errdefer {
        for (rows.items) |row| row.deinit(allocator);
        rows.deinit(allocator);
    }

    try scanTablePage(reader, root_page, allocator, &rows);
    return .{ .rows = try rows.toOwnedSlice(allocator) };
}

pub fn findRowByRowid(reader: page.PageReader, root_page: u32, wanted_rowid: i64, allocator: std.mem.Allocator) TableError!?Row {
    return findRowInPage(reader, root_page, wanted_rowid, allocator);
}

fn findRowInPage(reader: page.PageReader, page_number: u32, wanted_rowid: i64, allocator: std.mem.Allocator) TableError!?Row {
    const ref = try reader.page(page_number);
    const header = try btree.PageHeader.parse(ref);
    if (!header.page_type.isTable()) return error.UnsupportedTableBTree;

    return switch (header.page_type) {
        .table_leaf => try findRowInLeaf(reader, ref, header, wanted_rowid, allocator),
        .table_interior => try findRowInInterior(reader, ref, header, wanted_rowid, allocator),
        else => error.UnsupportedTableBTree,
    };
}

fn findRowInLeaf(reader: page.PageReader, ref: page.PageRef, header: btree.PageHeader, wanted_rowid: i64, allocator: std.mem.Allocator) TableError!?Row {
    var lo: usize = 0;
    var hi: usize = header.cell_count;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const cell = try header.cell(ref, mid);
        const prefix = try parseTableLeafCellPrefix(cell);
        if (wanted_rowid < prefix.rowid) {
            hi = mid;
        } else if (wanted_rowid > prefix.rowid) {
            lo = mid + 1;
        } else {
            return try parseTableLeafCellWithReader(reader, cell, allocator);
        }
    }
    return null;
}

fn findRowInInterior(reader: page.PageReader, ref: page.PageRef, header: btree.PageHeader, wanted_rowid: i64, allocator: std.mem.Allocator) TableError!?Row {
    var i: usize = 0;
    while (i < header.cell_count) : (i += 1) {
        const cell = try header.cell(ref, i);
        if (cell.len < 5) return error.InvalidTableCell;
        const left_child = readU32(cell[0..4]);
        const sep = try parseVarint(cell[4..]);
        if (wanted_rowid <= @as(i64, @intCast(sep.value))) {
            return try findRowInPage(reader, left_child, wanted_rowid, allocator);
        }
    }

    const right = header.right_most_pointer orelse return error.InvalidTableCell;
    return try findRowInPage(reader, right, wanted_rowid, allocator);
}

fn scanTablePage(reader: page.PageReader, page_number: u32, allocator: std.mem.Allocator, rows: *std.ArrayList(Row)) TableError!void {
    const ref = try reader.page(page_number);
    const header = try btree.PageHeader.parse(ref);
    if (!header.page_type.isTable()) return error.UnsupportedTableBTree;

    switch (header.page_type) {
        .table_leaf => try scanLeafPage(reader, ref, header, allocator, rows),
        .table_interior => try scanInteriorPage(reader, ref, header, allocator, rows),
        else => return error.UnsupportedTableBTree,
    }
}

fn scanLeafPage(reader: page.PageReader, ref: page.PageRef, header: btree.PageHeader, allocator: std.mem.Allocator, rows: *std.ArrayList(Row)) TableError!void {
    var i: usize = 0;
    while (i < header.cell_count) : (i += 1) {
        const cell = try header.cell(ref, i);
        const row = try parseTableLeafCellWithReader(reader, cell, allocator);
        errdefer row.deinit(allocator);
        try rows.append(allocator, row);
    }
}

fn scanInteriorPage(reader: page.PageReader, ref: page.PageRef, header: btree.PageHeader, allocator: std.mem.Allocator, rows: *std.ArrayList(Row)) TableError!void {
    var i: usize = 0;
    while (i < header.cell_count) : (i += 1) {
        const cell = try header.cell(ref, i);
        if (cell.len < 5) return error.InvalidTableCell;
        const left_child = readU32(cell[0..4]);
        _ = try parseVarint(cell[4..]); // rowid separator key; validating the cell is enough here.
        try scanTablePage(reader, left_child, allocator, rows);
    }

    const right = header.right_most_pointer orelse return error.InvalidTableCell;
    try scanTablePage(reader, right, allocator, rows);
}

pub fn parseTableLeafCell(cell: []const u8, allocator: std.mem.Allocator) TableError!Row {
    const prefix = try parseTableLeafCellPrefix(cell);
    if (prefix.payload_start + prefix.payload_size > cell.len) return error.PayloadOverflowUnsupported;

    const rec = try record.parse(cell[prefix.payload_start .. prefix.payload_start + prefix.payload_size], allocator);
    return .{
        .rowid = prefix.rowid,
        .values = rec.values,
    };
}

fn parseTableLeafCellWithReader(reader: page.PageReader, cell: []const u8, allocator: std.mem.Allocator) TableError!Row {
    const prefix = try parseTableLeafCellPrefix(cell);
    const payload_info = btree.tableLeafPayloadInfo(prefix.payload_size, reader.usableSize());
    if (prefix.payload_start + payload_info.local_len > cell.len) return error.InvalidTableCell;

    if (payload_info.overflow_page == null) {
        const rec = try record.parse(cell[prefix.payload_start .. prefix.payload_start + prefix.payload_size], allocator);
        return .{
            .rowid = prefix.rowid,
            .values = rec.values,
        };
    }

    if (prefix.payload_start + payload_info.local_len + 4 > cell.len) return error.InvalidTableCell;
    var payload = try allocator.alloc(u8, prefix.payload_size);
    errdefer allocator.free(payload);

    @memcpy(payload[0..payload_info.local_len], cell[prefix.payload_start..][0..payload_info.local_len]);
    var written = payload_info.local_len;
    var next_page = readU32(cell[prefix.payload_start + payload_info.local_len ..][0..4]);
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
    return .{
        .rowid = prefix.rowid,
        .values = rec.values,
        .owned_payload = payload,
    };
}

const TableLeafCellPrefix = struct {
    payload_size: usize,
    rowid: i64,
    payload_start: usize,
};

fn parseTableLeafCellPrefix(cell: []const u8) TableError!TableLeafCellPrefix {
    const payload_size_v = try parseVarint(cell);
    const rowid_v = try parseVarint(cell[payload_size_v.len..]);
    return .{
        .payload_size = @intCast(payload_size_v.value),
        .rowid = @intCast(rowid_v.value),
        .payload_start = @as(usize, payload_size_v.len) + rowid_v.len,
    };
}

fn parseVarint(bytes: []const u8) TableError!varint.Varint {
    return varint.parse(bytes) catch |err| switch (err) {
        error.TooSmall => error.VarintTooSmall,
        error.Overflow => error.VarintOverflow,
    };
}

fn readU32(bytes: []const u8) u32 {
    return std.mem.readInt(u32, bytes[0..4], .big);
}

test "parse table leaf cell" {
    const cell = [_]u8{
        9, // payload size
        7, // rowid
        3, // record header size
        1, // int8
        23, // 5-byte text
        42,
        'a', 'l', 'i', 'c', 'e',
    };

    const row = try parseTableLeafCell(&cell, std.testing.allocator);
    defer row.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(i64, 7), row.rowid);
    try std.testing.expectEqual(@as(usize, 2), row.values.len);
    try std.testing.expectEqual(@as(i64, 42), row.values[0].integer);
    try std.testing.expectEqualStrings("alice", row.values[1].text);
}

test "scan table root leaf page" {
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
    bytes[page_base + 6] = 0xf5;
    bytes[page_base + 8] = 0x0f;
    bytes[page_base + 9] = 0xf5;

    const cell_off = 0x0ff5;
    const cell = [_]u8{ 9, 7, 3, 1, 23, 42, 'a', 'l', 'i', 'c', 'e' };
    @memcpy(bytes[cell_off..][0..cell.len], &cell);

    const reader = try page.PageReader.init(&bytes);
    const table = try scanTable(reader, 1, std.testing.allocator);
    defer table.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), table.rows.len);
    try std.testing.expectEqual(@as(i64, 7), table.rows[0].rowid);
    try std.testing.expectEqualStrings("alice", table.rows[0].values[1].text);
}
