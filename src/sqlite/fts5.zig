const std = @import("std");

const fts5_bm25 = @import("fts5_bm25.zig");
const index = @import("index.zig");
const page = @import("page.zig");
const record = @import("record.zig");
const schema_mod = @import("schema.zig");
const table = @import("table.zig");
const varint = @import("varint.zig");

pub const MAX_COLUMNS: usize = 16;

pub const SearchOptions = struct {
    limit: usize = 10,
    weights: []const f64 = &.{},
};

pub const ResultRow = struct {
    rowid: u64,
    score: f64,
    hits: u32,
    doc_len: u64,
    column_hits: [MAX_COLUMNS]u32,
};

pub const SearchResult = struct {
    table_name: []const u8,
    query: []const u8,
    total_rows: u64,
    rows_with_term: u64,
    total_hits: u64,
    avg_doc_len: f64,
    column_count: usize,
    rows: []ResultRow,

    pub fn deinit(self: SearchResult, allocator: std.mem.Allocator) void {
        allocator.free(self.rows);
    }
};

const Segment = struct {
    segid: u64,
    first: u32,
    last: u32,
};

const Averages = struct {
    total_rows: u64,
    column_count: usize,
    column_tokens: [MAX_COLUMNS]u64,

    fn avgDocLen(self: Averages) f64 {
        if (self.total_rows == 0) return 0;
        var total: u64 = 0;
        for (self.column_tokens[0..self.column_count]) |n| total += n;
        return @as(f64, @floatFromInt(total)) / @as(f64, @floatFromInt(self.total_rows));
    }
};

const Posting = struct {
    column_hits: [MAX_COLUMNS]u32,
};

const PendingPoslist = struct {
    rowid: u64,
    bytes: std.ArrayList(u8),
    remaining: usize,
};

const DoclistParser = struct {
    allocator: std.mem.Allocator,
    postings: *std.AutoHashMap(u64, Posting),
    column_count: usize,
    last_rowid: u64 = 0,
    pending: ?PendingPoslist = null,

    fn init(allocator: std.mem.Allocator, postings: *std.AutoHashMap(u64, Posting), column_count: usize) DoclistParser {
        return .{
            .allocator = allocator,
            .postings = postings,
            .column_count = column_count,
        };
    }

    fn deinit(self: *DoclistParser) void {
        if (self.pending) |*pending| pending.bytes.deinit(self.allocator);
        self.pending = null;
    }

    fn hasPending(self: *const DoclistParser) bool {
        return self.pending != null;
    }

    fn parseRows(self: *DoclistParser, bytes: []const u8, first_rowid_absolute: bool) !void {
        var pos: usize = 0;
        var first = true;
        while (pos < bytes.len) {
            if (self.pending != null) return error.InvalidFts5Doclist;

            const rowid_v = try parseVarint(bytes[pos..]);
            pos += rowid_v.len;
            const rowid = if (first_rowid_absolute and first)
                rowid_v.value
            else
                self.last_rowid + rowid_v.value;
            self.last_rowid = rowid;
            first = false;

            const npos_v = try parseVarint(bytes[pos..]);
            pos += npos_v.len;
            const poslist_len: usize = @intCast(npos_v.value >> 1);
            if (poslist_len == 0) {
                _ = self.postings.remove(rowid);
                continue;
            }

            if (pos + poslist_len <= bytes.len) {
                try self.putPosting(rowid, bytes[pos .. pos + poslist_len]);
                pos += poslist_len;
            } else {
                var pending_bytes: std.ArrayList(u8) = .empty;
                errdefer pending_bytes.deinit(self.allocator);
                try pending_bytes.appendSlice(self.allocator, bytes[pos..]);
                self.pending = .{
                    .rowid = rowid,
                    .bytes = pending_bytes,
                    .remaining = pos + poslist_len - bytes.len,
                };
                return;
            }
        }
    }

    fn feedPoslistTail(self: *DoclistParser, bytes: []const u8) !void {
        if (bytes.len == 0) return;
        if (self.pending == null) return;

        var pending = &self.pending.?;
        const take = @min(bytes.len, pending.remaining);
        try pending.bytes.appendSlice(self.allocator, bytes[0..take]);
        pending.remaining -= take;
        if (pending.remaining == 0) {
            try self.putPosting(pending.rowid, pending.bytes.items);
            pending.bytes.deinit(self.allocator);
            self.pending = null;
        }
    }

    fn putPosting(self: *DoclistParser, rowid: u64, poslist: []const u8) !void {
        var hits = [_]u32{0} ** MAX_COLUMNS;
        try parsePoslist(poslist, self.column_count, &hits);
        var total: u32 = 0;
        for (hits[0..self.column_count]) |n| total += n;
        if (total == 0) {
            _ = self.postings.remove(rowid);
            return;
        }

        const gop = try self.postings.getOrPut(rowid);
        gop.value_ptr.* = .{ .column_hits = hits };
    }
};

