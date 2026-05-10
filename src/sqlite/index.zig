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

/// One end of a range predicate over the first index column. `none`
/// means "unbounded on this side"; the other variants pin the bound
/// to a literal value, optionally including the value itself.
pub const IndexBound = union(enum) {
    none,
    inclusive: LookupValue,
    exclusive: LookupValue,
};

pub const RangeOptions = struct {
    low: IndexBound = .none,
    high: IndexBound = .none,
    /// Walk in descending order (`ORDER BY indexed_col DESC`).
    reverse: bool = false,
};

/// View of an index entry handed to range walk callbacks. `values`
/// borrows from the page (or, if the cell spilled to overflow pages,
/// from a transient allocation that lives until callback return).
pub const IndexEntryView = struct {
    rowid: i64,
    first_value: record.Value,
    values: []const record.Value,
};

const IndexCellView = struct {
    values: []const record.Value,
    owned: ?IndexEntry = null,

    fn deinit(self: IndexCellView, allocator: std.mem.Allocator) void {
        if (self.owned) |entry| entry.deinit(allocator);
    }
};

const FirstValueView = struct {
    value: record.Value,
    owned: ?IndexEntry = null,

    fn deinit(self: FirstValueView, allocator: std.mem.Allocator) void {
        if (self.owned) |entry| entry.deinit(allocator);
    }
};

