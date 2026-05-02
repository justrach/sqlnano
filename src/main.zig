const std = @import("std");
const sqlnano = @import("sqlnano.zig");

const max_database_bytes = 1024 * 1024 * 1024;

pub fn main(init: std.process.Init) !void {
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    var stderr_buffer: [1024]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(init.io, &stderr_buffer);
    const stderr = &stderr_writer.interface;

    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();

    _ = args.skip(); // executable name
    const command = args.next() orelse {
        try printUsage(stdout);
        try stdout.flush();
        return;
    };

    if (std.mem.eql(u8, command, "inspect")) {
        const path = args.next() orelse {
            try stderr.print("error: missing database path\n\n", .{});
            try printUsage(stderr);
            try stderr.flush();
            return error.MissingDatabasePath;
        };
        if (args.next() != null) {
            try stderr.print("error: too many arguments\n\n", .{});
            try printUsage(stderr);
            try stderr.flush();
            return error.TooManyArguments;
        }

        try inspectDatabase(init, stdout, path);
        try stdout.flush();
        return;
    }

    if (std.mem.eql(u8, command, "select")) {
        const path = args.next() orelse {
            try stderr.print("error: missing database path\n\n", .{});
            try printUsage(stderr);
            try stderr.flush();
            return error.MissingDatabasePath;
        };
        const query_or_table = args.next() orelse {
            try stderr.print("error: missing SQL query or table name\n\n", .{});
            try printUsage(stderr);
            try stderr.flush();
            return error.MissingQuery;
        };
        if (args.next() != null) {
            try stderr.print("error: too many arguments\n\n", .{});
            try printUsage(stderr);
            try stderr.flush();
            return error.TooManyArguments;
        }

        if (looksLikeSql(query_or_table)) {
            try selectSql(init, stdout, path, query_or_table);
        } else {
            try selectTable(init, stdout, path, query_or_table);
        }
        try stdout.flush();
        return;
    }

    if (std.mem.eql(u8, command, "exec")) {
        const path = args.next() orelse {
            try stderr.print("error: missing database path\n\n", .{});
            try printUsage(stderr);
            try stderr.flush();
            return error.MissingDatabasePath;
        };
        const sql = args.next() orelse {
            try stderr.print("error: missing SQL\n\n", .{});
            try printUsage(stderr);
            try stderr.flush();
            return error.MissingQuery;
        };
        if (args.next() != null) {
            try stderr.print("error: too many arguments\n\n", .{});
            try printUsage(stderr);
            try stderr.flush();
            return error.TooManyArguments;
        }

        try execSql(init, stdout, path, sql);
        try stdout.flush();
        return;
    }

    if (std.mem.eql(u8, command, "bench-read")) {
        const path = args.next() orelse {
            try stderr.print("error: missing database path\n\n", .{});
            try printUsage(stderr);
            try stderr.flush();
            return error.MissingDatabasePath;
        };
        const query = args.next() orelse {
            try stderr.print("error: missing SQL query\n\n", .{});
            try printUsage(stderr);
            try stderr.flush();
            return error.MissingQuery;
        };
        const iterations_text = args.next() orelse {
            try stderr.print("error: missing iteration count\n\n", .{});
            try printUsage(stderr);
            try stderr.flush();
            return error.MissingIterationCount;
        };
        if (args.next() != null) {
            try stderr.print("error: too many arguments\n\n", .{});
            try printUsage(stderr);
            try stderr.flush();
            return error.TooManyArguments;
        }

        try benchRead(init, stdout, path, query, iterations_text);
        try stdout.flush();
        return;
    }

    if (std.mem.eql(u8, command, "parity")) {
        if (args.next() != null) {
            try stderr.print("error: too many arguments\n\n", .{});
            try printUsage(stderr);
            try stderr.flush();
            return error.TooManyArguments;
        }

        try printParity(stdout);
        try stdout.flush();
        return;
    }

    if (std.mem.eql(u8, command, "bench-write")) {
        const path = args.next() orelse {
            try stderr.print("error: missing database path\n\n", .{});
            try printUsage(stderr);
            try stderr.flush();
            return error.MissingDatabasePath;
        };
        const table_name = args.next() orelse {
            try stderr.print("error: missing table name\n\n", .{});
            try printUsage(stderr);
            try stderr.flush();
            return error.MissingTable;
        };
        const iters_text = args.next() orelse {
            try stderr.print("error: missing iteration count\n\n", .{});
            try printUsage(stderr);
            try stderr.flush();
            return error.MissingIterations;
        };
        const sync_text = args.next();
        if (args.next() != null) {
            try stderr.print("error: too many arguments\n\n", .{});
            try printUsage(stderr);
            try stderr.flush();
            return error.TooManyArguments;
        }
        try benchWrite(init, stdout, path, table_name, iters_text, sync_text);
        try stdout.flush();
        return;
    }

    if (std.mem.eql(u8, command, "wal-checkpoint")) {
        const path = args.next() orelse {
            try stderr.print("error: missing database path\n\n", .{});
            try printUsage(stderr);
            try stderr.flush();
            return error.MissingDatabasePath;
        };
        if (args.next() != null) {
            try stderr.print("error: too many arguments\n\n", .{});
            try printUsage(stderr);
            try stderr.flush();
            return error.TooManyArguments;
        }
        const freed = try sqlnano.sqlite.write_mod.recoverAndCompact(init.gpa, init.io, path);
        try stdout.print("wal_path: {s}-snwal\n", .{path});
        try stdout.print("compacted_bytes: {d}\n", .{freed});
        try stdout.flush();
        return;
    }

    if (std.mem.eql(u8, command, "wal-status")) {
        const path = args.next() orelse {
            try stderr.print("error: missing database path\n\n", .{});
            try printUsage(stderr);
            try stderr.flush();
            return error.MissingDatabasePath;
        };
        if (args.next() != null) {
            try stderr.print("error: too many arguments\n\n", .{});
            try printUsage(stderr);
            try stderr.flush();
            return error.TooManyArguments;
        }
        try walStatus(init, stdout, path);
        try stdout.flush();
        return;
    }

    if (std.mem.eql(u8, command, "help") or std.mem.eql(u8, command, "--help") or std.mem.eql(u8, command, "-h")) {
        try printUsage(stdout);
        try stdout.flush();
        return;
    }

    try stderr.print("error: unknown command '{s}'\n\n", .{command});
    try printUsage(stderr);
    try stderr.flush();
    return error.UnknownCommand;
}