const LeafInfo = struct {
    rowid_offset: usize,
    content_size: usize,
    first_term_offset: ?usize,
};

const TermSpan = struct {
    doc_start: usize,
    doc_end: usize,
    content_size: usize,
    is_last: bool,
};

pub fn search(
    reader: page.PageReader,
    schema: schema_mod.Schema,
    fts_table: []const u8,
    query: []const u8,
    options: SearchOptions,
    allocator: std.mem.Allocator,
) !SearchResult {
    if (options.limit == 0) {
        const rows = try allocator.alloc(ResultRow, 0);
        return .{
            .table_name = fts_table,
            .query = query,
            .total_rows = 0,
            .rows_with_term = 0,
            .total_hits = 0,
            .avg_doc_len = 0,
            .column_count = 0,
            .rows = rows,
        };
    }

    const data_entry = try shadowTable(schema, fts_table, "data", allocator);
    const idx_entry = try shadowTable(schema, fts_table, "idx", allocator);
    const docsize_entry = try shadowTable(schema, fts_table, "docsize", allocator);

    const term = try normalizeBareTerm(query, allocator);
    defer allocator.free(term);

    const averages = try loadAverages(reader, @intCast(data_entry.root_page), allocator);
    const doc_lengths = try loadDocLengths(reader, @intCast(docsize_entry.root_page), averages.total_rows, averages.column_count, allocator);
    defer allocator.free(doc_lengths);

    const segments = try loadSegments(reader, @intCast(data_entry.root_page), allocator);
    defer allocator.free(segments);

    var candidate_pages = try candidatePages(reader, @intCast(idx_entry.root_page), term, allocator);
    defer candidate_pages.deinit();

    var postings = std.AutoHashMap(u64, Posting).init(allocator);
    defer postings.deinit();

    for (segments) |segment| {
        try readSegmentTerm(reader, @intCast(data_entry.root_page), segment, candidate_pages, term, averages.column_count, &postings, allocator);
    }

    const rows_with_term: u64 = postings.count();
    const avg_doc_len = averages.avgDocLen();
    const top_limit = @min(options.limit, postings.count());
    const top = try allocator.alloc(ResultRow, top_limit);
    errdefer allocator.free(top);
    var top_len: usize = 0;

    var total_hits: u64 = 0;
    var it = postings.iterator();
    while (it.next()) |entry| {
        const rowid = entry.key_ptr.*;
        const posting = entry.value_ptr.*;
        var hit_count: u32 = 0;
        var weighted_hits: f64 = 0;
        for (posting.column_hits[0..averages.column_count], 0..) |hits, i| {
            hit_count += hits;
            const weight = if (i < options.weights.len) options.weights[i] else 1.0;
            weighted_hits += @as(f64, @floatFromInt(hits)) * weight;
        }
        total_hits += hit_count;

        const doc_len = if (rowid < doc_lengths.len) doc_lengths[@intCast(rowid)] else 0;
        const phrase = [_]fts5_bm25.PhraseStats{.{
            .rows_with_phrase = rows_with_term,
            .weighted_hits = weighted_hits,
        }};
        const score = fts5_bm25.score(averages.total_rows, doc_len, avg_doc_len, &phrase);
        topInsert(top, &top_len, .{
            .rowid = rowid,
            .score = score,
            .hits = hit_count,
            .doc_len = doc_len,
            .column_hits = posting.column_hits,
        });
    }

    const rows = try allocator.realloc(top, top_len);
    return .{
        .table_name = fts_table,
        .query = query,
        .total_rows = averages.total_rows,
        .rows_with_term = rows_with_term,
        .total_hits = total_hits,
        .avg_doc_len = avg_doc_len,
        .column_count = averages.column_count,
        .rows = rows,
    };
}

