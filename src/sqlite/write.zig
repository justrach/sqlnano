const std = @import("std");
const btree = @import("btree.zig");
const catalog = @import("catalog.zig");
const header = @import("header.zig");
const page = @import("page.zig");
const record = @import("record.zig");
const schema = @import("schema.zig");
const table = @import("table.zig");
const wal_mod = @import("wal.zig");
const wal_codec = @import("wal_codec.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const WriteError = anyerror;

pub const InsertValue = union(enum) {
    null,
    integer: i64,
    text: []const u8,
};

/// Process-local monotonic transaction-id source. Each WAL-logged op gets a
/// fresh id; this is sufficient because we group-commit per op and
/// checkpoint immediately after applying.
var g_txn_counter: std.atomic.Value(u64) = .init(1);

fn nextTxnId() u64 {
    return g_txn_counter.fetchAdd(1, .monotonic);
}

fn walPathFor(allocator: Allocator, db_path: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}-snwal", .{db_path});
}

const ReplayContext = struct {
    gpa: Allocator,
    image: *std.ArrayList(u8),
    /// Flipped to true by any successful apply. Callers use it to decide
    /// whether the post-recovery image needs a `writeFile`.
    dirty: bool,
};

fn replayApply(entry: wal_mod.Entry, ctx: ?*anyopaque) anyerror!void {
    const rc: *ReplayContext = @ptrCast(@alignCast(ctx.?));
    switch (entry.op) {
        .row_insert => {
            const dec = try wal_codec.decodeInsert(rc.gpa, entry.payload);
            defer dec.deinit(rc.gpa);
            _ = applyInsertCore(rc.gpa, rc.image, dec.table_name, dec.values, dec.rowid, .idempotent) catch |err| switch (err) {
                error.AlreadyApplied => return,
                else => return err,
            };
            rc.dirty = true;
        },
        .row_update => {
            const dec = try wal_codec.decodeUpdate(entry.payload);
            const changed = try applyUpdateCore(rc.gpa, rc.image, dec.statement);
            if (changed > 0) rc.dirty = true;
        },
        .row_delete => {
            const dec = try wal_codec.decodeDelete(entry.payload);
            const changed = try applyDeleteCore(rc.gpa, rc.image, dec.statement);
            if (changed > 0) rc.dirty = true;
        },
        else => {},
    }
}

const ApplyMode = enum { fresh, idempotent };

/// Long-lived database handle. Holds the data file image in memory, runs
/// every mutation against the in-memory buffer, and only touches the file
/// when `flush` fires (at `close`, at `checkpoint_threshold_bytes` of WAL,
/// or on an explicit caller request).
///
/// Hot path per op: encode payload → `wal.write` → `wal.commit` (one
/// fsync) → mutate the in-memory image. No file I/O on the data file
/// per op. This turns a tight insert loop from O(N * file_size) total
/// bytes written into O(1) data-file writes per checkpoint.
///
/// Crash recovery: on open we load the file image, then replay every
/// committed WAL entry past the last checkpoint into that image. Every
/// entry's apply is idempotent (INSERT returns `AlreadyApplied` on rowid
/// clash; UPDATE/DELETE rebuild from in-memory row state so a second
/// apply is a no-op). After recovery the post-replay image is flushed
/// and the WAL is checkpointed+compacted.
///
/// The `db_path` slice is borrowed and must outlive the connection.
pub const Connection = struct {
    gpa: Allocator,
    io: Io,
    db_path: []const u8,
    wal_path: []u8,
    wal: wal_mod.Wal,
    /// Mutable in-memory copy of the data file. All writes go through
    /// this buffer; `flush` is the only code that writes it to disk.
    image: std.ArrayList(u8),
    /// Set by any op that mutates `image`. `flush` clears it after a
    /// successful `writeFile`.
    image_dirty: bool,
    /// Per-table cache of the next rowid to assign for `VALUES (NULL, ...)`
    /// inserts. Lazily populated from a single `scanTable` per table, then
    /// incremented in place on every auto-rowid insert. Anything that
    /// could shift rowids (explicit rowid INSERT, DELETE, ROLLBACK once
    /// that exists) invalidates the matching entry.
    next_rowid_cache: std.StringHashMap(i64),

    /// When the on-disk WAL grows past this many bytes, `maybeCheckpoint`
    /// flushes the image and compacts the WAL. Big enough that a batch
    /// of small ops avoids paying a file rewrite per op; small enough
    /// that crash replay stays cheap.
    pub const checkpoint_threshold_bytes: u64 = 64 * 1024;

    pub fn open(gpa: Allocator, io: Io, db_path: []const u8) WriteError!Connection {
        const wal_path = try walPathFor(gpa, db_path);
        errdefer gpa.free(wal_path);

        var wal = try wal_mod.Wal.open(std.Io.Dir.cwd(), io, gpa, wal_path);
        errdefer wal.close(io);

        // Load the full data file into memory. The buffer is owned by
        // `Connection` from here until `close`.
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, db_path, gpa, .limited(1024 * 1024 * 1024));
        defer gpa.free(bytes);

        var image: std.ArrayList(u8) = .empty;
        errdefer image.deinit(gpa);
        try image.appendSlice(gpa, bytes);

        var conn = Connection{
            .gpa = gpa,
            .io = io,
            .db_path = db_path,
            .wal_path = wal_path,
            .wal = wal,
            .image = image,
            .image_dirty = false,
            .next_rowid_cache = std.StringHashMap(i64).init(gpa),
        };
        errdefer conn.deinitCache();

        var rc = ReplayContext{ .gpa = gpa, .image = &conn.image, .dirty = false };
        try conn.wal.recover(io, 0, replayApply, &rc);
        // Recovery may have mutated the image; propagate that so `flush`
        // writes the post-recovery state to disk before compacting the WAL.
        if (rc.dirty) conn.image_dirty = true;
        try conn.flush();

        return conn;
    }

    pub fn close(self: *Connection) void {
        // Best-effort final flush so the on-disk state reflects every
        // committed op and the WAL is empty.
        self.flush() catch {};
        self.wal.close(self.io);
        self.image.deinit(self.gpa);
        self.deinitCache();
        self.gpa.free(self.wal_path);
    }

    fn deinitCache(self: *Connection) void {
        var it = self.next_rowid_cache.iterator();
        while (it.next()) |entry| self.gpa.free(entry.key_ptr.*);
        self.next_rowid_cache.deinit();
    }

    fn invalidateRowidCache(self: *Connection, table_name: []const u8) void {
        if (self.next_rowid_cache.fetchRemove(table_name)) |kv| self.gpa.free(kv.key);
    }

    /// Persist the image (if dirty), then checkpoint + compact the WAL.
    /// Safe to call at any point; no-op when image is clean and WAL is
    /// empty.
    pub fn flush(self: *Connection) WriteError!void {
        if (self.image_dirty) {
            try std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = self.db_path, .data = self.image.items });
            self.image_dirty = false;
        }
        if (self.wal.end_offset == 0 and self.wal.synced_lsn == self.wal.checkpoint_lsn) return;
        if (self.wal.synced_lsn > self.wal.checkpoint_lsn) {
            try self.wal.checkpoint(self.io, wal_mod.DB_TAG_SQLITE);
        }
        self.wal.compact(self.io) catch {};
    }

    fn maybeCheckpoint(self: *Connection) WriteError!void {
        if (self.wal.end_offset < checkpoint_threshold_bytes) return;
        try self.flush();
    }

    pub fn insert(self: *Connection, table_name: []const u8, values: []const InsertValue) WriteError!i64 {
        const rowid = try self.resolveRowid(table_name, values);
        const payload = try wal_codec.encodeInsert(self.gpa, table_name, rowid, values);
        defer self.gpa.free(payload);
        const txn_id = nextTxnId();
        _ = try self.wal.write(self.io, txn_id, .row_insert, wal_mod.DB_TAG_SQLITE, 0, payload);
        try self.wal.commit(self.io, txn_id, wal_mod.DB_TAG_SQLITE);

        // Fast path: no indexes, append-at-end, fits in current rightmost
        // leaf. Short-circuits the full b-tree rebuild that the generic
        // path would do. On any condition we don't want to handle here
        // the function returns `false` and we fall through.
        const fast = try self.tryFastAppendInsert(table_name, values, rowid);
        if (!fast) {
            _ = try applyInsertCore(self.gpa, &self.image, table_name, values, rowid, .fresh);
        }
        try self.bumpRowidCache(table_name, rowid);
        self.image_dirty = true;
        try self.maybeCheckpoint();
        return rowid;
    }

    /// Compute the rowid a `VALUES (NULL, ...)` insert would receive,
    /// using the per-table cache to skip the `scanTable` scan when
    /// possible. For explicit rowids we defer to the old slow path.
    fn resolveRowid(self: *Connection, table_name: []const u8, values: []const InsertValue) WriteError!i64 {
        const reader = try page.PageReader.init(self.image.items);
        if (reader.db_header.isWal()) return error.WalModeUnsupported;
        const db_schema = try schema.readSchema(reader, self.gpa);
        defer db_schema.deinit(self.gpa);
        const entry = db_schema.findTable(table_name) orelse return error.TableNotFound;
        var info = try catalog.tableInfo(entry, self.gpa);
        defer info.deinit(self.gpa);
        if (values.len != info.columns.len) return error.ColumnCountMismatch;
        if (info.root_page == 1) return error.UnsupportedInsert;

        const is_auto = blk: {
            if (info.integer_primary_key_index) |ipk| {
                break :blk switch (values[ipk]) {
                    .null => true,
                    .integer => |v| if (v <= 0) return error.UnsupportedRowid else false,
                    else => return error.UnsupportedRowid,
                };
            }
            break :blk true; // No integer PK; rowid auto-increments.
        };

        if (!is_auto) {
            // Explicit rowid — cache can't help; defer to the scan-based
            // resolver, which also checks for duplicate.
            return resolveInsertRowid(self.gpa, &self.image, table_name, values);
        }

        if (self.next_rowid_cache.get(table_name)) |cached| return cached;

        // Cold path: one scan to find the current max rowid, then cache.
        const scanned = try table.scanTable(reader, info.root_page, self.gpa);
        defer scanned.deinit(self.gpa);
        var max: i64 = 0;
        for (scanned.rows) |row| max = @max(max, row.rowid);
        return max + 1;
    }

    fn bumpRowidCache(self: *Connection, table_name: []const u8, last_rowid: i64) !void {
        const gop = try self.next_rowid_cache.getOrPut(table_name);
        if (!gop.found_existing) {
            gop.key_ptr.* = try self.gpa.dupe(u8, table_name);
            gop.value_ptr.* = last_rowid + 1;
        } else if (gop.value_ptr.* <= last_rowid) {
            gop.value_ptr.* = last_rowid + 1;
        }
    }

    /// If the table has no indexes and its rightmost leaf has room for
    /// the new cell, append the cell in place and return true. Otherwise
    /// return false — the caller falls through to the full rebuild.
    ///
    /// The row's rowid must already be greater than every rowid in the
    /// table (enforced by the auto-rowid cache). This keeps the leaf's
    /// rowid ordering intact without rescanning.
    fn tryFastAppendInsert(
        self: *Connection,
        table_name: []const u8,
        values: []const InsertValue,
        rowid: i64,
    ) WriteError!bool {
        const reader = try page.PageReader.init(self.image.items);
        if (reader.db_header.isWal()) return false;
        const db_schema = try schema.readSchema(reader, self.gpa);
        defer db_schema.deinit(self.gpa);
        const entry = db_schema.findTable(table_name) orelse return false;
        var info = try catalog.tableInfo(entry, self.gpa);
        defer info.deinit(self.gpa);
        if (values.len != info.columns.len) return false;
        if (info.root_page == 1) return false;

        // Any index on this table → defer to the rebuild path, which
        // keeps indexes in sync.
        for (db_schema.entries) |e| {
            if (!e.isIndex() or e.root_page <= 0) continue;
            if (std.ascii.eqlIgnoreCase(e.table_name, info.name)) return false;
        }

        // Walk to the rightmost leaf. A malformed tree aborts the fast
        // path quietly; the rebuild caller will either succeed or
        // surface a real error.
        const rightmost = rightmostTableLeaf(reader, info.root_page) catch return false;

        // Build the cell bytes.
        const payload = try encodeRecord(info, rowid, values, self.gpa);
        defer self.gpa.free(payload);
        const page_size: usize = reader.db_header.page_size;
        const reserved: usize = reader.db_header.reserved_space;
        const usable = page_size - reserved;
        const info_pl = btree.tableLeafPayloadInfo(payload.len, usable);
        if (info_pl.overflow_page != null) return false;

        var cell: std.ArrayList(u8) = .empty;
        defer cell.deinit(self.gpa);
        try appendVarint(&cell, self.gpa, @intCast(payload.len));
        try appendVarint(&cell, self.gpa, @intCast(rowid));
        try cell.appendSlice(self.gpa, payload);

        const mutable = self.image.items;
        const page_start = (@as(usize, rightmost) - 1) * page_size;
        if (page_start + page_size > mutable.len) return false;
        const hdr_off: usize = if (rightmost == 1) header.HEADER_SIZE else 0;
        const base = page_start + hdr_off;
        if (mutable[base] != @intFromEnum(btree.PageType.table_leaf)) return false;

        const cell_count = readU16(mutable[base + 3 .. base + 5]);
        const stored_content_start = readU16(mutable[base + 5 .. base + 7]);
        const content_start_abs_old: usize = if (stored_content_start == 0)
            page_start + page_size
        else
            page_start + stored_content_start;

        const ptr_slot = base + 8 + @as(usize, cell_count) * 2;
        const new_cell_start_abs = content_start_abs_old - cell.items.len;
        // Must fit: new cell content can't collide with the pointer array
        // after we grow that array by one more slot.
        if (new_cell_start_abs < ptr_slot + 2) return false;

        @memcpy(mutable[new_cell_start_abs..][0..cell.items.len], cell.items);
        const new_rel_off: u16 = @intCast(new_cell_start_abs - page_start);
        writeU16(mutable[ptr_slot..][0..2], new_rel_off);
        writeU16(mutable[base + 3 .. base + 5], cell_count + 1);
        writeU16(mutable[base + 5 .. base + 7], new_rel_off);

        // Bump the file change counter so SQLite notices the mutation on
        // a reopen. The duplicate write into `version_valid_for` keeps
        // WAL-aware readers consistent.
        const current_change = readU32(mutable[24..28]);
        writeU32(mutable[24..28], current_change +% 1);
        if (mutable.len >= 96) writeU32(mutable[92..96], current_change +% 1);

        return true;
    }

    pub fn update(self: *Connection, stmt: @import("ast.zig").UpdateStatement) WriteError!usize {
        const payload = try wal_codec.encodeUpdate(self.gpa, stmt);
        defer self.gpa.free(payload);
        const txn_id = nextTxnId();
        _ = try self.wal.write(self.io, txn_id, .row_update, wal_mod.DB_TAG_SQLITE, 0, payload);
        try self.wal.commit(self.io, txn_id, wal_mod.DB_TAG_SQLITE);
        const changed = try applyUpdateCore(self.gpa, &self.image, stmt);
        if (changed > 0) {
            self.image_dirty = true;
            // UPDATE currently can't touch rowid, but be defensive.
            self.invalidateRowidCache(stmt.table_name);
        }
        try self.maybeCheckpoint();
        return changed;
    }

    pub fn delete(self: *Connection, stmt: @import("ast.zig").DeleteStatement) WriteError!usize {
        const payload = try wal_codec.encodeDelete(self.gpa, stmt);
        defer self.gpa.free(payload);
        const txn_id = nextTxnId();
        _ = try self.wal.write(self.io, txn_id, .row_delete, wal_mod.DB_TAG_SQLITE, 0, payload);
        try self.wal.commit(self.io, txn_id, wal_mod.DB_TAG_SQLITE);
        const changed = try applyDeleteCore(self.gpa, &self.image, stmt);
        if (changed > 0) {
            self.image_dirty = true;
            // Deleting rows doesn't lower next-rowid (SQLite doesn't
            // reuse rowids), but we invalidate so a future auto-rowid
            // insert re-derives from the authoritative image rather
            // than a stale count.
            self.invalidateRowidCache(stmt.table_name);
        }
        try self.maybeCheckpoint();
        return changed;
    }
};