fn printUsage(writer: *std.Io.Writer) !void {
    try writer.print(
        \\sqlnano: lightweight SQLite-compatible SQL engine
        \\
        \\Usage:
        \\  sqlnano inspect <database.db>                  Inspect SQLite header, schema, and row previews
        \\  sqlnano select <database.db> <table>            Read rows from a basic SQLite table
        \\  sqlnano select <database.db> "SELECT * FROM t"  Run tiny read-only SELECT SQL
        \\  sqlnano exec <database.db> "INSERT INTO t VALUES (...)"  Append a simple row
        \\  sqlnano bench-read <database.db> "SELECT * FROM t WHERE rowid = 1" <N>  Benchmark hot read path
        \\  sqlnano bench-write <database.db> <table> <N>  Benchmark durable inserts via a long-lived Connection
        \\  sqlnano wal-status <database.db>               Inspect the sidecar WAL (`<db>-snwal`)
        \\  sqlnano wal-checkpoint <database.db>           Replay any leftover WAL entries and truncate
        \\  sqlnano parity                                 Show SQLite/Turso compatibility parity table
        \\  sqlnano help                                   Show this help
        \\
    , .{});
}

fn printParity(writer: *std.Io.Writer) !void {
    const score = sqlnano.sqlite.parityCompletionScore();
    try writer.print("sqlnano SQLite/Turso parity\n", .{});
    try writer.print("complete_or_basic: {d}/{d}\n\n", .{ score.done, score.total });
    try writer.print("| Area | Status | Evidence | Next |\n", .{});
    try writer.print("|---|---|---|---|\n", .{});
    for (sqlnano.sqlite.parityFeatures) |feature| {
        try writer.print("| {s} | {s} | {s} | {s} |\n", .{
            feature.area,
            sqlnano.sqlite.parityStatusLabel(feature.status),
            feature.evidence,
            feature.next,
        });
    }
}

