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
    TooManyColumns,
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

/// Zero-allocation row-at-a-time table scan. For each row on each
/// leaf, calls `onRow(ctx, rowid, values)` with a stack-allocated
/// view. Text/blob slices inside `values` point directly into the
/// backing page buffer, so they're valid until the next callback
/// invocation AT MOST — callers that need to retain values must
/// copy them out.
///
/// Bails out with `error.TooManyColumns` on rows wider than
/// `record.MAX_INLINE_VALUES` (default 64) without falling back; for
/// the query executor we still use the allocating `scanTable`. This
/// path is built for hot aggregation / bench loops.
///
/// Overflow payloads aren't supported here either — rows that spill
/// past the leaf page return `error.PayloadOverflowUnsupported`.
pub fn scanTableForEach(
    reader: page.PageReader,
    root_page: u32,
    ctx: anytype,
    comptime onRow: fn (ctx: @TypeOf(ctx), rowid: i64, values: []const record.Value) anyerror!void,
) anyerror!void {
    try scanTableForEachPage(reader, root_page, ctx, onRow);
}

/// Row-at-a-time table scan that supports overflow payloads. Unlike
/// `scanTable`, this does not materialise the whole table; unlike
/// `scanTableForEach`, it may allocate for each row whose payload
/// spills to overflow pages.
pub fn scanTableForEachAlloc(
    reader: page.PageReader,
    root_page: u32,
    allocator: std.mem.Allocator,
    ctx: anytype,
    comptime onRow: fn (ctx: @TypeOf(ctx), rowid: i64, values: []const record.Value) anyerror!void,
) anyerror!void {
    try scanTableForEachAllocPage(reader, root_page, allocator, ctx, onRow);
}

fn scanTableForEachPage(
    reader: page.PageReader,
    page_number: u32,
    ctx: anytype,
    comptime onRow: fn (ctx: @TypeOf(ctx), rowid: i64, values: []const record.Value) anyerror!void,
) anyerror!void {
    const ref = try reader.page(page_number);
    const header = try btree.PageHeader.parse(ref);
    switch (header.page_type) {
        .table_leaf => {
            var inline_rec: record.InlineRecord = undefined;
            var i: usize = 0;
            while (i < header.cell_count) : (i += 1) {
                const cell = try header.cell(ref, i);
                const prefix = try parseTableLeafCellPrefix(cell);
                if (prefix.payload_start + prefix.payload_size > cell.len) return error.PayloadOverflowUnsupported;
                try record.parseInline(cell[prefix.payload_start .. prefix.payload_start + prefix.payload_size], &inline_rec);
                try onRow(ctx, prefix.rowid, inline_rec.slice());
                if (scanShouldStop(ctx)) return;
            }
        },
        .table_interior => {
            var i: usize = 0;
            while (i < header.cell_count) : (i += 1) {
                const cell = try header.cell(ref, i);
                if (cell.len < 5) return error.InvalidTableCell;
                const left_child = readU32(cell[0..4]);
                _ = try parseVarint(cell[4..]);
                try scanTableForEachPage(reader, left_child, ctx, onRow);
                if (scanShouldStop(ctx)) return;
            }
            const right = header.right_most_pointer orelse return error.InvalidTableCell;
            try scanTableForEachPage(reader, right, ctx, onRow);
        },
        else => return error.UnsupportedTableBTree,
    }
}

fn scanTableForEachAllocPage(
    reader: page.PageReader,
    page_number: u32,
    allocator: std.mem.Allocator,
    ctx: anytype,
    comptime onRow: fn (ctx: @TypeOf(ctx), rowid: i64, values: []const record.Value) anyerror!void,
) anyerror!void {
    const ref = try reader.page(page_number);
    const header = try btree.PageHeader.parse(ref);
    switch (header.page_type) {
        .table_leaf => {
            var i: usize = 0;
            while (i < header.cell_count) : (i += 1) {
                const cell = try header.cell(ref, i);
                const row = try parseTableLeafCellWithReader(reader, cell, allocator);
                defer row.deinit(allocator);
                try onRow(ctx, row.rowid, row.values);
                if (scanShouldStop(ctx)) return;
            }
        },
        .table_interior => {
            var i: usize = 0;
            while (i < header.cell_count) : (i += 1) {
                const cell = try header.cell(ref, i);
                if (cell.len < 5) return error.InvalidTableCell;
                const left_child = readU32(cell[0..4]);
                _ = try parseVarint(cell[4..]);
                try scanTableForEachAllocPage(reader, left_child, allocator, ctx, onRow);
                if (scanShouldStop(ctx)) return;
            }
            const right = header.right_most_pointer orelse return error.InvalidTableCell;
            try scanTableForEachAllocPage(reader, right, allocator, ctx, onRow);
        },
        else => return error.UnsupportedTableBTree,
    }
}