fn rightmostTableLeaf(reader: page.PageReader, start_page: u32) !u32 {
    var p = start_page;
    while (true) {
        const ref = try reader.page(p);
        const hdr = try btree.PageHeader.parse(ref);
        switch (hdr.page_type) {
            .table_leaf => return p,
            .table_interior => p = hdr.right_most_pointer orelse return error.MalformedInterior,
            else => return error.UnexpectedPageType,
        }
    }
}

fn readU32(bytes: []const u8) u32 {
    return std.mem.readInt(u32, bytes[0..4], .big);
}

/// Open the WAL beside `db_path`, replay any committed-but-unapplied
/// entries against the data file, then truncate the WAL if it ends in a
/// clean state. Useful as a CLI maintenance op or after a crash before
/// resuming writes. Returns the byte count freed by the truncate (0 if
/// the WAL was already empty or could not be compacted).
pub fn recoverAndCompact(gpa: Allocator, io: Io, db_path: []const u8) WriteError!u64 {
    const wal_path = try walPathFor(gpa, db_path);
    defer gpa.free(wal_path);
    var wal = try wal_mod.Wal.open(std.Io.Dir.cwd(), io, gpa, wal_path);
    defer wal.close(io);

    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, db_path, gpa, .limited(1024 * 1024 * 1024));
    defer gpa.free(bytes);

    var image: std.ArrayList(u8) = .empty;
    defer image.deinit(gpa);
    try image.appendSlice(gpa, bytes);

    var rc = ReplayContext{ .gpa = gpa, .image = &image, .dirty = false };
    try wal.recover(io, 0, replayApply, &rc);

    // Persist the post-recovery image so the WAL entries we just replayed
    // are on stable storage before we checkpoint them away. Only touch
    // disk when recovery actually changed anything.
    if (rc.dirty) {
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = db_path, .data = image.items });
    }

    if (wal.synced_lsn > wal.checkpoint_lsn) {
        try wal.checkpoint(io, wal_mod.DB_TAG_SQLITE);
    }

    const before = wal.end_offset;
    wal.compact(io) catch return 0;
    return before;
}

/// One-shot convenience wrapper: opens a `Connection`, runs a single
/// INSERT, then closes. Equivalent to:
///     var c = try Connection.open(gpa, io, path); defer c.close();
///     return c.insert(table_name, values);
pub fn insertSimple(gpa: Allocator, io: Io, path: []const u8, table_name: []const u8, values: []const InsertValue) WriteError!i64 {
    var conn = try Connection.open(gpa, io, path);
    defer conn.close();
    return conn.insert(table_name, values);
}

/// Determine the rowid the next INSERT would receive without mutating the
/// database. Mirrors the rowid-resolution arm of `applyInsertCore` so the
/// public wrapper can log the resolved rowid before applying.
fn resolveInsertRowid(gpa: Allocator, image: *std.ArrayList(u8), table_name: []const u8, values: []const InsertValue) WriteError!i64 {
    const reader = try page.PageReader.init(image.items);
    if (reader.db_header.isWal()) return error.WalModeUnsupported;
    const db_schema = try schema.readSchema(reader, gpa);
    defer db_schema.deinit(gpa);
    const entry = db_schema.findTable(table_name) orelse return error.TableNotFound;
    var info = try catalog.tableInfo(entry, gpa);
    defer info.deinit(gpa);
    if (values.len != info.columns.len) return error.ColumnCountMismatch;
    if (info.root_page == 1) return error.UnsupportedInsert;

    const scanned = try table.scanTable(reader, info.root_page, gpa);
    defer scanned.deinit(gpa);

    var rowid: i64 = 1;
    if (info.integer_primary_key_index) |ipk| {
        switch (values[ipk]) {
            .integer => |explicit| {
                if (explicit <= 0) return error.UnsupportedRowid;
                rowid = explicit;
                for (scanned.rows) |row| {
                    if (row.rowid == rowid) return error.DuplicateRowid;
                }
            },
            .null => {
                for (scanned.rows) |row| rowid = @max(rowid, row.rowid + 1);
            },
            else => return error.UnsupportedRowid,
        }
    } else {
        for (scanned.rows) |row| rowid = @max(rowid, row.rowid + 1);
    }
    return rowid;
}

/// Apply an INSERT to the data file using an explicit rowid. In `idempotent`
/// mode (used by recovery), a rowid that is already present returns
/// `error.AlreadyApplied` instead of `error.DuplicateRowid` so the caller
/// can swallow it.
fn applyInsertCore(
    gpa: Allocator,
    image: *std.ArrayList(u8),
    table_name: []const u8,
    values: []const InsertValue,
    explicit_rowid: i64,
    mode: ApplyMode,
) WriteError!i64 {
    const reader = try page.PageReader.init(image.items);
    if (reader.db_header.isWal()) return error.WalModeUnsupported;
    const db_schema = try schema.readSchema(reader, gpa);
    defer db_schema.deinit(gpa);
    const entry = db_schema.findTable(table_name) orelse return error.TableNotFound;
    var info = try catalog.tableInfo(entry, gpa);
    defer info.deinit(gpa);
    if (values.len != info.columns.len) return error.ColumnCountMismatch;
    if (info.root_page == 1) return error.UnsupportedInsert;

    const root_ref = try reader.page(info.root_page);
    const root_header = try btree.PageHeader.parse(root_ref);
    switch (root_header.page_type) {
        .table_leaf, .table_interior => {},
        else => return error.UnsupportedInsert,
    }

    const scanned = try table.scanTable(reader, info.root_page, gpa);
    defer scanned.deinit(gpa);

    for (scanned.rows) |row| {
        if (row.rowid == explicit_rowid) {
            return switch (mode) {
                .idempotent => error.AlreadyApplied,
                .fresh => error.DuplicateRowid,
            };
        }
    }

    var rows = try rowsFromScanned(info, scanned, gpa);
    defer deinitMutableRows(rows, gpa);
    try rows.append(gpa, .{ .rowid = explicit_rowid, .values = try dupeInsertValues(values, gpa) });
    sortMutableRows(rows.items);

    try rebuildTableAndIndexes(gpa, image, reader.db_header, reader, db_schema, info, rows.items);
    return explicit_rowid;
}