fn shadowTable(schema: schema_mod.Schema, fts_table: []const u8, suffix: []const u8, allocator: std.mem.Allocator) !schema_mod.SchemaEntry {
    const name = try std.fmt.allocPrint(allocator, "{s}_{s}", .{ fts_table, suffix });
    defer allocator.free(name);
    return schema.findTable(name) orelse error.MissingFts5ShadowTable;
}

fn normalizeBareTerm(query: []const u8, allocator: std.mem.Allocator) ![]u8 {
    var trimmed = std.mem.trim(u8, query, " \t\r\n");
    if (trimmed.len >= 2 and ((trimmed[0] == '\'' and trimmed[trimmed.len - 1] == '\'') or (trimmed[0] == '"' and trimmed[trimmed.len - 1] == '"'))) {
        trimmed = trimmed[1 .. trimmed.len - 1];
    }

    var token: std.ArrayList(u8) = .empty;
    defer token.deinit(allocator);

    var saw = false;
    for (trimmed) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '_') {
            try token.append(allocator, std.ascii.toLower(c));
            saw = true;
        } else if (std.ascii.isWhitespace(c)) {
            if (saw) return error.UnsupportedFts5Query;
        } else {
            return error.UnsupportedFts5Query;
        }
    }
    if (!saw) return error.UnsupportedFts5Query;

    const stem_len = porterLiteStemLen(token.items);
    var out = try allocator.alloc(u8, stem_len + 1);
    errdefer allocator.free(out);
    out[0] = '0';
    @memcpy(out[1..], token.items[0..stem_len]);
    return out;
}

fn porterLiteStemLen(token: []const u8) usize {
    var len = token.len;
    if (len <= 2) return len;

    if (endsWith(token[0..len], "sses")) {
        len -= 2;
    } else if (endsWith(token[0..len], "ies")) {
        len -= 2; // "parties" -> "parti", matching the Porter shape.
    } else if (!endsWith(token[0..len], "ss") and endsWith(token[0..len], "s") and hasVowel(token[0 .. len - 1])) {
        len -= 1;
    }

    if (len > 5 and endsWith(token[0..len], "ing") and hasVowel(token[0 .. len - 3])) {
        len -= 3;
    } else if (len > 4 and endsWith(token[0..len], "ed") and hasVowel(token[0 .. len - 2])) {
        len -= 2;
    }

    inline for (.{
        "ement",  "ance",   "ence",   "able",  "ible",  "ment",    "ant",   "ent",
        "ation",  "ator",   "alism",  "aliti", "alli",  "fulness", "ousli", "iveness",
        "tional", "biliti", "lessli", "icate", "iciti", "ical",    "ness",  "ous",
        "ive",    "ize",    "iti",    "ate",   "al",    "er",      "ic",
    }) |suffix| {
        if (len > suffix.len + 2 and endsWith(token[0..len], suffix)) {
            return len - suffix.len;
        }
    }

    return len;
}

fn endsWith(text: []const u8, suffix: []const u8) bool {
    return std.mem.endsWith(u8, text, suffix);
}

fn hasVowel(text: []const u8) bool {
    for (text) |c| {
        switch (c) {
            'a', 'e', 'i', 'o', 'u' => return true,
            else => {},
        }
    }
    return false;
}