fn inspectDatabase(init: std.process.Init, writer: *std.Io.Writer, path: []const u8) !void {
    var mf = try sqlnano.sqlite.mapped_file.MappedFile.open(init.io, path, .read_only);
    defer mf.deinit();
    const bytes = mf.items;

    const reader = try sqlnano.sqlite.PageReader.init(bytes);
    const header = reader.db_header;

    try writer.print("file: {s}\n", .{path});
    try writer.print("sqlite: yes\n", .{});
    try writer.print("page_size: {d}\n", .{header.page_size});
    try writer.print("page_count: {d}\n", .{reader.pageCount()});
    try writer.print("journal_mode: {s}\n", .{if (header.isWal()) "wal" else "rollback"});
    try writer.print("schema_format: {d}\n", .{header.schema_format});
    try writer.print("text_encoding: {s}\n", .{encodingName(header.text_encoding)});
    try writer.print("sqlite_version_number: {d}\n", .{header.sqlite_version_number});

    const schema = try sqlnano.sqlite.readSchema(reader, init.gpa);
    defer schema.deinit(init.gpa);

    try writer.print("schema_entries: {d}\n", .{schema.entries.len});
    for (schema.entries) |entry| {
        try writer.print("- {s} {s} table={s} root={d}\n", .{
            entry.object_type,
            entry.name,
            entry.table_name,
            entry.root_page,
        });
        if (entry.sql.len != 0) try writer.print("  sql: {s}\n", .{entry.sql});

        if (entry.isTable() and !isInternalTable(entry.name) and entry.root_page > 0) {
            var info = sqlnano.sqlite.tableInfo(entry, init.gpa) catch |err| {
                try writer.print("  columns: unavailable ({s})\n", .{@errorName(err)});
                continue;
            };
            defer info.deinit(init.gpa);
            try writer.print("  columns: ", .{});
            try printColumns(writer, info.columns);
            try writer.print("\n", .{});

            const tbl = sqlnano.sqlite.scanTable(reader, @intCast(entry.root_page), init.gpa) catch |err| {
                try writer.print("  rows: unavailable ({s})\n", .{@errorName(err)});
                continue;
            };
            defer tbl.deinit(init.gpa);
            try writer.print("  rows: {d}\n", .{tbl.rows.len});
            const preview_count = @min(tbl.rows.len, 5);
            for (tbl.rows[0..preview_count]) |row| {
                const projected = try sqlnano.sqlite.projectRow(info, row, init.gpa);
                defer projected.deinit(init.gpa);
                try writer.print("  row {d}: ", .{row.rowid});
                try printNamedValues(writer, projected.values);
                try writer.print("\n", .{});
            }
            if (tbl.rows.len > preview_count) try writer.print("  ... {d} more rows\n", .{tbl.rows.len - preview_count});
        } else if (entry.isIndex() and entry.root_page > 0) {
            const idx = sqlnano.sqlite.scanIndex(reader, @intCast(entry.root_page), init.gpa) catch |err| {
                try writer.print("  index_entries: unavailable ({s})\n", .{@errorName(err)});
                continue;
            };
            defer idx.deinit(init.gpa);
            try writer.print("  index_entries: {d}\n", .{idx.entries.len});
        }
    }
}

fn selectTable(init: std.process.Init, writer: *std.Io.Writer, path: []const u8, table_name: []const u8) !void {
    var mf = try sqlnano.sqlite.mapped_file.MappedFile.open(init.io, path, .read_only);
    defer mf.deinit();
    const bytes = mf.items;

    const reader = try sqlnano.sqlite.PageReader.init(bytes);
    const schema = try sqlnano.sqlite.readSchema(reader, init.gpa);
    defer schema.deinit(init.gpa);

    const entry = schema.findTable(table_name) orelse return error.TableNotFound;
    var info = try sqlnano.sqlite.tableInfo(entry, init.gpa);
    defer info.deinit(init.gpa);
    const tbl = try sqlnano.sqlite.scanTable(reader, @intCast(entry.root_page), init.gpa);
    defer tbl.deinit(init.gpa);

    try writer.print("table: {s}\n", .{entry.name});
    try writer.print("columns: ", .{});
    try printColumns(writer, info.columns);
    try writer.print("\n", .{});
    try writer.print("rows: {d}\n", .{tbl.rows.len});
    for (tbl.rows) |row| {
        const projected = try sqlnano.sqlite.projectRow(info, row, init.gpa);
        defer projected.deinit(init.gpa);
        try writer.print("{d}: ", .{row.rowid});
        try printNamedValues(writer, projected.values);
        try writer.print("\n", .{});
    }
}