pub fn updateSimple(gpa: Allocator, io: Io, path: []const u8, stmt: @import("ast.zig").UpdateStatement) WriteError!usize {
    var conn = try Connection.open(gpa, io, path);
    defer conn.close();
    return conn.update(stmt);
}

fn applyUpdateCore(gpa: Allocator, image: *std.ArrayList(u8), stmt: @import("ast.zig").UpdateStatement) WriteError!usize {
    const reader = try page.PageReader.init(image.items);
    if (reader.db_header.isWal()) return error.WalModeUnsupported;
    const db_schema = try schema.readSchema(reader, gpa);
    defer db_schema.deinit(gpa);
    const entry = db_schema.findTable(stmt.table_name) orelse return error.TableNotFound;
    var info = try catalog.tableInfo(entry, gpa);
    defer info.deinit(gpa);
    if (info.root_page == 1) return error.UnsupportedUpdate;
    if (std.ascii.eqlIgnoreCase(stmt.assignment.column_name, "rowid")) return error.RowidUpdateUnsupported;
    const assignment_idx = columnIndex(info, stmt.assignment.column_name) orelse return error.ColumnNotFound;
    if (info.integer_primary_key_index != null and info.integer_primary_key_index.? == assignment_idx) return error.RowidUpdateUnsupported;

    const root_ref = try reader.page(info.root_page);
    const root_header = try btree.PageHeader.parse(root_ref);
    switch (root_header.page_type) {
        .table_leaf, .table_interior => {},
        else => return error.UnsupportedUpdate,
    }

    const scanned = try table.scanTable(reader, info.root_page, gpa);
    defer scanned.deinit(gpa);
    const rows = try rowsFromScanned(info, scanned, gpa);
    defer deinitMutableRows(rows, gpa);

    var changed: usize = 0;
    for (rows.items) |*row| {
        if (try rowMatchesWhere(info, row.*, stmt.where_clause)) {
            row.values[assignment_idx] = stmt.assignment.value.toInsertValue();
            changed += 1;
        }
    }
    if (changed == 0) return 0;

    try rebuildTableAndIndexes(gpa, image, reader.db_header, reader, db_schema, info, rows.items);
    return changed;
}

pub fn deleteSimple(gpa: Allocator, io: Io, path: []const u8, stmt: @import("ast.zig").DeleteStatement) WriteError!usize {
    var conn = try Connection.open(gpa, io, path);
    defer conn.close();
    return conn.delete(stmt);
}

fn applyDeleteCore(gpa: Allocator, image: *std.ArrayList(u8), stmt: @import("ast.zig").DeleteStatement) WriteError!usize {
    const reader = try page.PageReader.init(image.items);
    if (reader.db_header.isWal()) return error.WalModeUnsupported;
    const db_schema = try schema.readSchema(reader, gpa);
    defer db_schema.deinit(gpa);
    const entry = db_schema.findTable(stmt.table_name) orelse return error.TableNotFound;
    var info = try catalog.tableInfo(entry, gpa);
    defer info.deinit(gpa);
    if (info.root_page == 1) return error.UnsupportedDelete;

    const root_ref = try reader.page(info.root_page);
    const root_header = try btree.PageHeader.parse(root_ref);
    switch (root_header.page_type) {
        .table_leaf, .table_interior => {},
        else => return error.UnsupportedDelete,
    }

    const scanned = try table.scanTable(reader, info.root_page, gpa);
    defer scanned.deinit(gpa);
    var old_rows = try rowsFromScanned(info, scanned, gpa);
    defer deinitMutableRows(old_rows, gpa);

    var kept: std.ArrayList(MutableRow) = .empty;
    errdefer deinitMutableRows(kept, gpa);
    var changed: usize = 0;
    for (old_rows.items) |*row| {
        if (try rowMatchesWhere(info, row.*, stmt.where_clause)) {
            deinitMutableRow(row.*, gpa);
            row.values = &[_]InsertValue{};
            changed += 1;
        } else {
            try kept.append(gpa, row.*);
            row.values = &[_]InsertValue{};
        }
    }
    old_rows.clearRetainingCapacity();
    if (changed == 0) {
        deinitMutableRows(kept, gpa);
        return 0;
    }
    defer deinitMutableRows(kept, gpa);

    try rebuildTableAndIndexes(gpa, image, reader.db_header, reader, db_schema, info, kept.items);
    return changed;
}

fn encodeRecord(info: catalog.TableInfo, rowid: i64, values: []const InsertValue, allocator: std.mem.Allocator) WriteError![]u8 {
    var record_values = try allocator.alloc(InsertValue, values.len);
    defer allocator.free(record_values);
    _ = rowid;
    for (values, 0..) |value, i| {
        record_values[i] = if (info.integer_primary_key_index != null and info.integer_primary_key_index.? == i) .null else value;
    }
    return encodeRecordValues(record_values, allocator);
}

fn encodeRecordValues(values: []const InsertValue, allocator: std.mem.Allocator) WriteError![]u8 {
    var serials = std.ArrayList(u64).empty;
    defer serials.deinit(allocator);
    var body = std.ArrayList(u8).empty;
    defer body.deinit(allocator);

    for (values) |value| {
        switch (value) {
            .null => try serials.append(allocator, 0),
            .integer => |v| {
                if (v == 0) {
                    try serials.append(allocator, 8);
                } else if (v == 1) {
                    try serials.append(allocator, 9);
                } else if (v >= std.math.minInt(i8) and v <= std.math.maxInt(i8)) {
                    try serials.append(allocator, 1);
                    try body.append(allocator, @bitCast(@as(i8, @intCast(v))));
                } else if (v >= std.math.minInt(i16) and v <= std.math.maxInt(i16)) {
                    try serials.append(allocator, 2);
                    var buf: [2]u8 = undefined;
                    std.mem.writeInt(i16, &buf, @intCast(v), .big);
                    try body.appendSlice(allocator, &buf);
                } else if (v >= std.math.minInt(i32) and v <= std.math.maxInt(i32)) {
                    try serials.append(allocator, 4);
                    var buf: [4]u8 = undefined;
                    std.mem.writeInt(i32, &buf, @intCast(v), .big);
                    try body.appendSlice(allocator, &buf);
                } else {
                    try serials.append(allocator, 6);
                    var buf: [8]u8 = undefined;
                    std.mem.writeInt(i64, &buf, v, .big);
                    try body.appendSlice(allocator, &buf);
                }
            },
            .text => |text| {
                try serials.append(allocator, 13 + text.len * 2);
                try body.appendSlice(allocator, text);
            },
        }
    }

    const header_len = try encodedHeaderLen(serials.items);
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try appendVarint(&out, allocator, header_len);
    for (serials.items) |serial| try appendVarint(&out, allocator, serial);
    try out.appendSlice(allocator, body.items);
    return out.toOwnedSlice(allocator);
}

fn encodedHeaderLen(serials: []const u64) WriteError!u64 {
    var header_len: u64 = 1;
    while (true) {
        var len: u64 = varintLen(header_len);
        for (serials) |serial| len += varintLen(serial);
        if (len == header_len) return len;
        header_len = len;
    }
}

fn tableInsertPosition(rows: []const table.Row, rowid: i64) usize {
    var pos: usize = 0;
    while (pos < rows.len and rows[pos].rowid < rowid) : (pos += 1) {}
    return pos;
}

fn maintainIndexes(
    mutable: []u8,
    db_header: header.Header,
    reader: page.PageReader,
    db_schema: schema.Schema,
    info: catalog.TableInfo,
    rowid: i64,
    values: []const InsertValue,
    allocator: std.mem.Allocator,
) WriteError!void {
    for (db_schema.entries) |entry| {
        if (!entry.isIndex() or entry.root_page <= 0) continue;
        if (!std.ascii.eqlIgnoreCase(entry.table_name, info.name)) continue;
        if (entry.sql.len == 0) return error.UnsupportedIndex;
        if (isUniqueIndex(entry.sql)) return error.UniqueIndexInsertUnsupported;
        const index_column = parseFirstIndexColumn(entry.sql) orelse return error.UnsupportedIndex;
        const column_idx = columnIndex(info, index_column) orelse return error.UnsupportedIndex;
        const index_value = indexInsertValue(info, rowid, values, column_idx);
        const index_values = [_]InsertValue{ index_value, .{ .integer = rowid } };
        const payload = try encodeRecordValues(&index_values, allocator);
        defer allocator.free(payload);

        var cell = std.ArrayList(u8).empty;
        defer cell.deinit(allocator);
        try appendVarint(&cell, allocator, @intCast(payload.len));
        try cell.appendSlice(allocator, payload);

        const index_root: u32 = @intCast(entry.root_page);
        const root_ref = try reader.page(index_root);
        const root_header = try btree.PageHeader.parse(root_ref);
        if (root_header.page_type != .index_leaf) return error.UnsupportedIndex;

        const scanned = try @import("index.zig").scanIndex(reader, index_root, allocator);
        defer scanned.deinit(allocator);
        const insert_pos = indexInsertPosition(scanned.entries, index_values[0], rowid);
        try insertCellIntoLeaf(mutable, db_header, index_root, cell.items, insert_pos);
    }
}

fn indexInsertValue(info: catalog.TableInfo, rowid: i64, values: []const InsertValue, column_idx: usize) InsertValue {
    if (info.integer_primary_key_index) |ipk| {
        if (column_idx == ipk) return .{ .integer = rowid };
    }
    return values[column_idx];
}

fn columnIndex(info: catalog.TableInfo, column_name: []const u8) ?usize {
    for (info.columns, 0..) |column, i| {
        if (std.ascii.eqlIgnoreCase(column.name, column_name)) return i;
    }
    return null;
}

fn indexInsertPosition(entries: []const @import("index.zig").IndexEntry, key: InsertValue, rowid: i64) usize {
    var pos: usize = 0;
    while (pos < entries.len) : (pos += 1) {
        if (compareIndexKey(key, rowid, entries[pos]) < 0) break;
    }
    return pos;
}

fn compareIndexKey(key: InsertValue, rowid: i64, entry: @import("index.zig").IndexEntry) i8 {
    const entry_key: record.Value = if (entry.values.len > 0) entry.values[0] else .null;
    const c = compareInsertValueToRecord(key, entry_key);
    if (c != 0) return c;
    const entry_rowid = entry.rowid() orelse 0;
    if (rowid < entry_rowid) return -1;
    if (rowid > entry_rowid) return 1;
    return 0;
}

