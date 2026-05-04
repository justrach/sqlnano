const std = @import("std");

pub const Status = enum {
    missing,
    planned,
    scaffold,
    partial,
    basic,
    experimental,
    complete,
};

pub const Feature = struct {
    area: []const u8,
    status: Status,
    evidence: []const u8,
    next: []const u8,
};

pub const features = [_]Feature{
    .{
        .area = "SQLite .db header detection",
        .status = .basic,
        .evidence = "Reads and validates SQLite database header/page metadata.",
        .next = "Add more file-format corruption fixtures.",
    },
    .{
        .area = "sqlite_schema introspection",
        .status = .basic,
        .evidence = "Reads sqlite_schema and extracts table/index entries.",
        .next = "Handle more schema object types and quoted/escaped SQL forms.",
    },
    .{
        .area = "Table b-tree reads",
        .status = .partial,
        .evidence = "Scans rowid tables and supports direct rowid lookup, including overflow payloads.",
        .next = "Broaden coverage for larger/more fragmented SQLite files.",
    },
    .{
        .area = "Index b-tree reads",
        .status = .partial,
        .evidence = "Scans simple indexes, uses b-tree-pruned non-partial single-column equality indexes for SELECT and FTS pre-filters, and can count first-column equality matches without materializing rowids.",
        .next = "Implement range traversal, ORDER BY pushdown, and broader composite-index planning.",
    },
    .{
        .area = "SQLite-compatible writes",
        .status = .partial,
        .evidence = "CREATE TABLE can initialize an empty DB or append a simple rowid-table schema row/root page when sqlite_schema is still a leaf. CREATE INDEX can add a non-unique single-column index when it fits in one leaf, and subsequent INSERT/UPDATE/DELETE rebuilds keep it in sync. ALTER TABLE RENAME rewrites sqlite_schema for simple rowid tables and their simple indexes. ALTER TABLE ADD COLUMN supports nullable tail columns without defaults/constraints by rewriting sqlite_schema. DROP TABLE works when every dropped table/index page is a tail suffix that can be truncated without freelist support. INSERT/UPDATE/DELETE on rowid tables are logged through a native WAL (group commit + crash recovery). `Connection` keeps the data file image in memory so ops mutate the buffer. The data file is opened once at first flush and kept open for the life of the connection; every subsequent checkpoint pwrites only the pages a fast-path insert actually touched (2-5 pages per insert). Auto-rowid inserts on indexless tables take a three-stage fast path: (a) stamp the cell into the rightmost leaf when it fits, (b) when a leaf fills, walk the right-most chain to find the lowest interior with room, allocate fresh interiors at every full level between it and the leaf, and splice in a new rightmost leaf, (c) when even the root is full, allocate three fresh pages (root copy + new chain + new leaf) and promote root to a deeper interior. All asymmetric, no data moved. The slow-path rebuild (indexed tables, UPDATE, DELETE) still forces a full-image rewrite. Verified to 5,000,000 rows by `PRAGMA integrity_check`; sustained throughput beats native SQLite WAL+NORMAL by 2.58x at 5M rows, 2.64x at 1M, and 3.36x at 1k rows with no decay across the range.",
        .next = "Add constrained/default ADD COLUMN, column rename/drop, freelist-backed DROP TABLE for non-tail pages, bring the fast path to indexed tables (incremental index-leaf insert), multi-leaf index splits, freelist handling to reclaim orphaned leaves, make UPDATE / DELETE incremental instead of full-rewrite, rollback journal + SQLite WAL frame format, and broader crash fixtures.",
    },
    .{
        .area = "Full SQL grammar",
        .status = .partial,
        .evidence = "SELECT supports: projections (*, col, t.col, t.*, expr, AS aliases); aggregates COUNT(*), COUNT(col), SUM, MIN, MAX, AVG (collapse-all only, no GROUP BY yet); WHERE with = != <> < <= > >= AND OR NOT, IS [NOT] NULL, LIKE / NOT LIKE (case-insensitive ASCII, %/_), IN / NOT IN (literal list), BETWEEN / NOT BETWEEN; arithmetic + - * / %, unary -, string concat ||; INNER JOIN with qualified names and aliases; ORDER BY col [ASC|DESC]; LIMIT N. CREATE TABLE accepts the simple rowid-table shape, CREATE INDEX accepts one non-unique column, ALTER TABLE supports table rename and nullable ADD COLUMN, and DROP TABLE supports tail-safe drops. INSERT/UPDATE/DELETE still only accept the tiny legacy forms. No column rename/drop, no subqueries, no GROUP BY / HAVING, no LEFT JOIN, no CASE WHEN, no user functions.",
        .next = "GROUP BY + HAVING, LEFT JOIN, DISTINCT, CASE WHEN, subqueries, CTEs, UPDATE/DELETE with richer WHERE, broader ALTER TABLE shapes, scalar functions (LOWER/UPPER/LENGTH/SUBSTR/COALESCE/...).",
    },
    .{
        .area = "Full query planner",
        .status = .partial,
        .evidence = "Single-table WHERE with `rowid = N` or `indexed_col = lit` takes the direct-lookup / b-tree-pruned index-rowid fast path. Filtered COUNT(*) over rowid/index equality counts keys directly instead of hydrating rows. Simple COUNT(*) chooses the smallest table/index b-tree with matching cardinality and counts cells instead of rows. Single-source ORDER BY rowid ASC (or integer-primary-key alias ASC) streams in natural b-tree order and can stop at LIMIT. Everything else falls through to the general nested-loop scan (which handles JOIN + WHERE + ORDER BY + LIMIT). Joins are cross-product with incremental ON-predicate filtering; column resolution walks every source and rejects ambiguous unqualified refs.",
        .next = "Cost-based join ordering (current order is FROM-then-JOINs in source order), hash joins for large cross-products, broader index-driven sort pushdown for ORDER BY.",
    },
    .{
        .area = "VDBE/execution engine",
        .status = .missing,
        .evidence = "Current execution is direct specialized Zig code, not bytecode.",
        .next = "Introduce register VM opcodes and compile SQL into bytecode.",
    },
    .{
        .area = "Transactions",
        .status = .missing,
        .evidence = "No BEGIN/COMMIT/ROLLBACK semantics yet.",
        .next = "Add transaction state, autocommit behavior, savepoint plan, rollback tests.",
    },
    .{
        .area = "Locking",
        .status = .missing,
        .evidence = "No SQLite-compatible shared/reserved/pending/exclusive lock protocol.",
        .next = "Implement file locking model for readers/writers across processes.",
    },
    .{
        .area = "Journaling/WAL logic",
        .status = .partial,
        .evidence = "Native sqlnano WAL (group commit + fsync + checkpoint + compact) logs every row mutation and replays committed-but-unapplied entries on reopen; covered by crash-recovery tests.",
        .next = "Implement SQLite rollback journal + SQLite WAL frame format so we interoperate with the canonical `.db-journal` / `-wal` files.",
    },
    .{
        .area = "Permissions/safety checks",
        .status = .scaffold,
        .evidence = "Rejects several unsafe write shapes such as WAL mode, non-leaf roots, and unsupported indexes.",
        .next = "Centralize safety policy, read-only mode, immutable mode, authorizer hooks.",
    },
    .{
        .area = "Triggers",
        .status = .missing,
        .evidence = "Trigger schema entries are not executed.",
        .next = "Parse trigger definitions and execute trigger programs during writes.",
    },
    .{
        .area = "Constraints",
        .status = .missing,
        .evidence = "PRIMARY KEY rowid projection exists, but constraint enforcement is not general.",
        .next = "Add NOT NULL, UNIQUE, CHECK, FK, default values, conflict actions.",
    },
    .{
        .area = "Type affinity rules",
        .status = .partial,
        .evidence = "Basic column affinity classification and row projection exist.",
        .next = "Implement SQLite coercion/comparison semantics comprehensively.",
    },
    .{
        .area = "Collations",
        .status = .missing,
        .evidence = "Only byte/string equality for supported text comparisons.",
        .next = "Add BINARY/NOCASE/RTRIM and collation-aware index comparisons.",
    },
    .{
        .area = "Virtual tables",
        .status = .experimental,
        .evidence = "No general xConnect/xBestIndex/xFilter module system yet, but FTS5 shadow tables can be read directly for prioritized compact shapes: bare-token and implicit-AND bareword MATCH, BM25 top-k, weights, hydration, and simple filters.",
        .next = "Keep compact native FTS shapes fast first; then broaden native query syntax, tokenizer parity, phrase/AND/OR/NEAR support, snippets, and eventually a real virtual-table ABI.",
    },
    .{
        .area = "Broad compatibility behavior",
        .status = .missing,
        .evidence = "Only a narrow SQLite-compatible subset is implemented.",
        .next = "Add sqllogictest/SQLite TCL-style compatibility fixtures over time.",
    },
};

pub fn statusLabel(status: Status) []const u8 {
    return switch (status) {
        .missing => "missing",
        .planned => "planned",
        .scaffold => "scaffold",
        .partial => "partial",
        .basic => "basic",
        .experimental => "experimental",
        .complete => "complete",
    };
}

pub fn statusRank(status: Status) u8 {
    return switch (status) {
        .missing => 0,
        .planned => 1,
        .scaffold => 2,
        .partial => 3,
        .basic => 4,
        .experimental => 4,
        .complete => 5,
    };
}

pub fn completionScore() struct { done: usize, total: usize } {
    var done: usize = 0;
    for (features) |feature| {
        if (feature.status == .complete or feature.status == .basic) done += 1;
    }
    return .{ .done = done, .total = features.len };
}

test "parity table has tracked features" {
    try std.testing.expect(features.len >= 12);
    try std.testing.expect(statusRank(.complete) > statusRank(.missing));
}
