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
        .evidence = "Scans simple indexes and uses single-column equality indexes for SELECT.",
        .next = "Implement binary seek/range traversal instead of scan-then-filter.",
    },
    .{
        .area = "SQLite-compatible writes",
        .status = .partial,
        .evidence = "INSERT/UPDATE/DELETE on rowid tables are logged through a native WAL (group commit + crash recovery). `Connection` holds the data file image in memory so ops mutate the buffer rather than rewriting the file per call; writeFile happens only at flush/close. Tables grow past one page via interior-root + multi-leaf splits verified by `PRAGMA integrity_check`. Simple single-leaf non-unique single-column indexes are maintained.",
        .next = "Incremental in-place leaf inserts (the current rebuild-from-scratch path is O(n) per op, giving O(n^2) on large batches), multi-leaf index splits, freelist handling to reclaim orphaned leaves, rollback journal + SQLite WAL frame format, and broader crash fixtures.",
    },
    .{
        .area = "Full SQL grammar",
        .status = .scaffold,
        .evidence = "Reusable tokenizer and shared AST parser exist for tiny SELECT and INSERT VALUES forms.",
        .next = "Expand SELECT projections/expressions, UPDATE, DELETE, DDL, joins, ordering, grouping, and functions.",
    },
    .{
        .area = "Full query planner",
        .status = .scaffold,
        .evidence = "Hard-coded rowid and single-column index fast paths exist.",
        .next = "Add binder, cost model, scan/index selection, joins, sorting, grouping.",
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
        .status = .missing,
        .evidence = "No xConnect/xBestIndex/xFilter-style module system.",
        .next = "Design extension ABI after core VM/planner exists.",
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
