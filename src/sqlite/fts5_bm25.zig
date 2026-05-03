const std = @import("std");

pub const K1: f64 = 1.2;
pub const B: f64 = 0.75;

pub const PhraseStats = struct {
    /// Number of rows containing this query phrase at least once.
    rows_with_phrase: u64,
    /// Weighted phrase frequency in the current row. For unweighted BM25 this
    /// is just the hit count; for `bm25(ft, w0, w1, ...)` it is
    /// sum(column_hits[c] * weight[c]).
    weighted_hits: f64,
};

/// SQLite FTS5's BM25 score for one row. Lower is better because SQLite
/// returns the negative of the normal BM25 relevance score so callers can
/// simply `ORDER BY bm25(ft)` ascending.
pub fn score(total_rows: u64, doc_len: u64, avg_doc_len: f64, phrases: []const PhraseStats) f64 {
    if (total_rows == 0 or avg_doc_len <= 0) return 0;

    const d: f64 = @floatFromInt(doc_len);
    const norm = K1 * (1.0 - B + B * d / avg_doc_len);
    var relevance: f64 = 0;

    for (phrases) |phrase| {
        if (phrase.weighted_hits <= 0) continue;

        const idf = inverseDocumentFrequency(total_rows, phrase.rows_with_phrase);
        const numerator = phrase.weighted_hits * (K1 + 1.0);
        const denominator = phrase.weighted_hits + norm;
        relevance += idf * numerator / denominator;
    }

    return -relevance;
}

pub fn inverseDocumentFrequency(total_rows: u64, rows_with_phrase: u64) f64 {
    if (total_rows == 0) return 0;
    const n: f64 = @floatFromInt(total_rows);
    const hits_int = @min(rows_with_phrase, total_rows);
    const hits: f64 = @floatFromInt(hits_int);
    return @log((n - hits + 0.5) / (hits + 0.5));
}

pub fn weightedHits(column_hits: []const u32, weights: []const f64) f64 {
    var total: f64 = 0;
    for (column_hits, 0..) |hits, i| {
        const weight = if (i < weights.len) weights[i] else 1.0;
        total += @as(f64, @floatFromInt(hits)) * weight;
    }
    return total;
}

test "sqlite fts5 bm25 returns lower scores for more phrase hits" {
    const rare_once = [_]PhraseStats{.{ .rows_with_phrase = 10, .weighted_hits = 1 }};
    const rare_many = [_]PhraseStats{.{ .rows_with_phrase = 10, .weighted_hits = 5 }};

    const once = score(1000, 100, 100, &rare_once);
    const many = score(1000, 100, 100, &rare_many);

    try std.testing.expect(many < once);
    try std.testing.expect(once < 0);
}

test "sqlite fts5 bm25 applies document length normalization" {
    const phrase = [_]PhraseStats{.{ .rows_with_phrase = 10, .weighted_hits = 3 }};

    const short = score(1000, 50, 100, &phrase);
    const long = score(1000, 200, 100, &phrase);

    try std.testing.expect(short < long);
}

test "sqlite fts5 bm25 supports column weights" {
    const title_hit = [_]u32{ 1, 0, 0 };
    const body_hit = [_]u32{ 0, 0, 1 };
    const weights = [_]f64{ 10.0, 5.0, 1.0 };

    try std.testing.expectEqual(@as(f64, 10.0), weightedHits(&title_hit, &weights));
    try std.testing.expectEqual(@as(f64, 1.0), weightedHits(&body_hit, &weights));
}
