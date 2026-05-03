const std = @import("std");

const btree = @import("btree.zig");
const fts5_bm25 = @import("fts5_bm25.zig");
const page = @import("page.zig");
const record = @import("record.zig");
const schema_mod = @import("schema.zig");
const table = @import("table.zig");
const varint = @import("varint.zig");

pub const MAX_COLUMNS: usize = 16;
const MAX_TERMS_PER_LEAF: usize = 1024;
const MAX_TERM_BYTES: usize = 1024;

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
    present: bool = false,
    column_hits: [MAX_COLUMNS]u32,
};

const PendingPoslist = struct {
    rowid: u64,
    bytes: std.ArrayList(u8),
    remaining: usize,
};

const DoclistParser = struct {
    allocator: std.mem.Allocator,
    postings: []Posting,
    column_count: usize,
    last_rowid: u64 = 0,
    pending: ?PendingPoslist = null,

    fn init(allocator: std.mem.Allocator, postings: []Posting, column_count: usize) DoclistParser {
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
                if (rowid < self.postings.len) self.postings[@intCast(rowid)].present = false;
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
        if (rowid >= self.postings.len) return error.Fts5RowidOutOfRange;
        var hits = [_]u32{0} ** MAX_COLUMNS;
        try parsePoslist(poslist, self.column_count, &hits);
        var total: u32 = 0;
        for (hits[0..self.column_count]) |n| total += n;
        if (total == 0) {
            self.postings[@intCast(rowid)].present = false;
            return;
        }

        self.postings[@intCast(rowid)] = .{ .present = true, .column_hits = hits };
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
    const AcceptAll = struct {
        fn call(_: *@This(), _: ResultRow) anyerror!bool {
            return true;
        }
    };
    var accept_all: AcceptAll = .{};
    return searchFiltered(reader, schema, fts_table, query, options, allocator, &accept_all, AcceptAll.call);
}

pub fn searchFiltered(
    reader: page.PageReader,
    schema: schema_mod.Schema,
    fts_table: []const u8,
    query: []const u8,
    options: SearchOptions,
    allocator: std.mem.Allocator,
    ctx: anytype,
    comptime acceptCandidate: fn (ctx: @TypeOf(ctx), candidate: ResultRow) anyerror!bool,
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
    const segments = try loadSegments(reader, @intCast(data_entry.root_page), allocator);
    defer allocator.free(segments);
    const max_rowid = try maxTableRowid(reader, @intCast(docsize_entry.root_page));

    const candidate_pages = try candidatePages(reader, @intCast(idx_entry.root_page), segments, term, allocator);
    defer allocator.free(candidate_pages);

    if (max_rowid > std.math.maxInt(usize) - 1) return error.Fts5TableTooLarge;
    const postings = try allocator.alloc(Posting, @as(usize, @intCast(max_rowid)) + 1);
    defer allocator.free(postings);
    @memset(postings, .{ .present = false, .column_hits = [_]u32{0} ** MAX_COLUMNS });

    for (segments, 0..) |segment, i| {
        try readSegmentTerm(reader, @intCast(data_entry.root_page), segment, candidate_pages[i], term, averages.column_count, postings, allocator);
    }

    var raw_matches = false;
    for (postings) |posting| {
        if (posting.present) {
            raw_matches = true;
            break;
        }
    }

    const avg_doc_len = averages.avgDocLen();
    const top = try allocator.alloc(ResultRow, options.limit);
    errdefer allocator.free(top);
    var top_len: usize = 0;

    if (!raw_matches) {
        const rows = try allocator.realloc(top, 0);
        return .{
            .table_name = fts_table,
            .query = query,
            .total_rows = averages.total_rows,
            .rows_with_term = 0,
            .total_hits = 0,
            .avg_doc_len = avg_doc_len,
            .column_count = averages.column_count,
            .rows = rows,
        };
    }

    const doc_lengths = try loadDocLengths(reader, @intCast(docsize_entry.root_page), max_rowid, averages.column_count, postings, allocator);
    defer allocator.free(doc_lengths);

    var rows_with_term: u64 = 0;
    var total_hits: u64 = 0;
    for (postings) |posting| {
        if (!posting.present) continue;
        rows_with_term += 1;
        for (posting.column_hits[0..averages.column_count]) |hits| total_hits += hits;
    }

    if (rows_with_term == 0) {
        const rows = try allocator.realloc(top, 0);
        return .{
            .table_name = fts_table,
            .query = query,
            .total_rows = averages.total_rows,
            .rows_with_term = 0,
            .total_hits = 0,
            .avg_doc_len = avg_doc_len,
            .column_count = averages.column_count,
            .rows = rows,
        };
    }

    for (postings, 0..) |posting, rowid| {
        if (!posting.present) continue;
        var hit_count: u32 = 0;
        var weighted_hits: f64 = 0;
        for (posting.column_hits[0..averages.column_count], 0..) |hits, i| {
            hit_count += hits;
            const weight = if (i < options.weights.len) options.weights[i] else 1.0;
            weighted_hits += @as(f64, @floatFromInt(hits)) * weight;
        }

        const doc_len = if (rowid < doc_lengths.len) doc_lengths[@intCast(rowid)] else 0;
        const phrase = [_]fts5_bm25.PhraseStats{.{
            .rows_with_phrase = rows_with_term,
            .weighted_hits = weighted_hits,
        }};
        const score = fts5_bm25.score(averages.total_rows, doc_len, avg_doc_len, &phrase);
        const candidate: ResultRow = .{
            .rowid = @intCast(rowid),
            .score = score,
            .hits = hit_count,
            .doc_len = doc_len,
            .column_hits = posting.column_hits,
        };
        if (!try acceptCandidate(ctx, candidate)) continue;
        topInsert(top, &top_len, candidate);
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
    const block = (try findTableBlobByRowid(reader, data_root, 1, allocator)) orelse return error.MissingFts5Averages;
    defer block.deinit(allocator);
    const blob = block.bytes;

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
    const block = (try findTableBlobByRowid(reader, data_root, 10, allocator)) orelse return error.MissingFts5Structure;
    defer block.deinit(allocator);
    const blob = block.bytes;

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

fn loadDocLengths(reader: page.PageReader, docsize_root: u32, max_rowid: u64, column_count: usize, postings: []Posting, allocator: std.mem.Allocator) ![]u32 {
    if (max_rowid > std.math.maxInt(usize) - 1) return error.Fts5TableTooLarge;
    const lengths = try allocator.alloc(u32, @as(usize, @intCast(max_rowid)) + 1);
    errdefer allocator.free(lengths);
    @memset(lengths, 0);

    const Ctx = struct {
        lengths: []u32,
        column_count: usize,
        postings: []Posting,

        fn onRow(ctx: *@This(), rowid: i64, values: []const record.Value) !void {
            if (rowid < 0 or @as(u64, @intCast(rowid)) >= @as(u64, @intCast(ctx.lengths.len))) return;
            if (!ctx.postings[@intCast(rowid)].present) return;
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

    var ctx: Ctx = .{ .lengths = lengths, .column_count = column_count, .postings = postings };
    try table.scanTableForEach(reader, docsize_root, &ctx, Ctx.onRow);
    for (postings, 0..) |*posting, rowid| {
        if (posting.present and lengths[rowid] == 0) posting.present = false;
    }
    return lengths;
}

fn candidatePages(reader: page.PageReader, idx_root: u32, segments: []const Segment, term: []const u8, allocator: std.mem.Allocator) ![]u32 {
    const pages = try allocator.alloc(u32, segments.len);
    errdefer allocator.free(pages);
    for (segments, 0..) |segment, i| {
        pages[i] = (try seekCandidateIndex(reader, idx_root, segment.segid, term)) orelse 0;
    }
    return pages;
}

const KeyOrder = enum { lt, eq, gt };

const CandidateCell = struct {
    order: KeyOrder,
    segid: u64,
    pgno: u32,
};

fn seekCandidateIndex(reader: page.PageReader, page_number: u32, target_segid: u64, term: []const u8) !?u32 {
    const ref = try reader.page(page_number);
    const header = try btree.PageHeader.parse(ref);
    if (!header.page_type.isIndex()) return error.UnsupportedIndexBTree;

    var lo: usize = 0;
    var hi: usize = header.cell_count;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const cell = try header.cell(ref, mid);
        const payload = if (header.page_type == .index_interior) cell[4..] else cell;
        const candidate = try parseCandidateIndexCell(reader, payload, target_segid, term);
        if (candidate.order == .gt) {
            hi = mid;
        } else {
            lo = mid + 1;
        }
    }

    if (header.page_type == .index_leaf) {
        if (lo == 0) return null;
        const cell = try header.cell(ref, lo - 1);
        const candidate = try parseCandidateIndexCell(reader, cell, target_segid, term);
        return if (candidate.segid == target_segid and candidate.order != .gt) candidate.pgno else null;
    }

    if (lo < header.cell_count) {
        const cell = try header.cell(ref, lo);
        if (cell.len < 4) return error.InvalidIndexCell;
        const left_child = readU32(cell[0..4]);
        if (try seekCandidateIndex(reader, left_child, target_segid, term)) |pgno| return pgno;
    } else {
        const right = header.right_most_pointer orelse return error.InvalidIndexCell;
        if (try seekCandidateIndex(reader, right, target_segid, term)) |pgno| return pgno;
    }

    if (lo == 0) return null;
    const prev_cell = try header.cell(ref, lo - 1);
    const payload = if (header.page_type == .index_interior) prev_cell[4..] else prev_cell;
    const candidate = try parseCandidateIndexCell(reader, payload, target_segid, term);
    return if (candidate.segid == target_segid and candidate.order != .gt) candidate.pgno else null;
}

fn parseCandidateIndexCell(reader: page.PageReader, cell: []const u8, target_segid: u64, term: []const u8) !CandidateCell {
    const payload_size_v = try parseVarint(cell);
    const payload_size: usize = @intCast(payload_size_v.value);
    const payload_start: usize = payload_size_v.len;
    const payload_info = btree.indexPayloadInfo(payload_size, reader.usableSize());
    if (payload_info.overflow_page != null) return error.UnsupportedFts5IdxOverflow;
    if (payload_start + payload_size > cell.len) return error.InvalidIndexCell;

    var rec: record.InlineRecord = undefined;
    try record.parseInline(cell[payload_start..][0..payload_size], &rec);
    const values = rec.slice();
    if (values.len < 3 or values[0] != .integer or values[2] != .integer) return error.InvalidIndexCell;
    if (values[0].integer < 0 or values[2].integer < 0) return error.InvalidIndexCell;
    const idx_term = valueBytes(values[1]) orelse return error.InvalidIndexCell;

    const segid: u64 = @intCast(values[0].integer);
    const pgno: u32 = @intCast(values[2].integer);
    const order: KeyOrder = if (segid < target_segid)
        .lt
    else if (segid > target_segid)
        .gt
    else switch (std.mem.order(u8, idx_term, term)) {
        .lt => .lt,
        .eq => .eq,
        .gt => .gt,
    };

    return .{ .order = order, .segid = segid, .pgno = pgno };
}

fn readSegmentTerm(
    reader: page.PageReader,
    data_root: u32,
    segment: Segment,
    candidate_page: u32,
    term: []const u8,
    column_count: usize,
    postings: []Posting,
    allocator: std.mem.Allocator,
) !void {
    if (segment.first == 0 or segment.last < segment.first) return;

    var start_page = segment.first;
    if (candidate_page != 0) {
        const half = candidate_page >> 1;
        start_page = if (half < segment.first)
            segment.first
        else if (half > segment.last)
            segment.last
        else
            half;
    }

    var pg = start_page;
    while (pg <= segment.last) : (pg += 1) {
        const segment_block = try segmentPage(reader, data_root, segment.segid, pg, allocator);
        defer segment_block.deinit(allocator);
        const block = segment_block.bytes;

        const found = try findTermSpan(block, term);
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
        const segment_block = try segmentPage(reader, data_root, segment.segid, pg, allocator);
        defer segment_block.deinit(allocator);
        const block = segment_block.bytes;
        const info = try leafInfo(block);
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

const BlobBlock = struct {
    bytes: []const u8,
    owned_payload: ?[]u8 = null,

    fn deinit(self: BlobBlock, allocator: std.mem.Allocator) void {
        if (self.owned_payload) |payload| allocator.free(payload);
    }
};

fn segmentPage(reader: page.PageReader, data_root: u32, segid: u64, pg: u32, allocator: std.mem.Allocator) !BlobBlock {
    const rowid_u = (segid << 37) + pg;
    if (rowid_u > std.math.maxInt(i64)) return error.InvalidFts5SegmentPage;
    return (try findTableBlobByRowid(reader, data_root, @intCast(rowid_u), allocator)) orelse error.MissingFts5SegmentPage;
}

fn findTableBlobByRowid(reader: page.PageReader, root_page: u32, wanted_rowid: i64, allocator: std.mem.Allocator) !?BlobBlock {
    return findTableBlobInPage(reader, root_page, wanted_rowid, allocator);
}

fn maxTableRowid(reader: page.PageReader, root_page: u32) !u64 {
    const ref = try reader.page(root_page);
    const header = try btree.PageHeader.parse(ref);
    if (!header.page_type.isTable()) return error.UnsupportedTableBTree;

    switch (header.page_type) {
        .table_leaf => {
            if (header.cell_count == 0) return 0;
            const cell = try header.cell(ref, header.cell_count - 1);
            const prefix = try parseTableLeafCellPrefix(cell);
            if (prefix.rowid < 0) return error.InvalidTableCell;
            return @intCast(prefix.rowid);
        },
        .table_interior => {
            const right = header.right_most_pointer orelse return error.InvalidTableCell;
            return try maxTableRowid(reader, right);
        },
        else => return error.UnsupportedTableBTree,
    }
}

fn findTableBlobInPage(reader: page.PageReader, page_number: u32, wanted_rowid: i64, allocator: std.mem.Allocator) !?BlobBlock {
    const ref = try reader.page(page_number);
    const header = try btree.PageHeader.parse(ref);
    if (!header.page_type.isTable()) return error.UnsupportedTableBTree;

    switch (header.page_type) {
        .table_leaf => {
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
                    return try parseTableLeafBlob(reader, cell, allocator);
                }
            }
            return null;
        },
        .table_interior => {
            var i: usize = 0;
            while (i < header.cell_count) : (i += 1) {
                const cell = try header.cell(ref, i);
                if (cell.len < 5) return error.InvalidTableCell;
                const left_child = readU32(cell[0..4]);
                const sep = try parseVarint(cell[4..]);
                if (wanted_rowid <= @as(i64, @intCast(sep.value))) {
                    return try findTableBlobInPage(reader, left_child, wanted_rowid, allocator);
                }
            }

            const right = header.right_most_pointer orelse return error.InvalidTableCell;
            return try findTableBlobInPage(reader, right, wanted_rowid, allocator);
        },
        else => return error.UnsupportedTableBTree,
    }
}

const TableLeafCellPrefix = struct {
    payload_size: usize,
    rowid: i64,
    payload_start: usize,
};

fn parseTableLeafCellPrefix(cell: []const u8) !TableLeafCellPrefix {
    const payload_size_v = try parseVarint(cell);
    const rowid_v = try parseVarint(cell[payload_size_v.len..]);
    return .{
        .payload_size = @intCast(payload_size_v.value),
        .rowid = @intCast(rowid_v.value),
        .payload_start = @as(usize, payload_size_v.len) + rowid_v.len,
    };
}

fn parseTableLeafBlob(reader: page.PageReader, cell: []const u8, allocator: std.mem.Allocator) !BlobBlock {
    const prefix = try parseTableLeafCellPrefix(cell);
    const payload_info = btree.tableLeafPayloadInfo(prefix.payload_size, reader.usableSize());
    if (prefix.payload_start + payload_info.local_len > cell.len) return error.InvalidTableCell;

    if (payload_info.overflow_page == null) {
        return blobFromRecordPayload(cell[prefix.payload_start .. prefix.payload_start + prefix.payload_size], null);
    }

    if (prefix.payload_start + payload_info.local_len + 4 > cell.len) return error.InvalidTableCell;
    const payload = try allocator.alloc(u8, prefix.payload_size);
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

    return blobFromRecordPayload(payload, payload);
}

fn blobFromRecordPayload(payload: []const u8, owned_payload: ?[]u8) !BlobBlock {
    var rec: record.InlineRecord = undefined;
    try record.parseInline(payload, &rec);
    const blob = firstBytesValue(rec.slice()) orelse return error.InvalidTableCell;
    return .{ .bytes = blob, .owned_payload = owned_payload };
}

const FindResult = union(enum) {
    found: TermSpan,
    not_found,
    past,
};

fn findTermSpan(block: []const u8, term: []const u8) !FindResult {
    const info = try leafInfo(block);
    if (info.first_term_offset == null) return .not_found;

    var offsets_buf: [MAX_TERMS_PER_LEAF]usize = undefined;
    const offsets = offsets_buf[0..try readTermOffsets(block, info.content_size, &offsets_buf)];

    var current: [MAX_TERM_BYTES]u8 = undefined;
    var current_len: usize = 0;
    for (offsets, 0..) |off, i| {
        const end = if (i + 1 < offsets.len) offsets[i + 1] else info.content_size;
        if (off >= end or end > block.len) return error.InvalidFts5Leaf;

        var pos = off;
        if (i != 0) {
            const keep_v = try parseVarint(block[pos..end]);
            pos += keep_v.len;
            if (keep_v.value > current_len) return error.InvalidFts5Leaf;
            current_len = @intCast(keep_v.value);
        }

        const suffix_len_v = try parseVarint(block[pos..end]);
        pos += suffix_len_v.len;
        const suffix_len: usize = @intCast(suffix_len_v.value);
        if (pos + suffix_len > end) return error.InvalidFts5Leaf;
        if (current_len + suffix_len > current.len) return error.Fts5TermTooLarge;
        @memcpy(current[current_len..][0..suffix_len], block[pos .. pos + suffix_len]);
        current_len += suffix_len;
        pos += suffix_len;

        const cmp = std.mem.order(u8, current[0..current_len], term);
        if (cmp == .eq) {
            return .{ .found = .{
                .doc_start = pos,
                .doc_end = end,
                .content_size = info.content_size,
                .is_last = i + 1 == offsets.len,
            } };
        }
        if (cmp == .gt) return .past;
    }
    return .not_found;
}

fn leafInfo(block: []const u8) !LeafInfo {
    if (block.len < 4) return error.InvalidFts5Leaf;
    const rowid_offset = std.mem.readInt(u16, block[0..2], .big);
    const content_size = std.mem.readInt(u16, block[2..4], .big);
    if (content_size > block.len or content_size < 4) return error.InvalidFts5Leaf;

    return .{
        .rowid_offset = rowid_offset,
        .content_size = content_size,
        .first_term_offset = try firstTermOffset(block, content_size),
    };
}

fn firstTermOffset(block: []const u8, content_size: usize) !?usize {
    if (content_size > block.len) return error.InvalidFts5Leaf;
    if (content_size == block.len) return null;
    const first = try parseVarint(block[content_size..]);
    if (first.value >= content_size) return error.InvalidFts5Leaf;
    return @intCast(first.value);
}

fn readTermOffsets(block: []const u8, content_size: usize, offsets: *[MAX_TERMS_PER_LEAF]usize) !usize {
    if (content_size > block.len) return error.InvalidFts5Leaf;
    var pos = content_size;
    var prev: usize = 0;
    var len: usize = 0;
    while (pos < block.len) {
        if (len >= offsets.len) return error.TooManyFts5LeafTerms;
        const delta = try parseVarint(block[pos..]);
        pos += delta.len;
        prev += @intCast(delta.value);
        if (prev >= content_size) return error.InvalidFts5Leaf;
        offsets[len] = prev;
        len += 1;
    }
    return len;
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

fn readU32(bytes: []const u8) u32 {
    return std.mem.readInt(u32, bytes[0..4], .big);
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
    var postings = [_]Posting{.{ .present = false, .column_hits = [_]u32{0} ** MAX_COLUMNS }} ** 32;

    var parser = DoclistParser.init(std.testing.allocator, &postings, 3);
    defer parser.deinit();

    // rowid 10, two position varints; then a continuation-page rowid 7.
    try parser.parseRows(&[_]u8{ 10, 5, 2, 3 }, true);
    try parser.parseRows(&[_]u8{ 7, 3, 2 }, true);

    try std.testing.expect(postings[10].present);
    try std.testing.expect(postings[7].present);
    try std.testing.expect(!postings[17].present);
    try std.testing.expectEqual(@as(u32, 2), postings[10].column_hits[0]);
    try std.testing.expectEqual(@as(u32, 1), postings[7].column_hits[0]);
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