fn loadAverages(reader: page.PageReader, data_root: u32, allocator: std.mem.Allocator) !Averages {
    const row = (try table.findRowByRowid(reader, data_root, 1, allocator)) orelse return error.MissingFts5Averages;
    defer row.deinit(allocator);
    if (row.values.len == 0) return error.InvalidFts5Averages;
    const blob = firstBytesValue(row.values) orelse return error.InvalidFts5Averages;

    var pos: usize = 0;
    const total_rows_v = try parseVarint(blob[pos..]);
    pos += total_rows_v.len;

    var averages: Averages = .{
        .total_rows = total_rows_v.value,
        .column_count = 0,
        .column_tokens = [_]u64{0} ** MAX_COLUMNS,
    };
    while (pos < blob.len) {
        if (averages.column_count >= MAX_COLUMNS) return error.TooManyFts5Columns;
        const v = try parseVarint(blob[pos..]);
        pos += v.len;
        averages.column_tokens[averages.column_count] = v.value;
        averages.column_count += 1;
    }
    if (averages.column_count == 0) return error.InvalidFts5Averages;
    return averages;
}

fn loadSegments(reader: page.PageReader, data_root: u32, allocator: std.mem.Allocator) ![]Segment {
    const row = (try table.findRowByRowid(reader, data_root, 10, allocator)) orelse return error.MissingFts5Structure;
    defer row.deinit(allocator);
    if (row.values.len == 0) return error.InvalidFts5Structure;
    const blob = firstBytesValue(row.values) orelse return error.InvalidFts5Structure;

    var pos: usize = 4; // first four bytes are the structure cookie
    if (blob.len < pos) return error.InvalidFts5Structure;
    const levels_v = try parseVarint(blob[pos..]);
    pos += levels_v.len;
    const _segments_v = try parseVarint(blob[pos..]);
    pos += _segments_v.len;
    const _writes_v = try parseVarint(blob[pos..]);
    pos += _writes_v.len;

    var segments: std.ArrayList(Segment) = .empty;
    errdefer segments.deinit(allocator);

    var level: u64 = 0;
    while (level < levels_v.value) : (level += 1) {
        const _merge_v = try parseVarint(blob[pos..]);
        pos += _merge_v.len;
        const count_v = try parseVarint(blob[pos..]);
        pos += count_v.len;

        var i: u64 = 0;
        while (i < count_v.value) : (i += 1) {
            const segid_v = try parseVarint(blob[pos..]);
            pos += segid_v.len;
            const first_v = try parseVarint(blob[pos..]);
            pos += first_v.len;
            const last_v = try parseVarint(blob[pos..]);
            pos += last_v.len;
            try segments.append(allocator, .{
                .segid = segid_v.value,
                .first = @intCast(first_v.value),
                .last = @intCast(last_v.value),
            });
        }
    }
    return segments.toOwnedSlice(allocator);
}

fn loadDocLengths(reader: page.PageReader, docsize_root: u32, total_rows: u64, column_count: usize, allocator: std.mem.Allocator) ![]u32 {
    if (total_rows > std.math.maxInt(usize) - 1) return error.Fts5TableTooLarge;
    const lengths = try allocator.alloc(u32, @as(usize, @intCast(total_rows)) + 1);
    errdefer allocator.free(lengths);
    @memset(lengths, 0);

    const Ctx = struct {
        lengths: []u32,
        column_count: usize,

        fn onRow(ctx: *@This(), rowid: i64, values: []const record.Value) !void {
            if (rowid < 0 or @as(u64, @intCast(rowid)) >= @as(u64, @intCast(ctx.lengths.len))) return;
            if (values.len == 0) return error.InvalidFts5Docsize;
            const blob = firstBytesValue(values) orelse return error.InvalidFts5Docsize;
            var pos: usize = 0;
            var total: u64 = 0;
            var col: usize = 0;
            while (col < ctx.column_count and pos < blob.len) : (col += 1) {
                const v = try parseVarint(blob[pos..]);
                pos += v.len;
                total += v.value;
            }
            ctx.lengths[@intCast(rowid)] = @intCast(@min(total, std.math.maxInt(u32)));
        }
    };

    var ctx: Ctx = .{ .lengths = lengths, .column_count = column_count };
    try table.scanTableForEachAlloc(reader, docsize_root, allocator, &ctx, Ctx.onRow);
    return lengths;
}