fn compareInsertValueToRecord(left: InsertValue, right: record.Value) i8 {
    const left_rank = insertValueRank(left);
    const right_rank = recordValueRank(right);
    if (left_rank < right_rank) return -1;
    if (left_rank > right_rank) return 1;
    return switch (left) {
        .null => 0,
        .integer => |l| switch (right) {
            .integer => |r| if (l < r) -1 else if (l > r) 1 else 0,
            else => 0,
        },
        .text => |l| switch (right) {
            .text => |r| orderToI8(std.mem.order(u8, l, r)),
            else => 0,
        },
    };
}

fn insertValueRank(value: InsertValue) u8 {
    return switch (value) {
        .null => 0,
        .integer => 1,
        .text => 3,
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

fn orderToI8(order: std.math.Order) i8 {
    return switch (order) {
        .lt => -1,
        .eq => 0,
        .gt => 1,
    };
}

fn isUniqueIndex(sql: []const u8) bool {
    const trimmed = std.mem.trim(u8, sql, " \t\r\n");
    if (!startsWithKeyword(trimmed, "CREATE")) return false;
    var pos: usize = 6;
    while (pos < trimmed.len and std.ascii.isWhitespace(trimmed[pos])) pos += 1;
    return startsWithKeyword(trimmed[pos..], "UNIQUE");
}

fn parseFirstIndexColumn(sql: []const u8) ?[]const u8 {
    const open = std.mem.indexOfScalar(u8, sql, '(') orelse return null;
    var pos = open + 1;
    while (pos < sql.len and std.ascii.isWhitespace(sql[pos])) pos += 1;
    if (pos >= sql.len) return null;
    if (sql[pos] == '"' or sql[pos] == '`' or sql[pos] == '[') {
        const close: u8 = if (sql[pos] == '[') ']' else sql[pos];
        pos += 1;
        const start = pos;
        while (pos < sql.len and sql[pos] != close) pos += 1;
        if (pos >= sql.len) return null;
        return sql[start..pos];
    }
    const start = pos;
    while (pos < sql.len and (std.ascii.isAlphanumeric(sql[pos]) or sql[pos] == '_')) pos += 1;
    if (pos == start) return null;
    return sql[start..pos];
}

fn startsWithKeyword(text: []const u8, keyword: []const u8) bool {
    if (text.len < keyword.len) return false;
    if (text.len > keyword.len and (std.ascii.isAlphanumeric(text[keyword.len]) or text[keyword.len] == '_')) return false;
    for (keyword, 0..) |c, i| {
        if (std.ascii.toUpper(text[i]) != c) return false;
    }
    return true;
}

fn insertCellIntoLeaf(bytes: []u8, db_header: header.Header, root_page: u32, cell: []const u8, pointer_index: usize) WriteError!void {
    const page_size: usize = db_header.page_size;
    const page_start = (@as(usize, root_page) - 1) * page_size;
    const hdr_off: usize = if (root_page == 1) header.HEADER_SIZE else 0;
    const base = page_start + hdr_off;
    if (base + 8 > bytes.len) return error.PageOutOfBounds;
    const usable_end = page_start + page_size - db_header.reserved_space;
    if (usable_end > bytes.len or usable_end < base + 8) return error.PageOutOfBounds;
    if (bytes[base] != 0x0d and bytes[base] != 0x0a) return error.UnsupportedInsert;

    const cell_count = readU16(bytes[base + 3 .. base + 5]);
    if (pointer_index > cell_count) return error.InvalidCellIndex;
    const ptr_start = base + 8;
    const ptr_end = ptr_start + (@as(usize, cell_count) + 1) * 2;
    var content_start = readU16(bytes[base + 5 .. base + 7]);
    if (content_start == 0) content_start = @intCast(page_size);
    if (content_start < cell.len) return error.PageFull;
    const new_cell_off: u16 = @intCast(content_start - cell.len);
    const absolute_cell_off = page_start + new_cell_off;
    if (absolute_cell_off + cell.len > usable_end) return error.PageOutOfBounds;
    if (ptr_end > page_start + new_cell_off) return error.PageFull;

    @memcpy(bytes[absolute_cell_off..][0..cell.len], cell);
    if (pointer_index < cell_count) {
        std.mem.copyBackwards(u8,
            bytes[ptr_start + (pointer_index + 1) * 2 .. ptr_start + (@as(usize, cell_count) + 1) * 2],
            bytes[ptr_start + pointer_index * 2 .. ptr_start + @as(usize, cell_count) * 2],
        );
    }
    writeU16(bytes[base + 3 .. base + 5], cell_count + 1);
    writeU16(bytes[base + 5 .. base + 7], new_cell_off);
    writeU16(bytes[ptr_start + pointer_index * 2 ..][0..2], new_cell_off);
}

fn appendVarint(list: *std.ArrayList(u8), allocator: std.mem.Allocator, value: u64) !void {
    var buf: [9]u8 = undefined;
    const n = encodeVarint(&buf, value);
    try list.appendSlice(allocator, buf[0..n]);
}

fn encodeVarint(out: *[9]u8, value: u64) usize {
    if (value <= 0x7f) {
        out[0] = @intCast(value);
        return 1;
    }
    var tmp: [9]u8 = undefined;
    var v = value;
    var n: usize = 0;
    while (v > 0 and n < 8) : (n += 1) {
        tmp[8 - n] = @intCast(v & 0x7f);
        v >>= 7;
    }
    var i: usize = 0;
    while (i < n) : (i += 1) out[i] = tmp[9 - n + i] | 0x80;
    out[n - 1] &= 0x7f;
    return n;
}

fn varintLen(value: u64) u64 {
    if (value <= 0x7f) return 1;
    var v = value;
    var n: u64 = 0;
    while (v > 0 and n < 9) : (n += 1) v >>= 7;
    return n;
}

fn readU16(bytes: []const u8) u16 {
    return std.mem.readInt(u16, bytes[0..2], .big);
}

fn writeU16(bytes: []u8, value: u16) void {
    std.mem.writeInt(u16, bytes[0..2], value, .big);
}

fn writeU32(bytes: []u8, value: u32) void {
    std.mem.writeInt(u32, bytes[0..4], value, .big);
}

pub const MutableRow = struct {
    rowid: i64,
    values: []InsertValue,
};

fn rowsFromScanned(info: catalog.TableInfo, scanned: table.Table, allocator: std.mem.Allocator) WriteError!std.ArrayList(MutableRow) {
    var list: std.ArrayList(MutableRow) = .empty;
    errdefer deinitMutableRows(list, allocator);
    try list.ensureTotalCapacity(allocator, scanned.rows.len);

    for (scanned.rows) |row| {
        const values = try allocator.alloc(InsertValue, info.columns.len);
        errdefer allocator.free(values);
        for (info.columns, 0..) |_, i| {
            const src: record.Value = if (i < row.values.len) row.values[i] else .null;
            if (info.integer_primary_key_index != null and info.integer_primary_key_index.? == i) {
                values[i] = .{ .integer = row.rowid };
                continue;
            }
            values[i] = switch (src) {
                .null => .null,
                .integer => |v| .{ .integer = v },
                .text => |t| .{ .text = t },
                .real, .blob => return error.UnsupportedColumnValue,
            };
        }
        try list.append(allocator, .{ .rowid = row.rowid, .values = values });
    }
    return list;
}

fn deinitMutableRow(row: MutableRow, allocator: std.mem.Allocator) void {
    if (row.values.len != 0) allocator.free(row.values);
}

fn deinitMutableRows(rows: std.ArrayList(MutableRow), allocator: std.mem.Allocator) void {
    var mut = rows;
    for (mut.items) |row| deinitMutableRow(row, allocator);
    mut.deinit(allocator);
}

fn dupeInsertValues(values: []const InsertValue, allocator: std.mem.Allocator) WriteError![]InsertValue {
    const out = try allocator.alloc(InsertValue, values.len);
    @memcpy(out, values);
    return out;
}

fn sortMutableRows(rows: []MutableRow) void {
    std.mem.sort(MutableRow, rows, {}, struct {
        fn lt(_: void, a: MutableRow, b: MutableRow) bool {
            return a.rowid < b.rowid;
        }
    }.lt);
}

fn rowMatchesWhere(info: catalog.TableInfo, row: MutableRow, where: @import("ast.zig").WhereClause) WriteError!bool {
    if (std.ascii.eqlIgnoreCase(where.column_name, "rowid")) {
        return switch (where.value) {
            .integer => |v| row.rowid == v,
            else => false,
        };
    }
    const idx = columnIndex(info, where.column_name) orelse return error.ColumnNotFound;
    var actual = row.values[idx];
    if (info.integer_primary_key_index != null and info.integer_primary_key_index.? == idx and actual == .null) {
        actual = .{ .integer = row.rowid };
    }
    return insertValuesEqual(actual, where.value.toInsertValue());
}

fn insertValuesEqual(a: InsertValue, b: InsertValue) bool {
    return switch (a) {
        .null => b == .null,
        .integer => |av| switch (b) {
            .integer => |bv| av == bv,
            else => false,
        },
        .text => |at| switch (b) {
            .text => |bt| std.mem.eql(u8, at, bt),
            else => false,
        },
    };
}

const IndexPlan = struct {
    schema_entry: schema.SchemaEntry,
    /// Owned cells (each one allocated with `gpa`).
    cells: [][]u8,
    /// Each leaf is a slice into `cells`; the outer slice is `gpa`-owned.
    layout_leaves: [][]const []const u8,
    /// Each divider cell points back into `cells`.
    divider_cells: [][]const u8,
    existing_leaves: []u32,
    /// One page number per leaf in `layout_leaves`, allocated with `gpa`.
    leaf_pages: []u32,

    fn deinit(self: IndexPlan, gpa: Allocator) void {
        for (self.cells) |c| gpa.free(c);
        gpa.free(self.cells);
        gpa.free(self.layout_leaves);
        gpa.free(self.divider_cells);
        gpa.free(self.existing_leaves);
        gpa.free(self.leaf_pages);
    }
};

/// Rebuild the data file image for `info`'s table and every index that
/// references it, mutating `image` in place.
///
/// Both tables and indexes get b-tree splits: rows pack into one leaf when
/// they fit, otherwise across N leaves with an interior root. Growing the
/// tree grows the image: new leaf pages are appended at the end and
/// `database_page_count` in the header is bumped. Old leaves no longer
/// referenced leak for now — a real freelist can recycle them later. The
/// flow is:
///
///   1. Build leaf cells for the table and for each index.
///   2. Plan leaf packing for everything.
///   3. Walk every existing tree to discover reusable non-root leaves.
///   4. Assign page numbers; this is also where we discover how many
///      brand-new pages we need.
///   5. Resize `image` for the new file extent, zero the new tail, then
///      write each leaf and (if multi-leaf) each interior root directly
///      into `image.items`. No file I/O — the caller flushes.
///
/// Important: `reader`, `db_schema`, and any slice fields that alias
/// `image.items` BEFORE the step-5 resize must not be used afterwards.
/// `image.resize` can relocate the backing buffer; only scalar fields
/// (page numbers, counts) and gpa-owned cell buffers are safe to use
/// after the resize.
fn rebuildTableAndIndexes(
    gpa: Allocator,
    image: *std.ArrayList(u8),
    db_header: header.Header,
    reader: page.PageReader,
    db_schema: schema.Schema,
    info: catalog.TableInfo,
    rows: []MutableRow,
) WriteError!void {
    sortMutableRows(rows);
    const usable_size = @as(usize, db_header.page_size) - db_header.reserved_space;

    // SQLite's `database_page_count` field (header offset 28) is allowed to
    // be stale or zero — older writers leave it untouched and readers fall
    // back to the file size. Trusting it blindly would let us allocate
    // "fresh" page numbers that actually overlap existing pages (e.g. the
    // index root). Use the larger of the header field and the file size.
    const file_pages: u32 = @intCast(image.items.len / db_header.page_size);
    const effective_page_count: u32 = @max(db_header.database_page_count, file_pages);

    // ── Step 1: build table leaf cells ──
    var table_cells: std.ArrayList([]u8) = .empty;
    defer {
        for (table_cells.items) |cell| gpa.free(cell);
        table_cells.deinit(gpa);
    }
    try table_cells.ensureTotalCapacity(gpa, rows.len);
    for (rows) |row| {
        const payload = try encodeRecord(info, row.rowid, row.values, gpa);
        defer gpa.free(payload);
        const info_pl = btree.tableLeafPayloadInfo(payload.len, usable_size);
        if (info_pl.overflow_page != null) return error.PayloadOverflowUnsupported;

        var cell: std.ArrayList(u8) = .empty;
        errdefer cell.deinit(gpa);
        try appendVarint(&cell, gpa, @intCast(payload.len));
        try appendVarint(&cell, gpa, @intCast(row.rowid));
        try cell.appendSlice(gpa, payload);
        try table_cells.append(gpa, try cell.toOwnedSlice(gpa));
    }

    // ── Step 2 & 3: plan + page assignment for the table tree ──
    const table_leaves = try packTableLeaves(table_cells.items, usable_size, gpa);
    defer gpa.free(table_leaves);
    if (table_leaves.len == 0) return error.EmptyLeafPlan;

    const table_existing = try collectNonRootTableLeaves(reader, info.root_page, gpa);
    defer gpa.free(table_existing);

    var next_fresh_page: u32 = effective_page_count + 1;

    const table_leaf_pages = try gpa.alloc(u32, table_leaves.len);
    defer gpa.free(table_leaf_pages);
    if (table_leaves.len == 1) {
        table_leaf_pages[0] = info.root_page;
    } else {
        var reused: usize = 0;
        for (table_leaf_pages) |*slot| {
            if (reused < table_existing.len) {
                slot.* = table_existing[reused];
                reused += 1;
            } else {
                slot.* = next_fresh_page;
                next_fresh_page += 1;
            }
        }
    }

    // ── Steps 1-4 for each index ──
    var index_plans: std.ArrayList(IndexPlan) = .empty;
    defer {
        for (index_plans.items) |plan| plan.deinit(gpa);
        index_plans.deinit(gpa);
    }

    for (db_schema.entries) |entry| {
        if (!entry.isIndex() or entry.root_page <= 0) continue;
        if (!std.ascii.eqlIgnoreCase(entry.table_name, info.name)) continue;
        if (entry.sql.len == 0) return error.UnsupportedIndex;
        const column_name = parseFirstIndexColumn(entry.sql) orelse return error.UnsupportedIndex;
        const col_idx = columnIndex(info, column_name) orelse return error.UnsupportedIndex;
        const index_root: u32 = @intCast(entry.root_page);

        // Verify root is a recognisable index page.
        const root_ref = try reader.page(index_root);
        const idx_root_header = try btree.PageHeader.parse(root_ref);
        switch (idx_root_header.page_type) {
            .index_leaf, .index_interior => {},
            else => return error.UnsupportedIndex,
        }

        // Build sorted (key, rowid) cells in leaf form.
        var pairs = try gpa.alloc(IndexPair, rows.len);
        defer gpa.free(pairs);
        for (rows, 0..) |row, i| {
            const key = indexInsertValue(info, row.rowid, row.values, col_idx);
            pairs[i] = .{ .key = key, .rowid = row.rowid };
        }
        std.mem.sort(IndexPair, pairs, {}, IndexPair.lessThan);

        var idx_cells: std.ArrayList([]u8) = .empty;
        errdefer {
            for (idx_cells.items) |c| gpa.free(c);
            idx_cells.deinit(gpa);
        }
        try idx_cells.ensureTotalCapacity(gpa, pairs.len);
        for (pairs) |pair| {
            const entry_values = [_]InsertValue{ pair.key, .{ .integer = pair.rowid } };
            const payload = try encodeRecordValues(&entry_values, gpa);
            defer gpa.free(payload);
            const info_pl = btree.indexPayloadInfo(payload.len, usable_size);
            if (info_pl.overflow_page != null) return error.PayloadOverflowUnsupported;

            var cell: std.ArrayList(u8) = .empty;
            errdefer cell.deinit(gpa);
            try appendVarint(&cell, gpa, @intCast(payload.len));
            try cell.appendSlice(gpa, payload);
            try idx_cells.append(gpa, try cell.toOwnedSlice(gpa));
        }

        const cells_slice = try idx_cells.toOwnedSlice(gpa);
        errdefer {
            for (cells_slice) |c| gpa.free(c);
            gpa.free(cells_slice);
        }

        const layout = try packIndexLayout(cells_slice, usable_size, gpa);
        errdefer {
            gpa.free(layout.leaves);
            gpa.free(layout.dividers);
        }
        // Multi-leaf indexes are NYI: see commit history. The split logic
        // exists but interacts subtly with the table allocator and produces
        // pages that fail `PRAGMA integrity_check` once table and index
        // grow on the same iteration. Reject early until we revisit it.
        if (layout.leaves.len > 1) return error.PayloadOverflowUnsupported;

        const existing = try collectNonRootIndexLeaves(reader, index_root, gpa);
        errdefer gpa.free(existing);

        const leaf_pages_for_index = try gpa.alloc(u32, layout.leaves.len);
        errdefer gpa.free(leaf_pages_for_index);
        if (layout.leaves.len == 1) {
            leaf_pages_for_index[0] = index_root;
        } else {
            var reused: usize = 0;
            for (leaf_pages_for_index) |*slot| {
                if (reused < existing.len) {
                    slot.* = existing[reused];
                    reused += 1;
                } else {
                    slot.* = next_fresh_page;
                    next_fresh_page += 1;
                }
            }
        }

        try index_plans.append(gpa, .{
            .schema_entry = entry,
            .cells = cells_slice,
            .layout_leaves = layout.leaves,
            .divider_cells = layout.dividers,
            .existing_leaves = existing,
            .leaf_pages = leaf_pages_for_index,
        });
    }

    // ── Distinctness check: every leaf page assignment across the table
    //    and indexes must be unique. If we ever produced a duplicate the
    //    b-tree would alias two children to the same physical page and one
    //    rewrite would silently clobber the other. This is the kind of bug
    //    that corrupts data without any obvious symptom up until SQLite's
    //    `PRAGMA integrity_check` cries about it, so the assertion lives
    //    in release too.
    {
        var seen: std.AutoHashMap(u32, void) = .init(gpa);
        defer seen.deinit();
        for (table_leaf_pages) |p| {
            const gop = try seen.getOrPut(p);
            if (gop.found_existing) return error.PageAllocationConflict;
        }
        for (index_plans.items) |plan| {
            for (plan.leaf_pages) |p| {
                const gop = try seen.getOrPut(p);
                if (gop.found_existing) return error.PageAllocationConflict;
            }
        }
    }

    // ── Step 5: resize the image to the new file extent, then write
    //    everything in place. Past this point, DO NOT use `reader`,
    //    `db_schema`, `info`, or any slice that aliased `image.items`
    //    before the resize — `image.resize` is allowed to relocate.
    const final_page_count: u32 = @max(effective_page_count, next_fresh_page - 1);
    const new_file_size: usize = @as(usize, final_page_count) * @as(usize, db_header.page_size);

    const info_root_page = info.root_page; // u32, survives resize.

    const old_len = image.items.len;
    try image.resize(gpa, new_file_size);
    if (new_file_size > old_len) @memset(image.items[old_len..], 0);
    const mutable = image.items;

    // Bump the header page count and file change counter. Writers that
    // bump file_change_counter let SQLite-aware readers notice the image
    // moved. Mirror it into version_valid_for for WAL-aware readers too.
    writeU32(mutable[28..32], final_page_count);
    if (mutable.len >= 28) {
        writeU32(mutable[24..28], db_header.file_change_counter +% 1);
        if (mutable.len >= 96) writeU32(mutable[92..96], db_header.file_change_counter +% 1);
    }

    // Table leaves + interior root.
    for (table_leaves, 0..) |leaf_cells, i| {
        try rewriteLeafPage(mutable, db_header, table_leaf_pages[i], .table_leaf, leaf_cells);
    }
    if (table_leaves.len >= 2) {
        try writeInteriorTableRoot(mutable, db_header, info_root_page, table_leaf_pages, table_leaves, gpa);
    }

    // Index leaves + (if multi-leaf) interior roots. `plan.schema_entry`
    // may alias the old `image.items`, so only read its scalar fields.
    for (index_plans.items) |plan| {
        for (plan.layout_leaves, 0..) |leaf_cells, i| {
            try rewriteLeafPage(mutable, db_header, plan.leaf_pages[i], .index_leaf, leaf_cells);
        }
        if (plan.layout_leaves.len >= 2) {
            const idx_root: u32 = @intCast(plan.schema_entry.root_page);
            try writeInteriorIndexRoot(mutable, db_header, idx_root, plan.leaf_pages, plan.divider_cells, gpa);
        }
    }
}

/// Greedy leaf packing: fill each leaf until adding the next cell would
/// overflow usable space. Returns a slice of cell-slices (one per leaf);
/// caller owns the outer slice but the inner slices alias `cells`.
fn packTableLeaves(
    cells: []const []const u8,
    usable_size: usize,
    gpa: Allocator,
) WriteError![]const []const []const u8 {
    // Leaf header is 8 bytes; per cell overhead is 2 bytes for the pointer.
    if (usable_size < 8) return error.PageTooSmall;
    const cell_area = usable_size - 8;

    var groups: std.ArrayList([]const []const u8) = .empty;
    errdefer groups.deinit(gpa);

    if (cells.len == 0) {
        // Represent "empty table" as one empty leaf so the root page gets
        // rewritten as an empty table_leaf.
        try groups.append(gpa, cells[0..0]);
        return groups.toOwnedSlice(gpa);
    }

    var start: usize = 0;
    while (start < cells.len) {
        var end: usize = start;
        var used: usize = 0;
        while (end < cells.len) {
            const cost = cells[end].len + 2; // cell bytes + pointer slot
            if (used + cost > cell_area) break;
            used += cost;
            end += 1;
        }
        // A single cell that won't fit in an empty leaf → overflow-only
        // payloads, which we don't support yet.
        if (end == start) return error.PayloadOverflowUnsupported;
        try groups.append(gpa, cells[start..end]);
        start = end;
    }
    return groups.toOwnedSlice(gpa);
}

/// Walk the existing table b-tree and return every leaf page number we
/// find, in left-to-right order. The root page itself is *not* included —
/// if the tree is currently a single leaf, we return an empty slice, and
/// the caller will reuse `root_page` directly.
fn collectNonRootTableLeaves(
    reader: page.PageReader,
    root_page: u32,
    gpa: Allocator,
) WriteError![]u32 {
    var out: std.ArrayList(u32) = .empty;
    errdefer out.deinit(gpa);
    try walkTableLeaves(reader, root_page, root_page, &out, gpa);
    return out.toOwnedSlice(gpa);
}

fn walkTableLeaves(
    reader: page.PageReader,
    page_num: u32,
    root_page: u32,
    out: *std.ArrayList(u32),
    gpa: Allocator,
) WriteError!void {
    const ref = try reader.page(page_num);
    const hdr = try btree.PageHeader.parse(ref);
    switch (hdr.page_type) {
        .table_leaf => {
            if (page_num != root_page) try out.append(gpa, page_num);
        },
        .table_interior => {
            var i: usize = 0;
            while (i < hdr.cell_count) : (i += 1) {
                const cell = try hdr.cell(ref, i);
                if (cell.len < 5) return error.InvalidTableCell;
                const left = std.mem.readInt(u32, cell[0..4], .big);
                try walkTableLeaves(reader, left, root_page, out, gpa);
            }
            const right = hdr.right_most_pointer orelse return error.InvalidTableCell;
            try walkTableLeaves(reader, right, root_page, out, gpa);
        },
        else => return error.UnsupportedTableBTree,
    }
}

/// Rewrite `root_page` as a `table_interior` node with one divider per
/// non-rightmost leaf. Each divider cell is `[u32 left_child BE][varint
/// largest_rowid_in_left]`; the rightmost leaf is pointed to by the
/// interior's right-most-pointer.
fn writeInteriorTableRoot(
    mutable: []u8,
    db_header: header.Header,
    root_page: u32,
    leaf_pages: []const u32,
    leaves: []const []const []const u8,
    gpa: Allocator,
) WriteError!void {
    std.debug.assert(leaves.len == leaf_pages.len);
    std.debug.assert(leaves.len >= 2);

    // Build divider cells first (for all but the rightmost leaf).
    var divider_cells: std.ArrayList([]u8) = .empty;
    defer {
        for (divider_cells.items) |c| gpa.free(c);
        divider_cells.deinit(gpa);
    }
    try divider_cells.ensureTotalCapacity(gpa, leaves.len - 1);

    var i: usize = 0;
    while (i + 1 < leaves.len) : (i += 1) {
        const last_cell = leaves[i][leaves[i].len - 1];
        // Cell layout: [varint payload_size][varint rowid][payload...]
        const payload_size_v = @import("varint.zig").parse(last_cell) catch return error.InvalidTableCell;
        const rowid_v = @import("varint.zig").parse(last_cell[payload_size_v.len..]) catch return error.InvalidTableCell;

        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(gpa);
        var page_bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &page_bytes, leaf_pages[i], .big);
        try buf.appendSlice(gpa, &page_bytes);
        try appendVarint(&buf, gpa, rowid_v.value);
        try divider_cells.append(gpa, try buf.toOwnedSlice(gpa));
    }

    const page_size: usize = db_header.page_size;
    const page_start = (@as(usize, root_page) - 1) * page_size;
    if (page_start + page_size > mutable.len) return error.PageOutOfBounds;
    const hdr_off: usize = if (root_page == 1) header.HEADER_SIZE else 0;
    const base = page_start + hdr_off;
    const usable_end = page_start + page_size - db_header.reserved_space;
    if (base + 12 > usable_end) return error.PageOutOfBounds;

    // Verify cells + pointer array fit.
    const ptr_end = base + 12 + divider_cells.items.len * 2;
    var content_cursor = usable_end;
    for (divider_cells.items) |c| {
        if (content_cursor < c.len) return error.InteriorPageFull;
        content_cursor -= c.len;
    }
    if (content_cursor < ptr_end) return error.InteriorPageFull;

    // Zero everything from end of (interior-sized) header to end of page.
    @memset(mutable[base + 12 .. usable_end], 0);

    // Lay out cells back-to-front and record their offsets.
    var cursor = usable_end;
    for (divider_cells.items, 0..) |c, j| {
        cursor -= c.len;
        @memcpy(mutable[cursor..][0..c.len], c);
        const rel: u16 = @intCast(cursor - page_start);
        writeU16(mutable[base + 12 + j * 2 ..][0..2], rel);
    }
    const content_start_rel: u32 = @intCast(cursor - page_start);

    mutable[base] = @intFromEnum(btree.PageType.table_interior);
    writeU16(mutable[base + 1 .. base + 3], 0); // first freeblock
    writeU16(mutable[base + 3 .. base + 5], @intCast(divider_cells.items.len));
    const stored_content_start: u16 = if (content_start_rel == 65536) 0 else @intCast(content_start_rel);
    writeU16(mutable[base + 5 .. base + 7], stored_content_start);
    mutable[base + 7] = 0; // fragmented free bytes
    writeU32(mutable[base + 8 .. base + 12], leaf_pages[leaves.len - 1]);
}

const IndexLayout = struct {
    leaves: [][]const []const u8,
    dividers: [][]const u8,
};

/// Greedy index packing. Indexes are SQLite-style "B-trees, not B+trees":
/// every leaf gets a contiguous range of cells, and between consecutive
/// leaves one entry is *promoted* into an interior divider cell. The
/// promoted entry does NOT also live in either neighboring leaf.
///
/// `cells` contains leaf-form cells (`[varint payload_size][payload]`).
/// The returned `dividers` are aliases into `cells`; the writer prepends
/// the 4-byte left-child page pointer when emitting the interior page.
fn packIndexLayout(
    cells: []const []const u8,
    usable_size: usize,
    gpa: Allocator,
) WriteError!IndexLayout {
    if (usable_size < 12) return error.PageTooSmall;
    const leaf_cell_area = usable_size - 8;

    var leaves: std.ArrayList([]const []const u8) = .empty;
    errdefer leaves.deinit(gpa);
    var dividers: std.ArrayList([]const u8) = .empty;
    errdefer dividers.deinit(gpa);

    if (cells.len == 0) {
        try leaves.append(gpa, cells[0..0]);
        return .{
            .leaves = try leaves.toOwnedSlice(gpa),
            .dividers = try dividers.toOwnedSlice(gpa),
        };
    }

    var i: usize = 0;
    while (i < cells.len) {
        const start = i;
        var used: usize = 0;
        while (i < cells.len) {
            const cost = cells[i].len + 2;
            if (used + cost > leaf_cell_area) break;
            used += cost;
            i += 1;
        }
        if (start == i) return error.PayloadOverflowUnsupported;
        try leaves.append(gpa, cells[start..i]);
        if (i < cells.len) {
            try dividers.append(gpa, cells[i]);
            i += 1;
        }
    }

    // Confirm the dividers all fit in a single interior root. A multi-level
    // tree would need recursive splitting; reject for now with a clear error.
    if (dividers.items.len > 0) {
        const interior_cell_area = usable_size - 12;
        var used: usize = 0;
        for (dividers.items) |d| {
            used += d.len + 4 + 2; // 4-byte child ptr + 2-byte cell ptr
            if (used > interior_cell_area) return error.IndexInteriorOverflow;
        }
    }

    return .{
        .leaves = try leaves.toOwnedSlice(gpa),
        .dividers = try dividers.toOwnedSlice(gpa),
    };
}

fn collectNonRootIndexLeaves(
    reader: page.PageReader,
    root_page: u32,
    gpa: Allocator,
) WriteError![]u32 {
    var out: std.ArrayList(u32) = .empty;
    errdefer out.deinit(gpa);
    try walkIndexLeaves(reader, root_page, root_page, &out, gpa);
    return out.toOwnedSlice(gpa);
}

fn walkIndexLeaves(
    reader: page.PageReader,
    page_num: u32,
    root_page: u32,
    out: *std.ArrayList(u32),
    gpa: Allocator,
) WriteError!void {
    const ref = try reader.page(page_num);
    const hdr = try btree.PageHeader.parse(ref);
    switch (hdr.page_type) {
        .index_leaf => {
            if (page_num != root_page) try out.append(gpa, page_num);
        },
        .index_interior => {
            var i: usize = 0;
            while (i < hdr.cell_count) : (i += 1) {
                const cell = try hdr.cell(ref, i);
                if (cell.len < 4) return error.UnsupportedIndex;
                const left = std.mem.readInt(u32, cell[0..4], .big);
                try walkIndexLeaves(reader, left, root_page, out, gpa);
            }
            const right = hdr.right_most_pointer orelse return error.UnsupportedIndex;
            try walkIndexLeaves(reader, right, root_page, out, gpa);
        },
        else => return error.UnsupportedIndex,
    }
}

/// Stamp the page at `root_page` as an `index_interior` whose cells are
/// `[u32 left_child BE]` followed by the divider cell bytes. The rightmost
/// leaf is reachable via the page's right-most pointer.
fn writeInteriorIndexRoot(
    mutable: []u8,
    db_header: header.Header,
    root_page: u32,
    leaf_pages: []const u32,
    divider_cells: []const []const u8,
    gpa: Allocator,
) WriteError!void {
    std.debug.assert(leaf_pages.len == divider_cells.len + 1);
    std.debug.assert(divider_cells.len >= 1);
    var interior_cells: std.ArrayList([]u8) = .empty;
    defer {
        for (interior_cells.items) |c| gpa.free(c);
        interior_cells.deinit(gpa);
    }
    try interior_cells.ensureTotalCapacity(gpa, divider_cells.len);
    for (divider_cells, 0..) |div, i| {
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(gpa);
        var page_bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &page_bytes, leaf_pages[i], .big);
        try buf.appendSlice(gpa, &page_bytes);
        try buf.appendSlice(gpa, div);
        try interior_cells.append(gpa, try buf.toOwnedSlice(gpa));
    }

    const page_size: usize = db_header.page_size;
    const page_start = (@as(usize, root_page) - 1) * page_size;
    if (page_start + page_size > mutable.len) return error.PageOutOfBounds;
    const hdr_off: usize = if (root_page == 1) header.HEADER_SIZE else 0;
    const base = page_start + hdr_off;
    const usable_end = page_start + page_size - db_header.reserved_space;
    if (base + 12 > usable_end) return error.PageOutOfBounds;

    const ptr_end = base + 12 + interior_cells.items.len * 2;
    var content_cursor = usable_end;
    for (interior_cells.items) |c| {
        if (content_cursor < c.len) return error.IndexInteriorOverflow;
        content_cursor -= c.len;
    }
    if (content_cursor < ptr_end) return error.IndexInteriorOverflow;

    @memset(mutable[base + 12 .. usable_end], 0);

    var cursor = usable_end;
    for (interior_cells.items, 0..) |c, j| {
        cursor -= c.len;
        @memcpy(mutable[cursor..][0..c.len], c);
        const rel: u16 = @intCast(cursor - page_start);
        writeU16(mutable[base + 12 + j * 2 ..][0..2], rel);
    }
    const content_start_rel: u32 = @intCast(cursor - page_start);

    mutable[base] = @intFromEnum(btree.PageType.index_interior);
    writeU16(mutable[base + 1 .. base + 3], 0);
    writeU16(mutable[base + 3 .. base + 5], @intCast(interior_cells.items.len));
    const stored_content_start: u16 = if (content_start_rel == 65536) 0 else @intCast(content_start_rel);
    writeU16(mutable[base + 5 .. base + 7], stored_content_start);
    mutable[base + 7] = 0;
    writeU32(mutable[base + 8 .. base + 12], leaf_pages[leaf_pages.len - 1]);
}