pub const EdgeValue = struct {
    value: record.Value,
    owned: ?IndexEntry = null,

    pub fn deinit(self: EdgeValue, allocator: std.mem.Allocator) void {
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

/// LIMIT-aware variant. Stops walking once the collected rowid count
/// reaches `limit`. A `limit` of zero collects nothing.
pub fn rowidsForFirstColumnEqualsLimit(
    reader: page.PageReader,
    root_page: u32,
    value: LookupValue,
    limit: usize,
    allocator: std.mem.Allocator,
) IndexError![]i64 {
    var rowids: std.ArrayList(i64) = .empty;
    errdefer rowids.deinit(allocator);
    if (limit > 0) {
        try rowidsForFirstColumnEqualsPageLimit(reader, root_page, value, limit, allocator, &rowids);
    }
    return try rowids.toOwnedSlice(allocator);
}

/// Count index entries whose first indexed column equals `value`.
/// Traversal is constrained to b-tree ranges that can contain the key;
/// inline cells stay zero-allocation, while overflow cells may use
/// `allocator` to reconstruct their payload.
pub fn countEntriesForFirstColumnEquals(
    reader: page.PageReader,
    root_page: u32,
    value: LookupValue,
    allocator: std.mem.Allocator,
) IndexError!u64 {
    return try countEntriesForFirstColumnEqualsPage(reader, root_page, value, allocator);
}

/// Walk an index in ascending or descending first-column order over a
/// range `[low, high]`, invoking `onMatch` per matching entry. The
/// callback's `entry.values` and `entry.first_value` borrow from the
/// page (or a per-cell scratch allocation) and become invalid after
/// the callback returns — clone before stashing.
///
/// Set a `stop_after: bool` field on `ctx`'s pointee to short-circuit
/// the walk after enough rows; matches `scanTableForEach`'s pattern.
pub fn walkIndexFirstColumnRange(
    reader: page.PageReader,
    root_page: u32,
    opts: RangeOptions,
    allocator: std.mem.Allocator,
    ctx: anytype,
    comptime onMatch: fn (ctx: @TypeOf(ctx), entry: IndexEntryView) IndexError!void,
) IndexError!void {
    try walkIndexRangePage(reader, root_page, opts, allocator, ctx, onMatch);
}

/// Convenience wrapper: collect rowids from a range walk. Forward order
/// only; pass `limit` to stop early. `null` returns all matches.
pub fn rowidsForFirstColumnRange(
    reader: page.PageReader,
    root_page: u32,
    low: IndexBound,
    high: IndexBound,
    limit: ?usize,
    allocator: std.mem.Allocator,
) IndexError![]i64 {
    var collector: RowidCollector = .{
        .allocator = allocator,
        .rowids = .empty,
        .limit = limit,
        .stop_after = false,
    };
    errdefer collector.rowids.deinit(allocator);
    try walkIndexFirstColumnRange(reader, root_page, .{ .low = low, .high = high }, allocator, &collector, RowidCollector.append);
    return try collector.rowids.toOwnedSlice(allocator);
}

const RowidCollector = struct {
    allocator: std.mem.Allocator,
    rowids: std.ArrayList(i64),
    limit: ?usize,
    stop_after: bool,

    fn append(self: *RowidCollector, entry: IndexEntryView) IndexError!void {
        try self.rowids.append(self.allocator, entry.rowid);
        if (self.limit) |lim| if (self.rowids.items.len >= lim) {
            self.stop_after = true;
        };
    }
};

/// Return the first non-NULL first-column value from the left or right
/// edge of an index b-tree. This is the direct b-tree-reader version
/// of SQLite's MIN/MAX index-edge shortcut.
pub fn firstNonNullFirstColumnEdgeValue(
    reader: page.PageReader,
    root_page: u32,
    reverse: bool,
    allocator: std.mem.Allocator,
) IndexError!?EdgeValue {
    return try firstNonNullFirstColumnEdgeValuePage(reader, root_page, reverse, allocator);
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

/// True if `value` is at or above the low bound of `opts`.
fn pastLow(value: record.Value, opts: RangeOptions) bool {
    return switch (opts.low) {
        .none => true,
        .inclusive => |lv| compareValueToLookup(value, lv) >= 0,
        .exclusive => |lv| compareValueToLookup(value, lv) > 0,
    };
}

/// True if `value` is strictly above the high bound (i.e. out of
/// range on the upper side, including the case `exclusive == value`).
fn pastHigh(value: record.Value, opts: RangeOptions) bool {
    return switch (opts.high) {
        .none => false,
        .inclusive => |hv| compareValueToLookup(value, hv) > 0,
        .exclusive => |hv| compareValueToLookup(value, hv) >= 0,
    };
}

fn entryInRange(value: record.Value, opts: RangeOptions) bool {
    return pastLow(value, opts) and !pastHigh(value, opts);
}

fn rangeWalkStopRequested(ctx: anytype) bool {
    const info = @typeInfo(@TypeOf(ctx));
    if (info != .pointer) return false;
    const child = info.pointer.child;
    if (@typeInfo(child) != .@"struct") return false;
    if (@hasField(child, "stop_after")) return ctx.stop_after;
    return false;
}

fn walkIndexRangePage(
    reader: page.PageReader,
    page_number: u32,
    opts: RangeOptions,
    allocator: std.mem.Allocator,
    ctx: anytype,
    comptime onMatch: fn (ctx: @TypeOf(ctx), entry: IndexEntryView) IndexError!void,
) IndexError!void {
    if (rangeWalkStopRequested(ctx)) return;
    const ref = try reader.page(page_number);
    const header = try btree.PageHeader.parse(ref);
    if (!header.page_type.isIndex()) return error.UnsupportedIndexBTree;

    if (header.page_type == .index_leaf) {
        return walkIndexRangeLeaf(reader, ref, header, opts, allocator, ctx, onMatch);
    }

    if (opts.reverse) {
        const right = header.right_most_pointer orelse return error.InvalidIndexCell;
        try walkIndexRangePage(reader, right, opts, allocator, ctx, onMatch);
        if (rangeWalkStopRequested(ctx)) return;

        var i = header.cell_count;
        while (i > 0) {
            i -= 1;
            const cell = try header.cell(ref, i);
            if (cell.len < 4) return error.InvalidIndexCell;
            const left_child = readU32(cell[0..4]);
            var inline_rec: record.InlineRecord = undefined;
            const entry = try parseIndexCellView(reader, cell[4..], allocator, &inline_rec);
            defer entry.deinit(allocator);
            const sep_first = if (entry.values.len > 0) entry.values[0] else .null;
            const sep_above = pastHigh(sep_first, opts);
            const sep_below = !pastLow(sep_first, opts);
            if (entryInRange(sep_first, opts)) {
                if (rowidFromValues(entry.values)) |rid| {
                    try onMatch(ctx, .{ .rowid = rid, .first_value = sep_first, .values = entry.values });
                    if (rangeWalkStopRequested(ctx)) return;
                }
            }
            if (!sep_above and !sep_below) {
                try walkIndexRangePage(reader, left_child, opts, allocator, ctx, onMatch);
                if (rangeWalkStopRequested(ctx)) return;
            } else if (!sep_above and sep_below) {
                // sep is below low — nothing in left_child is in range.
            } else if (sep_above) {
                // sep is above high; left_child entries are <= sep, may include in-range.
                try walkIndexRangePage(reader, left_child, opts, allocator, ctx, onMatch);
                if (rangeWalkStopRequested(ctx)) return;
            }
            if (sep_below) return;
        }
        return;
    }

    var i: usize = 0;
    while (i < header.cell_count) : (i += 1) {
        if (rangeWalkStopRequested(ctx)) return;
        const cell = try header.cell(ref, i);
        if (cell.len < 4) return error.InvalidIndexCell;
        const left_child = readU32(cell[0..4]);
        var inline_rec: record.InlineRecord = undefined;
        const entry = try parseIndexCellView(reader, cell[4..], allocator, &inline_rec);
        defer entry.deinit(allocator);
        const sep_first = if (entry.values.len > 0) entry.values[0] else .null;
        const sep_below = !pastLow(sep_first, opts);
        const sep_above = pastHigh(sep_first, opts);

        if (!sep_below) {
            try walkIndexRangePage(reader, left_child, opts, allocator, ctx, onMatch);
            if (rangeWalkStopRequested(ctx)) return;
        }
        if (entryInRange(sep_first, opts)) {
            if (rowidFromValues(entry.values)) |rid| {
                try onMatch(ctx, .{ .rowid = rid, .first_value = sep_first, .values = entry.values });
                if (rangeWalkStopRequested(ctx)) return;
            }
        }
        if (sep_above) return;
    }

    const right = header.right_most_pointer orelse return error.InvalidIndexCell;
    try walkIndexRangePage(reader, right, opts, allocator, ctx, onMatch);
}

fn walkIndexRangeLeaf(
    reader: page.PageReader,
    ref: page.PageRef,
    header: btree.PageHeader,
    opts: RangeOptions,
    allocator: std.mem.Allocator,
    ctx: anytype,
    comptime onMatch: fn (ctx: @TypeOf(ctx), entry: IndexEntryView) IndexError!void,
) IndexError!void {
    if (header.cell_count == 0) return;

    // Binary-search for the first cell at or above the low bound.
    var lo_idx: usize = 0;
    if (opts.low != .none) {
        var lo: usize = 0;
        var hi: usize = header.cell_count;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const cell = try header.cell(ref, mid);
            const first = try parseFirstIndexValueView(reader, cell, allocator);
            defer first.deinit(allocator);
            if (!pastLow(first.value, opts)) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        lo_idx = lo;
    }

    if (opts.reverse) {
        // Walk descending starting from the upper edge — skipping cells
        // that are above the high bound — and stop once we drop below
        // the low bound.
        var i = header.cell_count;
        while (i > lo_idx) {
            i -= 1;
            if (rangeWalkStopRequested(ctx)) return;
            const cell = try header.cell(ref, i);
            var inline_rec: record.InlineRecord = undefined;
            const entry = try parseIndexCellView(reader, cell, allocator, &inline_rec);
            defer entry.deinit(allocator);
            const sep_first = if (entry.values.len > 0) entry.values[0] else .null;
            if (pastHigh(sep_first, opts)) continue;
            if (!pastLow(sep_first, opts)) break;
            if (rowidFromValues(entry.values)) |rid| {
                try onMatch(ctx, .{ .rowid = rid, .first_value = sep_first, .values = entry.values });
                if (rangeWalkStopRequested(ctx)) return;
            }
        }
        return;
    }

    var i = lo_idx;
    while (i < header.cell_count) : (i += 1) {
        if (rangeWalkStopRequested(ctx)) return;
        const cell = try header.cell(ref, i);
        var inline_rec: record.InlineRecord = undefined;
        const entry = try parseIndexCellView(reader, cell, allocator, &inline_rec);
        defer entry.deinit(allocator);
        const sep_first = if (entry.values.len > 0) entry.values[0] else .null;
        if (pastHigh(sep_first, opts)) break;
        if (!pastLow(sep_first, opts)) continue;
        if (rowidFromValues(entry.values)) |rid| {
            try onMatch(ctx, .{ .rowid = rid, .first_value = sep_first, .values = entry.values });
        }
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
        if (cmp == 0 and valuesMatchLookup(entry.values, value)) {
            if (rowidFromValues(entry.values)) |rowid| try rowids.append(allocator, rowid);
        }
        if (cmp > 0) return;
    }

    const right = header.right_most_pointer orelse return error.InvalidIndexCell;
    try rowidsForFirstColumnEqualsPage(reader, right, value, allocator, rowids);
}

fn countEntriesForFirstColumnEqualsPage(
    reader: page.PageReader,
    page_number: u32,
    value: LookupValue,
    allocator: std.mem.Allocator,
) IndexError!u64 {
    const ref = try reader.page(page_number);
    const header = try btree.PageHeader.parse(ref);
    if (!header.page_type.isIndex()) return error.UnsupportedIndexBTree;

    if (header.page_type == .index_leaf) {
        return try countEntriesForFirstColumnEqualsLeaf(reader, ref, header, value, allocator);
    }

    var count: u64 = 0;
    var i: usize = 0;
    while (i < header.cell_count) : (i += 1) {
        const cell = try header.cell(ref, i);
        if (cell.len < 4) return error.InvalidIndexCell;
        const left_child = readU32(cell[0..4]);
        const first = try parseFirstIndexValueView(reader, cell[4..], allocator);
        defer first.deinit(allocator);
        const cmp = compareValueToLookup(first.value, value);

        if (cmp >= 0) {
            count = try addCount(count, try countEntriesForFirstColumnEqualsPage(reader, left_child, value, allocator));
        }
        if (cmp == 0 and valueMatchesLookup(first.value, value)) {
            count = try addCount(count, 1);
        }
        if (cmp > 0) return count;
    }

    const right = header.right_most_pointer orelse return error.InvalidIndexCell;
    return try addCount(count, try countEntriesForFirstColumnEqualsPage(reader, right, value, allocator));
}

fn firstNonNullFirstColumnEdgeValuePage(
    reader: page.PageReader,
    page_number: u32,
    reverse: bool,
    allocator: std.mem.Allocator,
) IndexError!?EdgeValue {
    const ref = try reader.page(page_number);
    const header = try btree.PageHeader.parse(ref);
    if (!header.page_type.isIndex()) return error.UnsupportedIndexBTree;

    if (header.page_type == .index_leaf) {
        return try firstNonNullFirstColumnEdgeValueLeaf(reader, ref, header, reverse, allocator);
    }

    if (reverse) {
        const right = header.right_most_pointer orelse return error.InvalidIndexCell;
        if (try firstNonNullFirstColumnEdgeValuePage(reader, right, reverse, allocator)) |value| return value;

        var i = header.cell_count;
        while (i > 0) {
            i -= 1;
            const cell = try header.cell(ref, i);
            if (cell.len < 4) return error.InvalidIndexCell;
            if (try firstNonNullFirstColumnFromCell(reader, cell[4..], allocator)) |value| return value;
            const left_child = readU32(cell[0..4]);
            if (try firstNonNullFirstColumnEdgeValuePage(reader, left_child, reverse, allocator)) |value| return value;
        }
        return null;
    }

    var i: usize = 0;
    while (i < header.cell_count) : (i += 1) {
        const cell = try header.cell(ref, i);
        if (cell.len < 4) return error.InvalidIndexCell;
        const left_child = readU32(cell[0..4]);
        if (try firstNonNullFirstColumnEdgeValuePage(reader, left_child, reverse, allocator)) |value| return value;
        if (try firstNonNullFirstColumnFromCell(reader, cell[4..], allocator)) |value| return value;
    }

    const right = header.right_most_pointer orelse return error.InvalidIndexCell;
    return try firstNonNullFirstColumnEdgeValuePage(reader, right, reverse, allocator);
}

fn firstNonNullFirstColumnEdgeValueLeaf(
    reader: page.PageReader,
    ref: page.PageRef,
    header: btree.PageHeader,
    reverse: bool,
    allocator: std.mem.Allocator,
) IndexError!?EdgeValue {
    if (reverse) {
        var i = header.cell_count;
        while (i > 0) {
            i -= 1;
            const cell = try header.cell(ref, i);
            if (try firstNonNullFirstColumnFromCell(reader, cell, allocator)) |value| return value;
        }
        return null;
    }

    var i: usize = 0;
    while (i < header.cell_count) : (i += 1) {
        const cell = try header.cell(ref, i);
        if (try firstNonNullFirstColumnFromCell(reader, cell, allocator)) |value| return value;
    }
    return null;
}

fn firstNonNullFirstColumnFromCell(reader: page.PageReader, cell: []const u8, allocator: std.mem.Allocator) IndexError!?EdgeValue {
    const first = try parseFirstIndexValueView(reader, cell, allocator);
    if (first.value == .null) {
        first.deinit(allocator);
        return null;
    }
    return .{ .value = first.value, .owned = first.owned };
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
        const first = try parseFirstIndexValueView(reader, cell, allocator);
        defer first.deinit(allocator);
        if (compareValueToLookup(first.value, value) < 0) {
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

fn rowidsForFirstColumnEqualsPageLimit(
    reader: page.PageReader,
    page_number: u32,
    value: LookupValue,
    limit: usize,
    allocator: std.mem.Allocator,
    rowids: *std.ArrayList(i64),
) IndexError!void {
    if (rowids.items.len >= limit) return;
    const ref = try reader.page(page_number);
    const header = try btree.PageHeader.parse(ref);
    if (!header.page_type.isIndex()) return error.UnsupportedIndexBTree;

    if (header.page_type == .index_leaf) {
        return rowidsForFirstColumnEqualsLeafLimit(reader, ref, header, value, limit, allocator, rowids);
    }

    var i: usize = 0;
    while (i < header.cell_count) : (i += 1) {
        if (rowids.items.len >= limit) return;
        const cell = try header.cell(ref, i);
        if (cell.len < 4) return error.InvalidIndexCell;
        const left_child = readU32(cell[0..4]);
        var inline_rec: record.InlineRecord = undefined;
        const entry = try parseIndexCellView(reader, cell[4..], allocator, &inline_rec);
        defer entry.deinit(allocator);
        const cmp = compareFirstValueToLookup(entry.values, value);

        if (cmp >= 0) {
            try rowidsForFirstColumnEqualsPageLimit(reader, left_child, value, limit, allocator, rowids);
            if (rowids.items.len >= limit) return;
        }
        if (cmp == 0 and valuesMatchLookup(entry.values, value)) {
            if (rowidFromValues(entry.values)) |rowid| {
                try rowids.append(allocator, rowid);
                if (rowids.items.len >= limit) return;
            }
        }
        if (cmp > 0) return;
    }

    const right = header.right_most_pointer orelse return error.InvalidIndexCell;
    try rowidsForFirstColumnEqualsPageLimit(reader, right, value, limit, allocator, rowids);
}

fn rowidsForFirstColumnEqualsLeafLimit(
    reader: page.PageReader,
    ref: page.PageRef,
    header: btree.PageHeader,
    value: LookupValue,
    limit: usize,
    allocator: std.mem.Allocator,
    rowids: *std.ArrayList(i64),
) IndexError!void {
    if (rowids.items.len >= limit) return;
    var lo: usize = 0;
    var hi: usize = header.cell_count;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const cell = try header.cell(ref, mid);
        const first = try parseFirstIndexValueView(reader, cell, allocator);
        defer first.deinit(allocator);
        if (compareValueToLookup(first.value, value) < 0) {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }

    var i = lo;
    while (i < header.cell_count) : (i += 1) {
        if (rowids.items.len >= limit) return;
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

fn countEntriesForFirstColumnEqualsLeaf(
    reader: page.PageReader,
    ref: page.PageRef,
    header: btree.PageHeader,
    value: LookupValue,
    allocator: std.mem.Allocator,
) IndexError!u64 {
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

    var count: u64 = 0;
    var i = lo;
    while (i < header.cell_count) : (i += 1) {
        const cell = try header.cell(ref, i);
        const first = try parseFirstIndexValueView(reader, cell, allocator);
        defer first.deinit(allocator);
        const cmp = compareValueToLookup(first.value, value);
        if (cmp > 0) break;
        if (cmp == 0 and valueMatchesLookup(first.value, value)) {
            count = try addCount(count, 1);
        }
    }
    return count;
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

fn parseFirstIndexValueView(
    reader: page.PageReader,
    cell: []const u8,
    allocator: std.mem.Allocator,
) IndexError!FirstValueView {
    const payload_size_v = try parseVarint(cell);
    const payload_size: usize = @intCast(payload_size_v.value);
    const payload_start: usize = payload_size_v.len;
    const payload_info = btree.indexPayloadInfo(payload_size, reader.usableSize());
    if (payload_start + payload_info.local_len > cell.len) return error.InvalidIndexCell;

    if (payload_info.overflow_page == null) {
        return .{ .value = try parseRecordFirstValue(cell[payload_start..][0..payload_size]) };
    }

    const entry = try parseIndexCellWithReader(reader, cell, allocator);
    const first: record.Value = if (entry.values.len > 0) entry.values[0] else .null;
    return .{ .value = first, .owned = entry };
}

fn parseRecordFirstValue(bytes: []const u8) IndexError!record.Value {
    const header_size_v = try parseVarint(bytes);
    const header_size: usize = @intCast(header_size_v.value);
    if (header_size == 0 or header_size > bytes.len) return error.InvalidHeaderSize;
    if (header_size_v.len >= header_size) return .null;

    const serial = try parseVarint(bytes[header_size_v.len..header_size]);
    return try decodeRecordValue(serial.value, bytes[header_size..]);
}

fn decodeRecordValue(serial: u64, bytes: []const u8) IndexError!record.Value {
    return switch (serial) {
        0 => .null,
        1 => .{ .integer = try readSigned(bytes, 1) },
        2 => .{ .integer = try readSigned(bytes, 2) },
        3 => .{ .integer = try readSigned(bytes, 3) },
        4 => .{ .integer = try readSigned(bytes, 4) },
        5 => .{ .integer = try readSigned(bytes, 6) },
        6 => .{ .integer = try readSigned(bytes, 8) },
        7 => blk: {
            if (bytes.len < 8) return error.ValueOutOfBounds;
            const raw = std.mem.readInt(u64, bytes[0..8], .big);
            break :blk .{ .real = @bitCast(raw) };
        },
        8 => .{ .integer = 0 },
        9 => .{ .integer = 1 },
        10, 11 => error.InvalidSerialType,
        else => blk: {
            const len: usize = if (serial % 2 == 0)
                @intCast((serial - 12) / 2)
            else
                @intCast((serial - 13) / 2);
            if (bytes.len < len) return error.ValueOutOfBounds;
            if (serial % 2 == 0) {
                break :blk .{ .blob = bytes[0..len] };
            } else {
                break :blk .{ .text = bytes[0..len] };
            }
        },
    };
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
    return valueMatchesLookup(values[0], value);
}

fn valueMatchesLookup(actual_value: record.Value, value: LookupValue) bool {
    return switch (value) {
        .null => actual_value == .null,
        .integer => |expected| switch (actual_value) {
            .integer => |actual| actual == expected,
            else => false,
        },
        .text => |expected| switch (actual_value) {
            .text => |actual| std.mem.eql(u8, actual, expected),
            else => false,
        },
    };
}

fn compareFirstValueToLookup(values: []const record.Value, lookup: LookupValue) i8 {
    const first: record.Value = if (values.len > 0) values[0] else .null;
    return compareValueToLookup(first, lookup);
}

fn compareValueToLookup(first: record.Value, lookup: LookupValue) i8 {
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

fn readSigned(bytes: []const u8, len: usize) IndexError!i64 {
    if (bytes.len < len) return error.ValueOutOfBounds;
    var value: i64 = if ((bytes[0] & 0x80) != 0) -1 else 0;
    for (bytes[0..len]) |b| {
        value = (value << 8) | @as(i64, b);
    }
    return value;
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

fn addCount(a: u64, b: u64) IndexError!u64 {
    return std.math.add(u64, a, b) catch error.Overflow;
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
    const cell = [_]u8{ 7, 3, 19, 1, 'b', 'o', 'b', 7 };
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
        &.{ 7, 3, 19, 1, 'b', 'o', 'b', 7 },
        &.{ 7, 3, 19, 1, 'b', 'o', 'b', 8 },
        &.{ 7, 3, 19, 1, 'z', 'e', 'd', 9 },
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

test "countEntriesForFirstColumnEquals returns matching leaf count without allocations" {
    var bytes = [_]u8{0} ** 4096;
    initIndexTestHeader(bytes[0..], 4096, 1);

    const cells = [_][]const u8{
        &.{ 8, 3, 23, 9, 'a', 'l', 'i', 'c', 'e' },
        &.{ 7, 3, 19, 1, 'b', 'o', 'b', 7 },
        &.{ 7, 3, 19, 1, 'b', 'o', 'b', 8 },
        &.{ 7, 3, 19, 1, 'z', 'e', 'd', 9 },
    };
    writeIndexLeafPageTest(bytes[0..], 0, 100, 4096, &cells);

    const reader = try page.PageReader.init(&bytes);
    var failing_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const allocator = failing_allocator.allocator();

    try std.testing.expectEqual(
        @as(u64, 2),
        try countEntriesForFirstColumnEquals(reader, 1, .{ .text = "bob" }, allocator),
    );
    try std.testing.expectEqual(
        @as(u64, 0),
        try countEntriesForFirstColumnEquals(reader, 1, .{ .text = "carol" }, allocator),
    );
    try std.testing.expectEqual(@as(usize, 0), failing_allocator.allocations);
}

test "countEntriesForFirstColumnEquals counts matching interior separators and bounded children" {
    const page_size = 4096;
    var bytes = [_]u8{0} ** (page_size * 3);
    initIndexTestHeader(bytes[0..], page_size, 3);

    const left_cells = [_][]const u8{
        &.{ 8, 3, 23, 9, 'a', 'l', 'i', 'c', 'e' },
        &.{ 7, 3, 19, 1, 'b', 'o', 'b', 7 },
    };
    const right_cells = [_][]const u8{
        &.{ 7, 3, 19, 1, 'b', 'o', 'b', 9 },
        &.{ 7, 3, 19, 1, 'z', 'e', 'd', 10 },
    };
    const separator = [_]u8{ 7, 3, 19, 1, 'b', 'o', 'b', 8 };

    writeIndexInteriorRootTest(bytes[0..], page_size, 2, 3, &separator);
    writeIndexLeafPageTest(bytes[0..], page_size, 0, page_size, &left_cells);
    writeIndexLeafPageTest(bytes[0..], page_size * 2, 0, page_size, &right_cells);

    const reader = try page.PageReader.init(&bytes);
    try std.testing.expectEqual(
        @as(u64, 3),
        try countEntriesForFirstColumnEquals(reader, 1, .{ .text = "bob" }, std.testing.allocator),
    );
    try std.testing.expectEqual(
        @as(u64, 1),
        try countEntriesForFirstColumnEquals(reader, 1, .{ .text = "alice" }, std.testing.allocator),
    );
    try std.testing.expectEqual(
        @as(u64, 0),
        try countEntriesForFirstColumnEquals(reader, 1, .{ .text = "carol" }, std.testing.allocator),
    );
}

test "firstNonNullFirstColumnEdgeValue reads min and max index edges" {
    var bytes = [_]u8{0} ** 4096;
    initIndexTestHeader(bytes[0..], 4096, 1);

    const cells = [_][]const u8{
        &.{ 4, 3, 0, 1, 5 },
        &.{ 5, 3, 1, 1, 42, 7 },
        &.{ 7, 3, 19, 1, 'b', 'o', 'b', 8 },
    };
    writeIndexLeafPageTest(bytes[0..], 0, 100, 4096, &cells);

    const reader = try page.PageReader.init(&bytes);
    const min_value = (try firstNonNullFirstColumnEdgeValue(reader, 1, false, std.testing.allocator)).?;
    defer min_value.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(i64, 42), min_value.value.integer);

    const max_value = (try firstNonNullFirstColumnEdgeValue(reader, 1, true, std.testing.allocator)).?;
    defer max_value.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("bob", max_value.value.text);
}

test "firstNonNullFirstColumnEdgeValue returns null for all-null index" {
    var bytes = [_]u8{0} ** 4096;
    initIndexTestHeader(bytes[0..], 4096, 1);

    const cells = [_][]const u8{
        &.{ 4, 3, 0, 1, 5 },
        &.{ 4, 3, 0, 1, 7 },
    };
    writeIndexLeafPageTest(bytes[0..], 0, 100, 4096, &cells);

    const reader = try page.PageReader.init(&bytes);
    try std.testing.expectEqual(@as(?EdgeValue, null), try firstNonNullFirstColumnEdgeValue(reader, 1, false, std.testing.allocator));
    try std.testing.expectEqual(@as(?EdgeValue, null), try firstNonNullFirstColumnEdgeValue(reader, 1, true, std.testing.allocator));
}

fn initIndexTestHeader(bytes: []u8, comptime page_size: u16, page_count: u32) void {
    @memcpy(bytes[0..16], @import("header.zig").MAGIC);
    std.mem.writeInt(u16, bytes[16..18], page_size, .big);
    bytes[18] = 1;
    bytes[19] = 1;
    bytes[21] = 64;
    bytes[22] = 32;
    bytes[23] = 32;
    std.mem.writeInt(u32, bytes[28..32], page_count, .big);
}

fn writeIndexLeafPageTest(
    bytes: []u8,
    page_start: usize,
    header_offset: usize,
    comptime page_size: usize,
    cells: []const []const u8,
) void {
    const page_base = page_start + header_offset;
    bytes[page_base + 0] = @intFromEnum(btree.PageType.index_leaf);
    std.mem.writeInt(u16, bytes[page_base + 3 ..][0..2], @intCast(cells.len), .big);

    var off: usize = page_size;
    for (cells, 0..) |cell, i| {
        off -= cell.len;
        @memcpy(bytes[page_start + off ..][0..cell.len], cell);
        std.mem.writeInt(u16, bytes[page_base + 8 + i * 2 ..][0..2], @intCast(off), .big);
    }
    std.mem.writeInt(u16, bytes[page_base + 5 ..][0..2], @intCast(off), .big);
}

fn writeIndexInteriorRootTest(
    bytes: []u8,
    comptime page_size: usize,
    left_child: u32,
    right_child: u32,
    separator: []const u8,
) void {
    const page_base = 100;
    const cell_off = page_size - 4 - separator.len;
    bytes[page_base + 0] = @intFromEnum(btree.PageType.index_interior);
    std.mem.writeInt(u16, bytes[page_base + 3 ..][0..2], 1, .big);
    std.mem.writeInt(u16, bytes[page_base + 5 ..][0..2], @intCast(cell_off), .big);
    std.mem.writeInt(u32, bytes[page_base + 8 ..][0..4], right_child, .big);
    std.mem.writeInt(u16, bytes[page_base + 12 ..][0..2], @intCast(cell_off), .big);
    std.mem.writeInt(u32, bytes[cell_off..][0..4], left_child, .big);
    @memcpy(bytes[cell_off + 4 ..][0..separator.len], separator);
}

test "rowidsForFirstColumnEqualsLimit stops at the requested count" {
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
        &.{ 7, 3, 19, 1, 'b', 'o', 'b', 7 },
        &.{ 7, 3, 19, 1, 'b', 'o', 'b', 8 },
        &.{ 7, 3, 19, 1, 'z', 'e', 'd', 9 },
    };

    var off: usize = bytes.len;
    for (cells, 0..) |cell, i| {
        off -= cell.len;
        @memcpy(bytes[off..][0..cell.len], cell);
        std.mem.writeInt(u16, bytes[page_base + 8 + i * 2 ..][0..2], @intCast(off), .big);
    }
    std.mem.writeInt(u16, bytes[page_base + 5 ..][0..2], @intCast(off), .big);

    const reader = try page.PageReader.init(&bytes);

    const limited = try rowidsForFirstColumnEqualsLimit(reader, 1, .{ .text = "bob" }, 1, std.testing.allocator);
    defer std.testing.allocator.free(limited);
    try std.testing.expectEqual(@as(usize, 1), limited.len);
    try std.testing.expectEqual(@as(i64, 7), limited[0]);

    const all = try rowidsForFirstColumnEqualsLimit(reader, 1, .{ .text = "bob" }, 99, std.testing.allocator);
    defer std.testing.allocator.free(all);
    try std.testing.expectEqual(@as(usize, 2), all.len);

    const zero = try rowidsForFirstColumnEqualsLimit(reader, 1, .{ .text = "bob" }, 0, std.testing.allocator);
    defer std.testing.allocator.free(zero);
    try std.testing.expectEqual(@as(usize, 0), zero.len);
}