fn selectSql(init: std.process.Init, writer: *std.Io.Writer, path: []const u8, query: []const u8) !void {
    var mf = try sqlnano.sqlite.mapped_file.MappedFile.open(init.io, path, .read_only);
    defer mf.deinit();
    const bytes = mf.items;

    const reader = try sqlnano.sqlite.PageReader.init(bytes);
    const schema = try sqlnano.sqlite.readSchema(reader, init.gpa);
    defer schema.deinit(init.gpa);
    const result = try sqlnano.sqlite.executeSelect(reader, schema, query, init.gpa);
    defer result.deinit(init.gpa);

    try writer.print("table: {s}\n", .{result.table_info.name});
    try writer.print("columns: [", .{});
    for (result.columns, 0..) |col, i| {
        if (i > 0) try writer.print(", ", .{});
        try writer.print("{s}", .{col.name});
    }
    try writer.print("]\n", .{});
    try writer.print("rows: {d}\n", .{result.rows.len});
    for (result.rows) |row| {
        if (row.rowid >= 0) {
            try writer.print("{d}: ", .{row.rowid});
        } else {
            try writer.print("-: ", .{});
        }
        try printNamedValues(writer, row.values);
        try writer.print("\n", .{});
    }
}

fn execSql(init: std.process.Init, writer: *std.Io.Writer, path: []const u8, sql: []const u8) !void {
    const stmt = try sqlnano.sqlite.parseStatement(sql, init.gpa);
    switch (stmt) {
        .insert => |ins| {
            defer ins.deinit(init.gpa);
            var values = try init.gpa.alloc(sqlnano.sqlite.InsertValue, ins.values.len);
            defer init.gpa.free(values);
            for (ins.values, 0..) |value, i| values[i] = value.toInsertValue();
            const rowid = try sqlnano.sqlite.insertSimple(init.gpa, init.io, path, ins.table_name, values);
            try writer.print("inserted rowid: {d}\n", .{rowid});
        },
        .update => |upd| {
            const changed = try sqlnano.sqlite.write_mod.updateSimple(init.gpa, init.io, path, upd);
            try writer.print("updated rows: {d}\n", .{changed});
        },
        .delete => |del| {
            const changed = try sqlnano.sqlite.write_mod.deleteSimple(init.gpa, init.io, path, del);
            try writer.print("deleted rows: {d}\n", .{changed});
        },
        .select => return error.SelectNotSupportedByExec,
    }
}