const IndexPair = struct {
    key: InsertValue,
    rowid: i64,

    fn lessThan(_: void, a: IndexPair, b: IndexPair) bool {
        const c = compareInsertValues(a.key, b.key);
        if (c != 0) return c < 0;
        return a.rowid < b.rowid;
    }
};

fn compareInsertValues(a: InsertValue, b: InsertValue) i8 {
    const ar = insertValueRank(a);
    const br = insertValueRank(b);
    if (ar < br) return -1;
    if (ar > br) return 1;
    return switch (a) {
        .null => 0,
        .integer => |av| switch (b) {
            .integer => |bv| if (av < bv) -1 else if (av > bv) 1 else 0,
            else => 0,
        },
        .text => |at| switch (b) {
            .text => |bt| orderToI8(std.mem.order(u8, at, bt)),
            else => 0,
        },
    };
}

fn rewriteLeafPage(
    mutable: []u8,
    db_header: header.Header,
    page_number: u32,
    page_type: btree.PageType,
    cells: []const []const u8,
) WriteError!void {
    const page_size: usize = db_header.page_size;
    const page_start = (@as(usize, page_number) - 1) * page_size;
    if (page_start + page_size > mutable.len) return error.PageOutOfBounds;
    const hdr_off: usize = if (page_number == 1) header.HEADER_SIZE else 0;
    const base = page_start + hdr_off;
    const usable_end = page_start + page_size - db_header.reserved_space;
    if (base + 8 > usable_end) return error.PageOutOfBounds;

    const ptr_end = base + 8 + cells.len * 2;
    var content_cursor = usable_end;
    for (cells) |cell| {
        if (content_cursor < cell.len) return error.PageFull;
        content_cursor -= cell.len;
    }
    const content_start_abs = content_cursor;
    if (content_start_abs < ptr_end) return error.PageFull;

    // Zero the area between the header-bytes-after-ptrs and the end of the page.
    @memset(mutable[base + 8 .. usable_end], 0);

    // Write cells, from first to last; each cell placed back-to-front relative to page end.
    var cursor = usable_end;
    var i: usize = 0;
    while (i < cells.len) : (i += 1) {
        const cell = cells[i];
        cursor -= cell.len;
        @memcpy(mutable[cursor..][0..cell.len], cell);
        const rel: u16 = @intCast(cursor - page_start);
        writeU16(mutable[base + 8 + i * 2 ..][0..2], rel);
    }

    // Leaf header.
    mutable[base] = @intFromEnum(page_type);
    writeU16(mutable[base + 1 .. base + 3], 0); // first freeblock
    writeU16(mutable[base + 3 .. base + 5], @intCast(cells.len));
    const content_start_rel: usize = if (cells.len == 0) page_size else content_start_abs - page_start;
    const stored_content_start: u16 = if (content_start_rel == 65536) 0 else @intCast(content_start_rel);
    writeU16(mutable[base + 5 .. base + 7], stored_content_start);
    mutable[base + 7] = 0; // fragmented free bytes
}