const CandidatePages = struct {
    map: std.AutoHashMap(u64, u32),

    fn deinit(self: *CandidatePages) void {
        self.map.deinit();
    }

    fn get(self: CandidatePages, segid: u64) ?u32 {
        return self.map.get(segid);
    }
};

fn candidatePages(reader: page.PageReader, idx_root: u32, term: []const u8, allocator: std.mem.Allocator) !CandidatePages {
    var out = CandidatePages{ .map = std.AutoHashMap(u64, u32).init(allocator) };
    errdefer out.deinit();

    const idx = try index.scanIndex(reader, idx_root, allocator);
    defer idx.deinit(allocator);
    for (idx.entries) |entry| {
        if (entry.values.len < 3 or entry.values[0] != .integer or entry.values[2] != .integer) continue;
        if (entry.values[0].integer < 0 or entry.values[2].integer < 0) continue;
        const idx_term = valueBytes(entry.values[1]) orelse continue;
        if (std.mem.order(u8, idx_term, term) == .gt) continue;
        try out.map.put(@intCast(entry.values[0].integer), @intCast(entry.values[2].integer));
    }
    return out;
}

fn readSegmentTerm(
    reader: page.PageReader,
    data_root: u32,
    segment: Segment,
    candidates: CandidatePages,
    term: []const u8,
    column_count: usize,
    postings: *std.AutoHashMap(u64, Posting),
    allocator: std.mem.Allocator,
) !void {
    if (segment.first == 0 or segment.last < segment.first) return;

    var start_page = segment.first;
    if (candidates.get(segment.segid)) |encoded| {
        const half = encoded >> 1;
        start_page = if (half < segment.first)
            segment.first
        else if (half > segment.last)
            segment.last
        else
            half;
    }

    var pg = start_page;
    while (pg <= segment.last) : (pg += 1) {
        const block = try segmentPage(reader, data_root, segment.segid, pg, allocator);
        defer allocator.free(block);

        const found = try findTermSpan(block, term, allocator);
        switch (found) {
            .found => |span| {
                var parser = DoclistParser.init(allocator, postings, column_count);
                defer parser.deinit();

                try parser.parseRows(block[span.doc_start..span.doc_end], true);
                if (span.is_last and span.doc_end == span.content_size) {
                    try readContinuationPages(reader, data_root, segment, pg + 1, &parser, allocator);
                }
                if (parser.hasPending()) return error.InvalidFts5Doclist;
                return;
            },
            .past => return,
            .not_found => {},
        }
    }
}

fn readContinuationPages(
    reader: page.PageReader,
    data_root: u32,
    segment: Segment,
    first_page: u32,
    parser: *DoclistParser,
    allocator: std.mem.Allocator,
) !void {
    var pg = first_page;
    while (pg <= segment.last) : (pg += 1) {
        const block = try segmentPage(reader, data_root, segment.segid, pg, allocator);
        defer allocator.free(block);
        const info = try leafInfo(block, allocator);
        const chunk_end = info.first_term_offset orelse info.content_size;
        if (chunk_end > block.len or chunk_end < 4) return error.InvalidFts5Leaf;

        if (info.rowid_offset > 4) {
            const tail_end = @min(info.rowid_offset, chunk_end);
            try parser.feedPoslistTail(block[4..tail_end]);
            if (info.rowid_offset < chunk_end) {
                if (parser.hasPending()) return error.InvalidFts5Doclist;
                try parser.parseRows(block[info.rowid_offset..chunk_end], true);
            }
        } else if (parser.hasPending()) {
            try parser.feedPoslistTail(block[4..chunk_end]);
        } else {
            try parser.parseRows(block[4..chunk_end], true);
        }

        if (info.first_term_offset != null) return;
    }
}