fn benchRead(init: std.process.Init, writer: *std.Io.Writer, path: []const u8, query: []const u8, iterations_text: []const u8) !void {
    const iterations = try std.fmt.parseInt(usize, iterations_text, 10);
    if (iterations == 0) return error.InvalidIterationCount;

    var mf = try sqlnano.sqlite.mapped_file.MappedFile.open(init.io, path, .read_only);
    defer mf.deinit();
    const bytes = mf.items;

    const reader = try sqlnano.sqlite.PageReader.init(bytes);
    const schema = try sqlnano.sqlite.readSchema(reader, init.gpa);
    defer schema.deinit(init.gpa);

    const stmt = try sqlnano.sqlite.parseSelect(query, init.gpa);
    defer stmt.deinit(init.gpa);
    const entry = schema.findTable(stmt.table_name) orelse return error.TableNotFound;
    var info = try sqlnano.sqlite.tableInfo(entry, init.gpa);
    defer info.deinit(init.gpa);

    // Detect `SELECT COUNT(*) FROM t` (no WHERE) — SQLite's fast
    // COUNT path also just sums leaf-header cell counts, so we match
    // its apples-to-apples shape by doing the same.
    const is_count_star = stmt.where_expr == null and
        stmt.joins.len == 0 and
        stmt.projections.len == 1 and
        stmt.projections[0] == .count_star;

    var mode: []const u8 = if (is_count_star) "count-star" else "full-scan";
    var rowid: ?i64 = null;
    var indexed_rowids: ?[]i64 = null;
    defer if (indexed_rowids) |ids| init.gpa.free(ids);

    // bench-read accepts the same tiny subset as before — a single
    // `col = lit` equality at the top of the WHERE tree. Anything
    // richer falls out as `UnsupportedBenchmarkQuery`.
    if (stmt.where_expr) |w| {
        const wb = w.*;
        if (wb != .binary or wb.binary.op != .eq) return error.UnsupportedBenchmarkQuery;
        const eq = wb.binary;
        if (eq.lhs.* != .column or eq.rhs.* != .literal) return error.UnsupportedBenchmarkQuery;
        const cname = eq.lhs.column.name;
        const lit = eq.rhs.literal;
        if (sqlnano.sqlite.sql_mod.asciiEqlPub(cname, "rowid")) {
            switch (lit) {
                .integer => |v| {
                    rowid = v;
                    mode = "rowid-direct";
                },
                else => return error.UnsupportedBenchmarkQuery,
            }
        } else if (try sqlnano.sqlite.sql_mod.indexedRowidsForColumn(reader, schema, info, cname, lit, init.gpa)) |ids| {
            indexed_rowids = ids;
            mode = "prepared-index-rowids";
        } else {
            return error.UnsupportedBenchmarkQuery;
        }
    }

    var total_rows: usize = 0;
    const start = std.Io.Clock.awake.now(init.io).toNanoseconds();
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        if (rowid) |id| {
            if (try sqlnano.sqlite.table_mod.findRowByRowid(reader, info.root_page, id, init.gpa)) |found| {
                total_rows += 1;
                found.deinit(init.gpa);
            }
        } else if (indexed_rowids) |ids| {
            for (ids) |id| {
                if (try sqlnano.sqlite.table_mod.findRowByRowid(reader, info.root_page, id, init.gpa)) |found| {
                    total_rows += 1;
                    found.deinit(init.gpa);
                }
            }
        } else if (is_count_star) {
            const n = try sqlnano.sqlite.table_mod.countRows(reader, info.root_page);
            total_rows += @intCast(n);
        } else {
            // Zero-alloc full scan. `scanTableForEach` streams rows
            // through a stack-backed `InlineRecord` view and fires the
            // `Counter.tick` callback per row — the whole scan allocates
            // nothing per row (and nothing at all beyond the initial
            // page reads). This is what makes the reported
            // `rows_per_sec` reflect raw b-tree walking cost rather
            // than ArrayList churn.
            const Counter = struct {
                total: *u64,
                sink: *i64,
                fn tick(ctx: *const @This(), rid: i64, values: []const sqlnano.sqlite.record_mod.Value) anyerror!void {
                    ctx.total.* += 1;
                    // Sum rowid + every integer column into a sink so the
                    // optimizer can't elide value decoding. Matches what
                    // SQLite's bench harness does (sqlite3_column_int64
                    // on every column).
                    ctx.sink.* +%= rid;
                    for (values) |v| switch (v) {
                        .integer => |x| ctx.sink.* +%= x,
                        else => {},
                    };
                }
            };
            var rows_this_iter: u64 = 0;
            var sink: i64 = 0;
            const ctx: Counter = .{ .total = &rows_this_iter, .sink = &sink };
            try sqlnano.sqlite.table_mod.scanTableForEach(reader, info.root_page, &ctx, Counter.tick);
            total_rows += rows_this_iter;
            std.mem.doNotOptimizeAway(sink);
        }
    }
    const end = std.Io.Clock.awake.now(init.io).toNanoseconds();
    const elapsed_ns_i96 = end - start;
    const elapsed_ns: f64 = @floatFromInt(elapsed_ns_i96);
    const iterations_f: f64 = @floatFromInt(iterations);
    const total_rows_f: f64 = @floatFromInt(total_rows);

    try writer.print("mode: {s}\n", .{mode});
    try writer.print("iterations: {d}\n", .{iterations});
    try writer.print("rows_total: {d}\n", .{total_rows});
    try writer.print("elapsed_ms: {d:.3}\n", .{elapsed_ns / std.time.ns_per_ms});
    try writer.print("ns_per_iter: {d:.1}\n", .{elapsed_ns / iterations_f});
    try writer.print("iters_per_sec: {d:.0}\n", .{iterations_f * std.time.ns_per_s / elapsed_ns});
    try writer.print("rows_per_sec: {d:.0}\n", .{total_rows_f * std.time.ns_per_s / elapsed_ns});
}