test "encode record for insert" {
    const entry = schema.SchemaEntry{
        .rowid = 1,
        .object_type = "table",
        .name = "users",
        .table_name = "users",
        .root_page = 2,
        .sql = "CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT, age INTEGER)",
    };
    const info = try catalog.tableInfo(entry, std.testing.allocator);
    defer info.deinit(std.testing.allocator);
    const vals = [_]InsertValue{ .{ .integer = 1 }, .{ .text = "alice" }, .{ .integer = 30 } };
    const encoded = try encodeRecord(info, 1, &vals, std.testing.allocator);
    defer std.testing.allocator.free(encoded);
    const parsed = try record.parse(encoded, std.testing.allocator);
    defer parsed.deinit(std.testing.allocator);
    try std.testing.expect(parsed.values[0] == .null);
    try std.testing.expectEqualStrings("alice", parsed.values[1].text);
    try std.testing.expectEqual(@as(i64, 30), parsed.values[2].integer);
}

// ── integration tests (require the `sqlite3` CLI for fixture creation) ────

const testing = std.testing;

fn skipIfNoSqlite() !void {
    const result = std.process.run(testing.allocator, testing.io, .{
        .argv = &.{ "sqlite3", "-version" },
    }) catch return error.SkipZigTest;
    defer testing.allocator.free(result.stdout);
    defer testing.allocator.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) return error.SkipZigTest;
}