fn segmentPage(reader: page.PageReader, data_root: u32, segid: u64, pg: u32, allocator: std.mem.Allocator) ![]u8 {
    const rowid_u = (segid << 37) + pg;
    if (rowid_u > std.math.maxInt(i64)) return error.InvalidFts5SegmentPage;
    const row = (try table.findRowByRowid(reader, data_root, @intCast(rowid_u), allocator)) orelse return error.MissingFts5SegmentPage;
    defer row.deinit(allocator);
    if (row.values.len == 0) return error.InvalidFts5SegmentPage;
    const blob = firstBytesValue(row.values) orelse return error.InvalidFts5SegmentPage;
    return allocator.dupe(u8, blob);
}

const FindResult = union(enum) {
    found: TermSpan,
    not_found,
    past,
};

fn findTermSpan(block: []const u8, term: []const u8, allocator: std.mem.Allocator) !FindResult {
    const info = try leafInfo(block, allocator);
    if (info.first_term_offset == null) return .not_found;

    var offsets: std.ArrayList(usize) = .empty;
    defer offsets.deinit(allocator);
    try readTermOffsets(block, info.content_size, allocator, &offsets);

    var current: std.ArrayList(u8) = .empty;
    defer current.deinit(allocator);
    for (offsets.items, 0..) |off, i| {
        const end = if (i + 1 < offsets.items.len) offsets.items[i + 1] else info.content_size;
        if (off >= end or end > block.len) return error.InvalidFts5Leaf;

        var pos = off;
        if (i != 0) {
            const keep_v = try parseVarint(block[pos..end]);
            pos += keep_v.len;
            if (keep_v.value > current.items.len) return error.InvalidFts5Leaf;
            current.shrinkRetainingCapacity(@intCast(keep_v.value));
        }

        const suffix_len_v = try parseVarint(block[pos..end]);
        pos += suffix_len_v.len;
        const suffix_len: usize = @intCast(suffix_len_v.value);
        if (pos + suffix_len > end) return error.InvalidFts5Leaf;
        try current.appendSlice(allocator, block[pos .. pos + suffix_len]);
        pos += suffix_len;

        const cmp = std.mem.order(u8, current.items, term);
        if (cmp == .eq) {
            return .{ .found = .{
                .doc_start = pos,
                .doc_end = end,
                .content_size = info.content_size,
                .is_last = i + 1 == offsets.items.len,
            } };
        }
        if (cmp == .gt) return .past;
    }
    return .not_found;
}

fn leafInfo(block: []const u8, allocator: std.mem.Allocator) !LeafInfo {
    if (block.len < 4) return error.InvalidFts5Leaf;
    const rowid_offset = std.mem.readInt(u16, block[0..2], .big);
    const content_size = std.mem.readInt(u16, block[2..4], .big);
    if (content_size > block.len or content_size < 4) return error.InvalidFts5Leaf;

    var offsets: std.ArrayList(usize) = .empty;
    defer offsets.deinit(allocator);
    try readTermOffsets(block, content_size, allocator, &offsets);

    return .{
        .rowid_offset = rowid_offset,
        .content_size = content_size,
        .first_term_offset = if (offsets.items.len == 0) null else offsets.items[0],
    };
}

fn readTermOffsets(block: []const u8, content_size: usize, allocator: std.mem.Allocator, offsets: *std.ArrayList(usize)) !void {
    if (content_size > block.len) return error.InvalidFts5Leaf;
    var pos = content_size;
    var prev: usize = 0;
    while (pos < block.len) {
        const delta = try parseVarint(block[pos..]);
        pos += delta.len;
        prev += @intCast(delta.value);
        if (prev >= content_size) return error.InvalidFts5Leaf;
        try offsets.append(allocator, prev);
    }
}