fn benchWrite(
    init: std.process.Init,
    writer: *std.Io.Writer,
    path: []const u8,
    table_name: []const u8,
    iters_text: []const u8,
    sync_text: ?[]const u8,
) !void {
    const iterations = try std.fmt.parseInt(usize, iters_text, 10);
    if (iterations == 0) return error.InvalidIterationCount;

    const sync_mode: sqlnano.sqlite.wal_mod.SyncMode = if (sync_text) |s|
        if (std.ascii.eqlIgnoreCase(s, "full"))
            .full
        else if (std.ascii.eqlIgnoreCase(s, "normal"))
            .normal
        else if (std.ascii.eqlIgnoreCase(s, "off"))
            .off
        else
            return error.InvalidSyncMode
    else
        .full;

    var conn = try sqlnano.sqlite.Connection.open(init.gpa, init.io, path);
    defer conn.close();
    conn.setSyncMode(sync_mode);

    const start = std.Io.Clock.awake.now(init.io).toNanoseconds();
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        const values = [_]sqlnano.sqlite.InsertValue{
            .null,
            .{ .integer = @intCast(i) },
        };
        _ = try conn.insert(table_name, &values);
    }
    const end = std.Io.Clock.awake.now(init.io).toNanoseconds();

    const elapsed_ns: f64 = @floatFromInt(end - start);
    const iters_f: f64 = @floatFromInt(iterations);
    try writer.print("mode: connection-batch synchronous={s}\n", .{@tagName(sync_mode)});
    try writer.print("iterations: {d}\n", .{iterations});
    try writer.print("elapsed_ms: {d:.3}\n", .{elapsed_ns / std.time.ns_per_ms});
    try writer.print("us_per_op: {d:.1}\n", .{elapsed_ns / 1000.0 / iters_f});
    try writer.print("ops_per_sec: {d:.0}\n", .{iters_f * std.time.ns_per_s / elapsed_ns});
}