fn buildSqliteFixture(db_path: []const u8, schema_sql: []const u8) !void {
    const result = try std.process.run(testing.allocator, testing.io, .{
        .argv = &.{ "sqlite3", db_path, schema_sql },
    });
    defer testing.allocator.free(result.stdout);
    defer testing.allocator.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) return error.SqliteFixtureFailed;
}

fn tmpDbPath(allocator: Allocator, tmp: testing.TmpDir, name: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/{s}", .{ tmp.sub_path, name });
}

test "insertSimple round-trips through WAL into the data file" {
    try skipIfNoSqlite();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const db_path = try tmpDbPath(testing.allocator, tmp, "t.db");
    defer testing.allocator.free(db_path);
    try buildSqliteFixture(db_path, "CREATE TABLE users(id INTEGER PRIMARY KEY, name TEXT, age INTEGER);");

    const vals = [_]InsertValue{ .null, .{ .text = "alice" }, .{ .integer = 30 } };
    const rowid = try insertSimple(testing.allocator, testing.io, db_path, "users", &vals);
    try testing.expectEqual(@as(i64, 1), rowid);

    const bytes = try std.Io.Dir.cwd().readFileAlloc(testing.io, db_path, testing.allocator, .limited(1024 * 1024));
    defer testing.allocator.free(bytes);
    const reader = try page.PageReader.init(bytes);
    const db_schema = try schema.readSchema(reader, testing.allocator);
    defer db_schema.deinit(testing.allocator);
    const entry = db_schema.findTable("users") orelse return error.TestUnexpectedResult;
    var info = try catalog.tableInfo(entry, testing.allocator);
    defer info.deinit(testing.allocator);
    const scanned = try table.scanTable(reader, info.root_page, testing.allocator);
    defer scanned.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), scanned.rows.len);
    try testing.expectEqual(@as(i64, 1), scanned.rows[0].rowid);
    try testing.expectEqualStrings("alice", scanned.rows[0].values[1].text);

    // WAL file should have been compacted to zero bytes after apply+checkpoint.
    const wal_path = try walPathFor(testing.allocator, db_path);
    defer testing.allocator.free(wal_path);
    const wal_file = try std.Io.Dir.cwd().openFile(testing.io, wal_path, .{ .mode = .read_only });
    defer wal_file.close(testing.io);
    const wstat = try wal_file.stat(testing.io);
    try testing.expectEqual(@as(u64, 0), wstat.size);
}

test "Connection.open replays committed WAL entries the data file never got" {
    try skipIfNoSqlite();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const db_path = try tmpDbPath(testing.allocator, tmp, "t.db");
    defer testing.allocator.free(db_path);
    try buildSqliteFixture(db_path, "CREATE TABLE users(id INTEGER PRIMARY KEY, name TEXT, age INTEGER);");

    // Snapshot the pristine, pre-mutation data file.
    const pre_bytes = try std.Io.Dir.cwd().readFileAlloc(testing.io, db_path, testing.allocator, .limited(1024 * 1024));
    defer testing.allocator.free(pre_bytes);

    // Hand-craft a WAL that contains a committed row_insert payload beside an
    // otherwise-untouched data file. This simulates a crash between
    // `wal.commit` and the in-memory apply step inside `Connection.insert`.
    const wal_path = try walPathFor(testing.allocator, db_path);
    defer testing.allocator.free(wal_path);
    {
        var wal = try wal_mod.Wal.open(std.Io.Dir.cwd(), testing.io, testing.allocator, wal_path);
        defer wal.close(testing.io);
        const vals = [_]InsertValue{ .null, .{ .text = "bob" }, .{ .integer = 42 } };
        const payload = try wal_codec.encodeInsert(testing.allocator, "users", 1, &vals);
        defer testing.allocator.free(payload);
        const txn_id = nextTxnId();
        _ = try wal.write(testing.io, txn_id, .row_insert, wal_mod.DB_TAG_SQLITE, 0, payload);
        try wal.commit(testing.io, txn_id, wal_mod.DB_TAG_SQLITE);
    }

    // Sanity: the data file must be byte-identical to its pre-commit state.
    const mid_bytes = try std.Io.Dir.cwd().readFileAlloc(testing.io, db_path, testing.allocator, .limited(1024 * 1024));
    defer testing.allocator.free(mid_bytes);
    try testing.expectEqualSlices(u8, pre_bytes, mid_bytes);

    // Opening a Connection triggers WAL recovery, which must apply the row.
    {
        var conn = try Connection.open(testing.allocator, testing.io, db_path);
        defer conn.close();
    }

    const post_bytes = try std.Io.Dir.cwd().readFileAlloc(testing.io, db_path, testing.allocator, .limited(1024 * 1024));
    defer testing.allocator.free(post_bytes);
    const reader = try page.PageReader.init(post_bytes);
    const db_schema = try schema.readSchema(reader, testing.allocator);
    defer db_schema.deinit(testing.allocator);
    const entry = db_schema.findTable("users") orelse return error.TestUnexpectedResult;
    var info = try catalog.tableInfo(entry, testing.allocator);
    defer info.deinit(testing.allocator);
    const scanned = try table.scanTable(reader, info.root_page, testing.allocator);
    defer scanned.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), scanned.rows.len);
    try testing.expectEqual(@as(i64, 1), scanned.rows[0].rowid);
    try testing.expectEqualStrings("bob", scanned.rows[0].values[1].text);
    try testing.expectEqual(@as(i64, 42), scanned.rows[0].values[2].integer);
}