fn scanShouldStop(ctx: anytype) bool {
    const info = @typeInfo(@TypeOf(ctx));
    if (info != .pointer) return false;
    const child = info.pointer.child;
    if (@typeInfo(child) != .@"struct") return false;
    if (@hasField(child, "stop_after")) return ctx.stop_after;
    return false;
}

/// Count the number of rows in `root_page`'s table by summing leaf
/// cell counts from the b-tree header — no per-row parse, no
/// allocation. Matches what SQLite's `SELECT COUNT(*)` compiles down
/// to when there's no WHERE clause.
pub fn countRows(reader: page.PageReader, root_page: u32) TableError!u64 {
    var total: u64 = 0;
    try countRowsPage(reader, root_page, &total);
    return total;
}

fn countRowsPage(reader: page.PageReader, page_number: u32, total: *u64) TableError!void {
    const ref = try reader.page(page_number);
    const header = try btree.PageHeader.parse(ref);
    switch (header.page_type) {
        .table_leaf => total.* += header.cell_count,
        .table_interior => {
            var i: usize = 0;
            while (i < header.cell_count) : (i += 1) {
                const cell = try header.cell(ref, i);
                if (cell.len < 5) return error.InvalidTableCell;
                const left_child = readU32(cell[0..4]);
                try countRowsPage(reader, left_child, total);
            }
            const right = header.right_most_pointer orelse return error.InvalidTableCell;
            try countRowsPage(reader, right, total);
        },
        else => return error.UnsupportedTableBTree,
    }
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
    var lo: usize = 0;
    var hi: usize = header.cell_count;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const cell = try header.cell(ref, mid);
        if (cell.len < 5) return error.InvalidTableCell;
        const sep = try parseVarint(cell[4..]);
        if (wanted_rowid <= @as(i64, @intCast(sep.value))) {
            hi = mid;
        } else {
            lo = mid + 1;
        }
    }

    if (lo < header.cell_count) {
        const cell = try header.cell(ref, lo);
        if (cell.len < 5) return error.InvalidTableCell;
        const left_child = readU32(cell[0..4]);
        return try findRowInPage(reader, left_child, wanted_rowid, allocator);
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
        'a',
        'l',
        'i',
        'c',
        'e',
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

test "scan table foreach stops after caller sets stop_after" {
    var bytes = [_]u8{0} ** 4096;
    initTestHeader(bytes[0..], 4096, 1);

    const page_base = 100;
    bytes[page_base + 0] = @intFromEnum(btree.PageType.table_leaf);
    bytes[page_base + 3] = 0;
    bytes[page_base + 4] = 2;

    const cell_1 = [_]u8{ 5, 1, 3, 1, 1, 10, 20 };
    const cell_2 = [_]u8{ 5, 2, 3, 1, 1, 30, 40 };
    const cell_2_off = 4096 - cell_2.len;
    const cell_1_off = cell_2_off - cell_1.len;
    writeU16Test(bytes[page_base + 5 ..][0..2], @intCast(cell_1_off));
    writeU16Test(bytes[page_base + 8 ..][0..2], @intCast(cell_1_off));
    writeU16Test(bytes[page_base + 10 ..][0..2], @intCast(cell_2_off));
    @memcpy(bytes[cell_1_off..][0..cell_1.len], &cell_1);
    @memcpy(bytes[cell_2_off..][0..cell_2.len], &cell_2);

    const reader = try page.PageReader.init(&bytes);
    const Ctx = struct {
        count: usize = 0,
        last_rowid: i64 = 0,
        stop_after: bool = false,

        fn onRow(ctx: *@This(), rowid: i64, values: []const record.Value) !void {
            try std.testing.expectEqual(@as(usize, 2), values.len);
            ctx.count += 1;
            ctx.last_rowid = rowid;
            ctx.stop_after = true;
        }
    };
    var ctx: Ctx = .{};
    try scanTableForEach(reader, 1, &ctx, Ctx.onRow);

    try std.testing.expectEqual(@as(usize, 1), ctx.count);
    try std.testing.expectEqual(@as(i64, 1), ctx.last_rowid);
}

test "scan table foreach alloc reads overflow payload" {
    const page_size = 512;
    var bytes = [_]u8{0} ** (page_size * 2);
    initTestHeader(bytes[0..], page_size, 2);

    var payload = [_]u8{0} ** 600;
    payload[0] = 3; // header size: one byte for size + two-byte serial type
    _ = encodeVarintTest(payload[1..], 1206); // blob length: (1206 - 12) / 2 = 597
    @memset(payload[3..], 0xab);

    const payload_info = btree.tableLeafPayloadInfo(payload.len, page_size);
    try std.testing.expect(payload_info.overflow_page != null);

    var cell_1: [128]u8 = undefined;
    var cpos: usize = 0;
    cpos += encodeVarintTest(cell_1[cpos..], payload.len);
    cpos += encodeVarintTest(cell_1[cpos..], 1);
    @memcpy(cell_1[cpos..][0..payload_info.local_len], payload[0..payload_info.local_len]);
    cpos += payload_info.local_len;
    writeU32Test(cell_1[cpos..][0..4], 2);
    cpos += 4;

    const cell_2 = [_]u8{ 3, 2, 2, 1, 7 };
    const cell_1_off = page_size - cpos;
    const cell_2_off = cell_1_off - cell_2.len;

    const page_base = 100;
    bytes[page_base + 0] = @intFromEnum(btree.PageType.table_leaf);
    bytes[page_base + 3] = 0;
    bytes[page_base + 4] = 2;
    writeU16Test(bytes[page_base + 5 ..][0..2], @intCast(cell_2_off));
    writeU16Test(bytes[page_base + 8 ..][0..2], @intCast(cell_1_off));
    writeU16Test(bytes[page_base + 10 ..][0..2], @intCast(cell_2_off));
    @memcpy(bytes[cell_1_off..][0..cpos], cell_1[0..cpos]);
    @memcpy(bytes[cell_2_off..][0..cell_2.len], &cell_2);

    const overflow_base = page_size;
    writeU32Test(bytes[overflow_base..][0..4], 0);
    @memcpy(bytes[overflow_base + 4 ..][0 .. payload.len - payload_info.local_len], payload[payload_info.local_len..]);

    const reader = try page.PageReader.init(&bytes);
    const Ctx = struct {
        count: usize = 0,
        blob_len: usize = 0,
        stop_after: bool = false,

        fn onRow(ctx: *@This(), rowid: i64, values: []const record.Value) !void {
            try std.testing.expectEqual(@as(i64, 1), rowid);
            try std.testing.expectEqual(@as(usize, 1), values.len);
            try std.testing.expect(values[0] == .blob);
            try std.testing.expectEqual(@as(usize, 597), values[0].blob.len);
            try std.testing.expectEqual(@as(u8, 0xab), values[0].blob[0]);
            ctx.count += 1;
            ctx.blob_len = values[0].blob.len;
            ctx.stop_after = true;
        }
    };
    var ctx: Ctx = .{};
    try scanTableForEachAlloc(reader, 1, std.testing.allocator, &ctx, Ctx.onRow);

    try std.testing.expectEqual(@as(usize, 1), ctx.count);
    try std.testing.expectEqual(@as(usize, 597), ctx.blob_len);
}

fn initTestHeader(bytes: []u8, comptime page_size: u16, page_count: u32) void {
    @memcpy(bytes[0..16], @import("header.zig").MAGIC);
    writeU16Test(bytes[16..18], page_size);
    bytes[18] = 1;
    bytes[19] = 1;
    bytes[21] = 64;
    bytes[22] = 32;
    bytes[23] = 32;
    writeU32Test(bytes[28..32], page_count);
}

fn writeU16Test(bytes: []u8, value: u16) void {
    std.mem.writeInt(u16, bytes[0..2], value, .big);
}

fn writeU32Test(bytes: []u8, value: u32) void {
    std.mem.writeInt(u32, bytes[0..4], value, .big);
}

fn encodeVarintTest(dst: []u8, value: u64) usize {
    var buf: [9]u8 = undefined;
    var tmp = value;
    var len: usize = 1;
    while (tmp > 0x7f and len < 9) : (len += 1) tmp >>= 7;

    var i = len;
    tmp = value;
    while (i > 0) {
        i -= 1;
        buf[i] = @intCast(tmp & 0x7f);
        if (i != len - 1) buf[i] |= 0x80;
        tmp >>= 7;
    }

    @memcpy(dst[0..len], buf[0..len]);
    return len;
}