fn walStatus(init: std.process.Init, writer: *std.Io.Writer, db_path: []const u8) !void {
    const wal_path = try std.fmt.allocPrint(init.gpa, "{s}-snwal", .{db_path});
    defer init.gpa.free(wal_path);

    const cwd = std.Io.Dir.cwd();
    const file = cwd.openFile(init.io, wal_path, .{ .mode = .read_only }) catch |err| switch (err) {
        error.FileNotFound => {
            try writer.print("wal_path: {s}\n", .{wal_path});
            try writer.print("status: missing (no writes yet, or already truncated)\n", .{});
            return;
        },
        else => return err,
    };
    defer file.close(init.io);

    const stat = try file.stat(init.io);
    const size = stat.size;
    try writer.print("wal_path: {s}\n", .{wal_path});
    try writer.print("size_bytes: {d}\n", .{size});
    if (size == 0) {
        try writer.print("entries: 0\n", .{});
        return;
    }

    const buf = try init.gpa.alloc(u8, size);
    defer init.gpa.free(buf);
    const n = try file.readPositionalAll(init.io, buf, 0);
    const data = buf[0..n];

    const hdr_size = sqlnano.sqlite.wal_mod.HEADER_SIZE;
    var pos: usize = 0;
    var counts = [_]u32{0} ** 256;
    var max_lsn: u64 = 0;
    var latest_checkpoint: u64 = 0;
    var entries: u32 = 0;
    var partial_tail: bool = false;
    while (pos + hdr_size <= data.len) {
        const op = data[pos + 16];
        const length = std.mem.readInt(u32, data[pos + 8 ..][0..4], .little);
        const lsn = std.mem.readInt(u64, data[pos + 0 ..][0..8], .little);
        if (lsn == 0) break;
        const total = hdr_size + length + ((8 - ((hdr_size + length) & 7)) & 7);
        if (pos + total > data.len) {
            partial_tail = true;
            break;
        }
        counts[op] +%= 1;
        if (lsn > max_lsn) max_lsn = lsn;
        if (op == @intFromEnum(sqlnano.sqlite.wal_mod.OpCode.checkpoint) and lsn > latest_checkpoint) {
            latest_checkpoint = lsn;
        }
        entries += 1;
        pos += total;
    }

    try writer.print("entries: {d}\n", .{entries});
    try writer.print("max_lsn: {d}\n", .{max_lsn});
    try writer.print("latest_checkpoint_lsn: {d}\n", .{latest_checkpoint});
    try writer.print("unapplied_lsns_after_checkpoint: {d}\n", .{if (max_lsn > latest_checkpoint) max_lsn - latest_checkpoint else 0});
    try writer.print("partial_tail: {s}\n", .{if (partial_tail) "yes" else "no"});
    try writer.print("counts:\n", .{});
    inline for (.{
        .{ "row_insert", sqlnano.sqlite.wal_mod.OpCode.row_insert },
        .{ "row_update", sqlnano.sqlite.wal_mod.OpCode.row_update },
        .{ "row_delete", sqlnano.sqlite.wal_mod.OpCode.row_delete },
        .{ "txn_commit", sqlnano.sqlite.wal_mod.OpCode.txn_commit },
        .{ "checkpoint", sqlnano.sqlite.wal_mod.OpCode.checkpoint },
    }) |pair| {
        try writer.print("  {s}: {d}\n", .{ pair[0], counts[@intFromEnum(pair[1])] });
    }
}

fn printColumns(writer: *std.Io.Writer, columns: []const sqlnano.sqlite.Column) !void {
    try writer.print("[", .{});
    for (columns, 0..) |column, i| {
        if (i != 0) try writer.print(", ", .{});
        try writer.print("{s}", .{column.name});
        if (column.is_integer_primary_key) try writer.print(" INTEGER PRIMARY KEY", .{});
    }
    try writer.print("]", .{});
}

fn printNamedValues(writer: *std.Io.Writer, values: []const sqlnano.sqlite.catalog_mod.NamedValue) !void {
    try writer.print("[", .{});
    for (values, 0..) |value, i| {
        if (i != 0) try writer.print(", ", .{});
        try writer.print("{s}=", .{value.name});
        try printValue(writer, value.value);
    }
    try writer.print("]", .{});
}

fn printValue(writer: *std.Io.Writer, value: sqlnano.sqlite.Value) !void {
    switch (value) {
        .null => try writer.print("null", .{}),
        .integer => |int| try writer.print("{d}", .{int}),
        .real => |real| try writer.print("{d}", .{real}),
        .text => |text| try writer.print("\"{s}\"", .{text}),
        .blob => |blob| try writer.print("<blob {d} bytes>", .{blob.len}),
    }
}

fn looksLikeSql(text: []const u8) bool {
    return startsWithKeyword(std.mem.trim(u8, text, " \t\r\n"), "SELECT");
}

fn startsWithKeyword(text: []const u8, keyword: []const u8) bool {
    if (text.len < keyword.len) return false;
    if (text.len > keyword.len and isIdent(text[keyword.len])) return false;
    for (keyword, 0..) |c, i| {
        if (std.ascii.toUpper(text[i]) != c) return false;
    }
    return true;
}

fn isIdent(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn isInternalTable(name: []const u8) bool {
    return std.mem.startsWith(u8, name, "sqlite_");
}

fn encodingName(value: u32) []const u8 {
    return switch (value) {
        0 => "unspecified",
        1 => "utf-8",
        2 => "utf-16le",
        3 => "utf-16be",
        else => "unknown",
    };
}