test "arbitrary WAL truncation yields a prefix of committed txns, never corruption" {
    try skipIfNoSqlite();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const pristine_path = try tmpDbPath(testing.allocator, tmp, "pristine.db");
    defer testing.allocator.free(pristine_path);
    try buildSqliteFixture(pristine_path, "CREATE TABLE t(id INTEGER PRIMARY KEY, n INTEGER);");
    const pristine_bytes = try std.Io.Dir.cwd().readFileAlloc(testing.io, pristine_path, testing.allocator, .limited(1024 * 1024));
    defer testing.allocator.free(pristine_bytes);

    const db_path = try tmpDbPath(testing.allocator, tmp, "t.db");
    defer testing.allocator.free(db_path);
    const wal_path = try walPathFor(testing.allocator, db_path);
    defer testing.allocator.free(wal_path);
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = db_path, .data = pristine_bytes });

    // Construct a WAL containing N committed row_insert entries *without*
    // touching the DB file, so every row's presence post-recovery is 100 %
    // attributable to replay.
    const N: usize = 5;
    var commit_ends: [N]u64 = undefined;
    {
        var wal = try wal_mod.Wal.open(std.Io.Dir.cwd(), testing.io, testing.allocator, wal_path);
        defer wal.close(testing.io);
        var i: usize = 0;
        while (i < N) : (i += 1) {
            const vals = [_]InsertValue{ .null, .{ .integer = @intCast(i + 100) } };
            const payload = try wal_codec.encodeInsert(testing.allocator, "t", @intCast(i + 1), &vals);
            defer testing.allocator.free(payload);
            const txn_id = nextTxnId();
            _ = try wal.write(testing.io, txn_id, .row_insert, wal_mod.DB_TAG_SQLITE, 0, payload);
            try wal.commit(testing.io, txn_id, wal_mod.DB_TAG_SQLITE);
            commit_ends[i] = wal.end_offset;
        }
    }

    const wal_full = try std.Io.Dir.cwd().readFileAlloc(testing.io, wal_path, testing.allocator, .limited(1024 * 1024));
    defer testing.allocator.free(wal_full);

    // For every truncation offset, reset DB+WAL, open a Connection (runs
    // recovery + post-recovery flush), and assert row count equals the
    // largest k such that commit_ends[k-1] <= off.
    var off: usize = 0;
    while (off <= wal_full.len) : (off += 1) {
        try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = db_path, .data = pristine_bytes });
        try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = wal_path, .data = wal_full[0..off] });

        var conn = try Connection.open(testing.allocator, testing.io, db_path);
        conn.close();

        const bytes = try std.Io.Dir.cwd().readFileAlloc(testing.io, db_path, testing.allocator, .limited(1024 * 1024));
        defer testing.allocator.free(bytes);
        const reader = try page.PageReader.init(bytes);
        const db_schema = try schema.readSchema(reader, testing.allocator);
        defer db_schema.deinit(testing.allocator);
        const entry = db_schema.findTable("t") orelse return error.TestUnexpectedResult;
        var info = try catalog.tableInfo(entry, testing.allocator);
        defer info.deinit(testing.allocator);
        const scanned = try table.scanTable(reader, info.root_page, testing.allocator);
        defer scanned.deinit(testing.allocator);

        var expected: usize = 0;
        for (commit_ends) |end| {
            if (end <= off) expected += 1;
        }
        try testing.expectEqual(expected, scanned.rows.len);

        // Rows present must be a contiguous prefix of the intended ids.
        for (scanned.rows, 0..) |row, j| {
            try testing.expectEqual(@as(i64, @intCast(j + 1)), row.rowid);
        }
    }
}

test "batched inserts defer checkpoint and recover after simulated crash" {
    try skipIfNoSqlite();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const db_path = try tmpDbPath(testing.allocator, tmp, "t.db");
    defer testing.allocator.free(db_path);
    try buildSqliteFixture(db_path, "CREATE TABLE users(id INTEGER PRIMARY KEY, name TEXT);");

    // Phase 1: issue several inserts below the checkpoint threshold and
    // then skip the final flush, simulating a crash mid-batch.
    {
        var conn = try Connection.open(testing.allocator, testing.io, db_path);
        _ = try conn.insert("users", &.{ .null, .{ .text = "a" } });
        _ = try conn.insert("users", &.{ .null, .{ .text = "b" } });
        _ = try conn.insert("users", &.{ .null, .{ .text = "c" } });
        // The WAL should still hold committed-but-uncheckpointed entries.
        try testing.expect(conn.wal.end_offset > 0);
        try testing.expect(conn.wal.synced_lsn > conn.wal.checkpoint_lsn);
        // Simulate crash: drop the handle's resources without flushing.
        // We skip the writeFile that `close` would do, leaving the on-disk
        // data file behind while the WAL still holds the unapplied commits.
        conn.wal.close(testing.io);
        conn.image.deinit(testing.allocator);
        conn.deinitCache();
        testing.allocator.free(conn.wal_path);
    }

    // Phase 2: reopen. Recovery must replay every committed row, and the
    // post-recovery flush must leave the WAL empty.
    {
        var conn = try Connection.open(testing.allocator, testing.io, db_path);
        defer conn.close();
        try testing.expectEqual(@as(u64, 0), conn.wal.end_offset);
    }

    const bytes = try std.Io.Dir.cwd().readFileAlloc(testing.io, db_path, testing.allocator, .limited(1024 * 1024));
    defer testing.allocator.free(bytes);
    const reader = try page.PageReader.init(bytes);
    const db_schema = try schema.readSchema(reader, testing.allocator);
    defer db_schema.deinit(testing.allocator);
    const entry = db_schema.findTable("users") orelse return error.TestUnexpectedResult;
    var info = try catalog.tableInfo(entry, testing.allocator);
    defer info.deinit(testing.allocator);
    const scanned = try table.scanTable(reader, info.root_page, testing.allocator);
    defer scanned.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 3), scanned.rows.len);
    try testing.expectEqualStrings("a", scanned.rows[0].values[1].text);
    try testing.expectEqualStrings("b", scanned.rows[1].values[1].text);
    try testing.expectEqualStrings("c", scanned.rows[2].values[1].text);
}

test "many inserts split the b-tree across multiple leaves" {
    // This test is O(N²) per iteration (each insert rewrites the whole
    // image), which makes it minutes-long in Debug. Exercise it only when
    // the compiler can make single ops fast.
    if (@import("builtin").mode == .Debug) return error.SkipZigTest;
    try skipIfNoSqlite();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const db_path = try tmpDbPath(testing.allocator, tmp, "t.db");
    defer testing.allocator.free(db_path);
    try buildSqliteFixture(db_path, "CREATE TABLE t(id INTEGER PRIMARY KEY, n INTEGER);");

    const N: i64 = 800; // ~10-byte cells × 800 = ~8 KiB → at least two leaves at 4 KiB page size.
    {
        var conn = try Connection.open(testing.allocator, testing.io, db_path);
        defer conn.close();
        var i: i64 = 0;
        while (i < N) : (i += 1) {
            _ = try conn.insert("t", &.{ .null, .{ .integer = i } });
        }
    }

    // Read back via our own b-tree walker.
    const bytes = try std.Io.Dir.cwd().readFileAlloc(testing.io, db_path, testing.allocator, .limited(4 * 1024 * 1024));
    defer testing.allocator.free(bytes);
    const reader = try page.PageReader.init(bytes);
    const db_schema = try schema.readSchema(reader, testing.allocator);
    defer db_schema.deinit(testing.allocator);
    const entry = db_schema.findTable("t") orelse return error.TestUnexpectedResult;
    var info = try catalog.tableInfo(entry, testing.allocator);
    defer info.deinit(testing.allocator);

    // Root must now be an interior page (i.e. the split happened).
    const root_ref = try reader.page(info.root_page);
    const root_hdr = try btree.PageHeader.parse(root_ref);
    try testing.expectEqual(btree.PageType.table_interior, root_hdr.page_type);

    const scanned = try table.scanTable(reader, info.root_page, testing.allocator);
    defer scanned.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, @intCast(N)), scanned.rows.len);
    for (scanned.rows, 0..) |row, i| {
        try testing.expectEqual(@as(i64, @intCast(i + 1)), row.rowid);
        try testing.expectEqual(@as(i64, @intCast(i)), row.values[1].integer);
    }

    // Final safety net: hand the file to sqlite3 and ask it to verify.
    const res = try std.process.run(testing.allocator, testing.io, .{
        .argv = &.{ "sqlite3", db_path, "PRAGMA integrity_check;" },
    });
    defer testing.allocator.free(res.stdout);
    defer testing.allocator.free(res.stderr);
    try testing.expect(res.term == .exited and res.term.exited == 0);
    try testing.expect(std.mem.indexOf(u8, res.stdout, "ok") != null);
}

test "update and delete round-trip through Connection" {
    try skipIfNoSqlite();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const db_path = try tmpDbPath(testing.allocator, tmp, "t.db");
    defer testing.allocator.free(db_path);
    try buildSqliteFixture(db_path, "CREATE TABLE users(id INTEGER PRIMARY KEY, name TEXT, age INTEGER);");

    {
        var conn = try Connection.open(testing.allocator, testing.io, db_path);
        defer conn.close();
        _ = try conn.insert("users", &.{ .null, .{ .text = "alice" }, .{ .integer = 30 } });
        _ = try conn.insert("users", &.{ .null, .{ .text = "bob" }, .{ .integer = 40 } });

        const changed = try conn.update(.{
            .table_name = "users",
            .assignment = .{ .column_name = "age", .value = .{ .integer = 31 } },
            .where_clause = .{ .column_name = "name", .value = .{ .text = "alice" } },
        });
        try testing.expectEqual(@as(usize, 1), changed);

        const deleted = try conn.delete(.{
            .table_name = "users",
            .where_clause = .{ .column_name = "name", .value = .{ .text = "bob" } },
        });
        try testing.expectEqual(@as(usize, 1), deleted);
    }

    const bytes = try std.Io.Dir.cwd().readFileAlloc(testing.io, db_path, testing.allocator, .limited(1024 * 1024));
    defer testing.allocator.free(bytes);
    const reader = try page.PageReader.init(bytes);
    const db_schema = try schema.readSchema(reader, testing.allocator);
    defer db_schema.deinit(testing.allocator);
    const entry = db_schema.findTable("users") orelse return error.TestUnexpectedResult;
    var info = try catalog.tableInfo(entry, testing.allocator);
    defer info.deinit(testing.allocator);
    const scanned = try table.scanTable(reader, info.root_page, testing.allocator);
    defer scanned.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), scanned.rows.len);
    try testing.expectEqualStrings("alice", scanned.rows[0].values[1].text);
    try testing.expectEqual(@as(i64, 31), scanned.rows[0].values[2].integer);
}