fn parsePoslist(poslist: []const u8, column_count: usize, hits: *[MAX_COLUMNS]u32) !void {
    var pos: usize = 0;
    var column: usize = 0;
    while (pos < poslist.len) {
        if (poslist[pos] == 1) {
            pos += 1;
            const col_v = try parseVarint(poslist[pos..]);
            pos += col_v.len;
            column = @intCast(col_v.value);
        } else {
            const p = try parseVarint(poslist[pos..]);
            pos += p.len;
            if (column < column_count and column < MAX_COLUMNS) {
                hits[column] += 1;
            }
        }
    }
}

fn valueBytes(value: record.Value) ?[]const u8 {
    return switch (value) {
        .text => |text| text,
        .blob => |blob| blob,
        else => null,
    };
}

fn firstBytesValue(values: []const record.Value) ?[]const u8 {
    for (values) |value| {
        if (valueBytes(value)) |bytes| return bytes;
    }
    return null;
}

fn parseVarint(bytes: []const u8) !varint.Varint {
    return varint.parse(bytes) catch |err| switch (err) {
        error.TooSmall => error.InvalidFts5Varint,
        error.Overflow => error.InvalidFts5Varint,
    };
}

fn topBetter(a: ResultRow, b: ResultRow) bool {
    if (a.score < b.score) return true;
    if (a.score > b.score) return false;
    return a.rowid < b.rowid;
}

fn topInsert(top: []ResultRow, len: *usize, entry: ResultRow) void {
    if (top.len == 0) return;
    if (len.* == top.len and !topBetter(entry, top[top.len - 1])) return;
    var pos: usize = 0;
    while (pos < len.*) : (pos += 1) {
        if (topBetter(entry, top[pos])) break;
    }
    if (pos >= top.len) return;
    if (len.* < top.len) len.* += 1;
    var i = len.* - 1;
    while (i > pos) : (i -= 1) {
        top[i] = top[i - 1];
    }
    top[pos] = entry;
}

test "sqlite fts5 doclist parser treats continuation rowids as absolute" {
    var postings = std.AutoHashMap(u64, Posting).init(std.testing.allocator);
    defer postings.deinit();

    var parser = DoclistParser.init(std.testing.allocator, &postings, 3);
    defer parser.deinit();

    // rowid 10, two position varints; then a continuation-page rowid 7.
    try parser.parseRows(&[_]u8{ 10, 5, 2, 3 }, true);
    try parser.parseRows(&[_]u8{ 7, 3, 2 }, true);

    try std.testing.expect(postings.contains(10));
    try std.testing.expect(postings.contains(7));
    try std.testing.expect(!postings.contains(17));
    try std.testing.expectEqual(@as(u32, 2), postings.get(10).?.column_hits[0]);
    try std.testing.expectEqual(@as(u32, 1), postings.get(7).?.column_hits[0]);
}

test "sqlite fts5 query normalizer applies porter-style suffixes" {
    const term = try normalizeBareTerm("negligence", std.testing.allocator);
    defer std.testing.allocator.free(term);
    try std.testing.expectEqualStrings("0neglig", term);
}

test "sqlite fts5 top insert keeps lowest bm25 scores first" {
    var top: [3]ResultRow = undefined;
    var len: usize = 0;
    topInsert(&top, &len, .{ .rowid = 3, .score = -0.2, .hits = 1, .doc_len = 10, .column_hits = [_]u32{0} ** MAX_COLUMNS });
    topInsert(&top, &len, .{ .rowid = 1, .score = -0.5, .hits = 1, .doc_len = 10, .column_hits = [_]u32{0} ** MAX_COLUMNS });
    topInsert(&top, &len, .{ .rowid = 2, .score = -0.5, .hits = 1, .doc_len = 10, .column_hits = [_]u32{0} ** MAX_COLUMNS });
    topInsert(&top, &len, .{ .rowid = 4, .score = -0.1, .hits = 1, .doc_len = 10, .column_hits = [_]u32{0} ** MAX_COLUMNS });

    try std.testing.expectEqual(@as(usize, 3), len);
    try std.testing.expectEqual(@as(u64, 1), top[0].rowid);
    try std.testing.expectEqual(@as(u64, 2), top[1].rowid);
    try std.testing.expectEqual(@as(u64, 3), top[2].rowid);
}
