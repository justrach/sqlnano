const std = @import("std");
const btree = @import("btree.zig");
const catalog = @import("catalog.zig");
const header = @import("header.zig");
const mapped_file = @import("mapped_file.zig");
const page = @import("page.zig");
const record = @import("record.zig");
const schema = @import("schema.zig");
const table = @import("table.zig");
const wal_mod = @import("wal.zig");
const wal_codec = @import("wal_codec.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const MappedFile = mapped_file.MappedFile;

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
    image: *MappedFile,
    /// Flipped to true by any successful apply. Callers use it to
    /// decide whether the post-recovery image needs a final msync.
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

/// When the on-disk WAL grows past this many bytes, `maybeCheckpoint`
/// flushes the image and compacts the WAL. 1 MiB balances batch
/// amortisation against crash-replay cost.
pub const checkpoint_threshold_bytes: u64 = 1 * 1024 * 1024;

pub const Connection = struct {
    gpa: Allocator,
    io: Io,
    db_path: []const u8,
    wal_path: []u8,
    wal: wal_mod.Wal,
    /// `mmap`-backed view of the database file. `image.items()` hands
    /// out a mutable slice of the file contents; the OS page cache
    /// decides which pages live in RAM at any given moment, which
    /// lets us run against databases larger than memory. Writes go
    /// straight into the mapped region; `flush` runs `msync` on the
    /// pages we've dirtied since the last checkpoint.
    image: MappedFile,
    /// Set by any op that mutates `image`. `flush` clears it after a
    /// successful `msync`.
    image_dirty: bool,
    /// Bit i = page (i+1) has been mutated since last successful flush.
    /// Only meaningful when `full_rewrite` is false. Used by `flush`
    /// to decide which byte ranges of the mmap need `msync`ing.
    dirty_pages: std.bit_set.DynamicBitSetUnmanaged,
    /// When true, the next flush must `msync` the entire mapping. Set
    /// by slow-path ops (UPDATE / DELETE / the generic b-tree rebuild)
    /// that can move row data across pages at will. The incremental
    /// INSERT fast paths keep this false.
    full_rewrite: bool,
    /// Cached from the SQLite header at open. Used by the incremental
    /// flush to turn page numbers into byte offsets. SQLite never
    /// rewrites this field in practice; if it ever did, `full_rewrite`
    /// would bypass this path.
    page_size_cached: usize,
    /// Per-table cache of the next rowid to assign for `VALUES (NULL, ...)`
    /// inserts. Lazily populated from a single `scanTable` per table, then
    /// incremented in place on every auto-rowid insert. Anything that
    /// could shift rowids (explicit rowid INSERT, DELETE, ROLLBACK once
    /// that exists) invalidates the matching entry.
    next_rowid_cache: std.StringHashMap(i64),
    /// Lazily-populated schema cache. Parsed once from the sqlite_schema
    /// b-tree on first access; all string fields are dupe'd into `gpa` so
    /// the cache survives mmap resize. Invalidated on DDL (not yet wired).
    cached_schema: ?schema.Schema = null,
    /// Per-table cache of parsed `catalog.TableInfo`. Populated on first
    /// reference to each table; string fields are dupe'd into `gpa`.
    cached_table_infos: std.StringHashMap(catalog.TableInfo),
    /// Per-op scratch arena. Reset at the top of every mutating op. Used
    /// for everything transient in the hot path — parsed schema view,
    /// table info, WAL payload, cell buffer — so the steady state is
    /// zero malloc/free pairs per insert. Backed by the page allocator
    /// so released memory goes straight to the OS instead of being
    /// retained by the GPA. Inspired by the same hack in justrach/codedb.
    scratch_arena: std.heap.ArenaAllocator,

    /// When true, `insert`/`update`/`delete` write WAL entries but defer
    /// `commit` + fsync until `commitBatch()`. Amortises one fsync across
    /// many ops. Real transaction semantics (undo on rollback) are not
    /// implemented yet — this is just I/O batching.
    in_batch: bool = false,
    /// Transaction id reused for every WAL entry in the current batch.
    batch_txn_id: u64 = 0,

    /// Set to true after an early `persistImage` (at 50 % of the
    /// threshold). When `maybeCheckpoint` fires a second time it skips
    /// `persistImage` unless new pages were dirtied since.
    checkpoint_early_flushed: bool = false,

    pub fn open(gpa: Allocator, io: Io, db_path: []const u8) WriteError!Connection {
        const wal_path = try walPathFor(gpa, db_path);
        errdefer gpa.free(wal_path);

        var wal = try wal_mod.Wal.open(std.Io.Dir.cwd(), io, gpa, wal_path);
        errdefer wal.close(io);

        // mmap the data file. Creating a fresh file here is fine —
        // the b-tree code will ftruncate it to the first real page
        // when the caller's `CREATE TABLE` lands.
        var image = try MappedFile.open(io, db_path, .read_write);
        errdefer image.deinit();

        // Parse page size from the SQLite header at byte 16 (BE u16,
        // where 1 means 65536). Falls back to 4096 on empty / tiny DBs.
        const page_size: usize = blk: {
            if (image.items.len < 18) break :blk 4096;
            const raw = std.mem.readInt(u16, image.items[16..18], .big);
            if (raw == 1) break :blk 65536;
            if (raw == 0) break :blk 4096;
            break :blk raw;
        };

        var conn = Connection{
            .gpa = gpa,
            .io = io,
            .db_path = db_path,
            .wal_path = wal_path,
            .wal = wal,
            .image = image,
            .image_dirty = false,
            .dirty_pages = .{},
            .full_rewrite = true,
            .page_size_cached = page_size,
            .next_rowid_cache = std.StringHashMap(i64).init(gpa),
            .cached_table_infos = std.StringHashMap(catalog.TableInfo).init(gpa),
            .scratch_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator),
        };
        errdefer {
            conn.deinitCache();
            conn.scratch_arena.deinit();
            conn.dirty_pages.deinit(gpa);
        }

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
        self.image.deinit();
        self.dirty_pages.deinit(self.gpa);
        self.deinitCache();
        self.scratch_arena.deinit();
        self.gpa.free(self.wal_path);
    }

    fn deinitCache(self: *Connection) void {
        // Rowid cache keys are dupe'd.
        var rit = self.next_rowid_cache.iterator();
        while (rit.next()) |entry| self.gpa.free(entry.key_ptr.*);
        self.next_rowid_cache.deinit();

        // Table info cache: each entry owns a dupe'd key + dupe'd TableInfo.
        var tit = self.cached_table_infos.iterator();
        while (tit.next()) |entry| {
            self.gpa.free(entry.key_ptr.*);
            for (entry.value_ptr.columns) |col| {
                self.gpa.free(col.name);
            }
            self.gpa.free(entry.value_ptr.columns);
            self.gpa.free(entry.value_ptr.name);
        }
        self.cached_table_infos.deinit();

        if (self.cached_schema != null) {
            self.dupeSchemaDeinit();
            self.cached_schema = null;
        }
    }

    fn invalidateRowidCache(self: *Connection, table_name: []const u8) void {
        if (self.next_rowid_cache.fetchRemove(table_name)) |kv| self.gpa.free(kv.key);
    }

    /// Load (or return cached) schema + per-table catalog info. Parsed from
    /// the sqlite_schema b-tree on first access; all string fields are dupe'd
    /// into `gpa` so the cache survives mmap resize from fast-path splits.
    /// Returns borrowed references into `self` — caller must not hold them
    /// across DDL (not yet supported through Connection).
    fn getOrLoadTableInfo(self: *Connection, table_name: []const u8) WriteError!struct { schema: *schema.Schema, info: *catalog.TableInfo } {
        // ── schema: load once ───────────────────────────────────────
        if (self.cached_schema == null) {
            const reader = try page.PageReader.init(self.image.items);
            if (reader.db_header.isWal()) return error.WalModeUnsupported;
            const raw = try schema.readSchema(reader, self.gpa);
            try self.dupeSchema(raw);
            raw.deinit(self.gpa);
        }
        const cs = &self.cached_schema.?;

        // ── per-table info: load once per table ─────────────────────
        const gop = try self.cached_table_infos.getOrPut(table_name);
        if (!gop.found_existing) {
            const entry = cs.findTable(table_name) orelse return error.TableNotFound;
            const raw = try catalog.tableInfo(entry, self.gpa);
            // Key must outlive the hash map; dup into gpa.
            gop.key_ptr.* = try self.gpa.dupe(u8, table_name);
            gop.value_ptr.* = try self.dupeTableInfo(raw);
            raw.deinit(self.gpa);
        }
        return .{ .schema = cs, .info = gop.value_ptr };
    }

    /// Set the WAL durability mode. See `wal.SyncMode`. Defaults to `.full`.
    pub fn setSyncMode(self: *Connection, mode: wal_mod.SyncMode) void {
        self.wal.sync_mode = mode;
    }

    /// Persist the image (if dirty), then checkpoint + compact the WAL.
    /// Safe to call at any point; no-op when image is clean and WAL is
    /// empty.
    ///
    /// Two paths:
    ///
    ///   * Full rewrite — when `full_rewrite` is set, or when page size
    ///     has changed, or the dirty bitmap has grown beyond what an
    ///     incremental write can cover. The entire image is written
    ///     via `writeFile` (truncate + write).
    ///
    ///   * Incremental — iterate the dirty-page bitmap, pwrite each
    ///     dirty page into the kept-open `db_file`. This turns
    ///     `O(N * file_size)` per checkpoint (full rewrite) into
    ///     `O(dirty_pages * page_size)`, which is ~2-5 pages for every
    ///     fast-path insert regardless of total table size.
    ///
    /// After a successful write path runs, the WAL is checkpointed and
    /// compacted. The data file gets a single `fsync` before that
    /// happens so WAL compaction can't rewind us past committed state.
    pub fn flush(self: *Connection) WriteError!void {
        if (self.image_dirty) {
            try self.persistImage();
            self.image_dirty = false;
            self.full_rewrite = false;
            self.dirty_pages.unsetAll();
        }
        if (self.wal.end_offset == 0 and self.wal.synced_lsn == self.wal.checkpoint_lsn) return;
        if (self.wal.synced_lsn > self.wal.checkpoint_lsn) {
            try self.wal.checkpoint(self.io, wal_mod.DB_TAG_SQLITE);
        }
        self.wal.compact(self.io) catch {};
    }

    fn persistImage(self: *Connection) WriteError!void {
        // With mmap, writes landed in the kernel's page cache the
        // moment the fast path stored into the mapping. `msync(SYNC)`
        // is what guarantees they reach stable storage.
        if (self.full_rewrite) {
            try self.image.syncAll();
            return;
        }

        const page_size = self.page_size_cached;
        const image_len = self.image.length();
        var it = self.dirty_pages.iterator(.{});
        while (it.next()) |bit_idx| {
            const page_num_0: u64 = @intCast(bit_idx);
            const off = page_num_0 * @as(u64, page_size);
            if (off + page_size > image_len) continue; // page allocated then truncated — rare
            try self.image.syncRange(off, page_size);
        }
    }

    /// Mark `page_num` (1-based) as dirty. Called by every fast path at
    /// each page it mutates. No-op when `full_rewrite` is already set —
    /// the full path writes the entire image anyway.
    fn markPageDirty(self: *Connection, page_num: u32) !void {
        if (self.full_rewrite) return;
        std.debug.assert(page_num >= 1);
        const idx: usize = @intCast(page_num - 1);
        if (idx >= self.dirty_pages.bit_length) {
            const new_len = idx + 1;
            // Round up to reduce reallocations as the table grows.
            const grown = std.math.ceilPowerOfTwo(usize, @max(new_len, 64)) catch new_len;
            try self.dirty_pages.resize(self.gpa, grown, false);
        }
        self.dirty_pages.set(idx);
    }

    fn markPagesDirty(self: *Connection, first: u32, count: u32) !void {
        if (self.full_rewrite) return;
        var i: u32 = 0;
        while (i < count) : (i += 1) try self.markPageDirty(first + i);
    }

    fn maybeCheckpoint(self: *Connection) WriteError!void {
        const half = checkpoint_threshold_bytes / 2;
        // Early persist at 50 % of the threshold: flush dirty image
        // pages now so that when we cross the full threshold later,
        // only the WAL checkpoint + compact remain. The bitmap is
        // cleared and will repopulate if more writes land before the
        // threshold.
        if (self.image_dirty and self.wal.end_offset >= half and !self.checkpoint_early_flushed) {
            try self.persistImage();
            self.image_dirty = false;
            self.dirty_pages.unsetAll();
            self.checkpoint_early_flushed = true;
        }
        if (self.wal.end_offset < checkpoint_threshold_bytes) return;

        // At the full threshold: if we early-flushed and no new pages
        // are dirty, skip persistImage and go straight to checkpoint.
        if (self.checkpoint_early_flushed and !self.image_dirty) {
            if (self.wal.synced_lsn > self.wal.checkpoint_lsn) {
                try self.wal.checkpoint(self.io, wal_mod.DB_TAG_SQLITE);
            }
            self.wal.compact(self.io) catch {};
            self.checkpoint_early_flushed = false;
            return;
        }
        // Fallback: full flush (persist + checkpoint + compact).
        try self.flush();
        self.checkpoint_early_flushed = false;
    }

    // ── batch I/O ────────────────────────────────────────────────────

    /// Start a write batch. Every subsequent `insert` / `update` / `delete`
    /// appends to the WAL buffer but skips `commit` + fsync + checkpoint.
    /// Call `commitBatch` to finalise, or `rollbackBatch` to discard.
    pub fn beginBatch(self: *Connection) void {
        std.debug.assert(!self.in_batch);
        self.in_batch = true;
        self.batch_txn_id = nextTxnId();
    }

    /// Flush the WAL buffer to disk, then checkpoint if the threshold is
    /// exceeded. After this returns, all batched ops are durable (subject
    /// to `sync_mode`).
    pub fn commitBatch(self: *Connection) WriteError!void {
        std.debug.assert(self.in_batch);
        self.in_batch = false;
        try self.wal.commit(self.io, self.batch_txn_id, wal_mod.DB_TAG_SQLITE);
        try self.maybeCheckpoint();
    }

    /// Discard an in-progress batch. WAL entries buffered beyond the last
    /// commit are unreachable by recovery (recovery skips entries without a
    /// matching `txn_commit` record). Image mutations already applied are
    /// NOT rolled back — this is I/O batching, not transactional undo.
    pub fn rollbackBatch(self: *Connection) void {
        std.debug.assert(self.in_batch);
        self.in_batch = false;
    }

    pub fn insert(self: *Connection, table_name: []const u8, values: []const InsertValue) WriteError!i64 {
        // One arena reset per op. All transient allocations below use
        // `scratch` and become zero-cost after the final reset in a
        // tight loop — no free, no fragmentation, pages reused.
        _ = self.scratch_arena.reset(.retain_capacity);
        const scratch = self.scratch_arena.allocator();

        // Schema + catalog info are cached after the first access.
        // `getOrLoadTableInfo` dups string fields into `gpa` so the
        // cache survives mmap resize from fast-path b-tree splits.
        const cached = try self.getOrLoadTableInfo(table_name);
        const db_schema = cached.schema.*;
        const info = cached.info.*;
        if (values.len != info.columns.len) return error.ColumnCountMismatch;
        if (info.root_page == 1) return error.UnsupportedInsert;

        const reader = try page.PageReader.init(self.image.items);

        const resolved = try self.resolveRowidShared(scratch, reader, db_schema, info, table_name, values);
        const rowid = resolved.rowid;

        const payload = try wal_codec.encodeInsert(scratch, table_name, rowid, values);
        const txn_id = if (self.in_batch) self.batch_txn_id else nextTxnId();
        _ = try self.wal.write(self.io, txn_id, .row_insert, wal_mod.DB_TAG_SQLITE, 0, payload);
        if (!self.in_batch) try self.wal.commit(self.io, txn_id, wal_mod.DB_TAG_SQLITE);

        // The append-only fast paths (A/B/C) assume the new rowid is
        // strictly greater than every existing rowid in the rightmost
        // leaf — true for auto-rowid and for explicit rowids that
        // happen to extend the key space, but NOT in general. An
        // explicit rowid smaller than the current max would silently
        // corrupt b-tree ordering. Gate them behind an in-order check.
        const is_auto = resolved.is_auto;
        const in_order = is_auto or self.explicitRowidExtendsTable(reader, info, rowid);

        // Fast path A: no indexes, append-at-end, fits in current rightmost
        // leaf. Short-circuits the full b-tree rebuild that the generic
        // path would do.
        const fast = in_order and try self.tryFastAppendShared(scratch, reader, db_schema, info, values, rowid);
        if (!fast) {
            // Fast path B: rightmost leaf is full, parent interior has
            // room for one more divider. Allocate one fresh leaf, stamp
            // the new cell there alone, append a single divider into the
            // parent. O(1) per split.
            //
            // After a successful split the post-resize `image.items`
            // backing has moved, so anything pointing into the old
            // backing (`reader`, `db_schema`, `info`'s string fields) is
            // dangling. We deliberately don't use them past this point.
            const split = in_order and try self.tryFastSplitAppendShared(scratch, reader, db_schema, info, values, rowid);
            if (!split) {
                // Fast path C: rightmost leaf is full AND the parent IS
                // the root AND the root is itself full. Promote the root
                // to a level-2 interior — 3 fresh pages: a copy of the
                // old root holding the existing 400-ish leaves, a fresh
                // sibling interior pointing to the new leaf, and the new
                // leaf itself. Past this point the tree depth grows by 1
                // and subsequent splits go back through path B.
                const promoted = in_order and try self.tryFastPromoteRoot(scratch, reader, db_schema, info, values, rowid);
                if (!promoted) {
                    // Generic rebuild can move row data across pages at
                    // will; force the next flush to rewrite everything.
                    self.full_rewrite = true;
                    _ = try applyInsertCore(self.gpa, &self.image, table_name, values, rowid, .fresh);
                }
            }
        }
        try self.bumpRowidCache(table_name, rowid);
        self.image_dirty = true;
        if (!self.in_batch) try self.maybeCheckpoint();
        return rowid;
    }

    const ResolvedRowid = struct { rowid: i64, is_auto: bool };

    /// Compute the rowid a `VALUES (NULL, ...)` insert would receive,
    /// reusing already-parsed schema + info from the caller. Falls back
    /// to a full scan only on a cache miss.
    fn resolveRowidShared(
        self: *Connection,
        scratch: Allocator,
        reader: page.PageReader,
        _: schema.Schema,
        info: catalog.TableInfo,
        table_name: []const u8,
        values: []const InsertValue,
    ) WriteError!ResolvedRowid {
        const is_auto = blk: {
            if (info.integer_primary_key_index) |ipk| {
                break :blk switch (values[ipk]) {
                    .null => true,
                    .integer => |v| if (v <= 0) return error.UnsupportedRowid else false,
                    else => return error.UnsupportedRowid,
                };
            }
            break :blk true;
        };

        if (!is_auto) {
            // Explicit rowid — cache can't help; defer to the scan-based
            // resolver, which also checks for duplicates.
            const rid = try resolveInsertRowid(self.gpa, &self.image, table_name, values);
            return .{ .rowid = rid, .is_auto = false };
        }

        if (self.next_rowid_cache.get(table_name)) |cached| {
            return .{ .rowid = cached, .is_auto = true };
        }

        // Cold path: one scan to find the current max rowid, then cache.
        const scanned = try table.scanTable(reader, info.root_page, scratch);
        var max: i64 = 0;
        for (scanned.rows) |row| max = @max(max, row.rowid);
        return .{ .rowid = max + 1, .is_auto = true };
    }

    /// True iff `rowid` is strictly greater than every rowid currently
    /// in `info.root_page`'s tree — i.e. the append-only fast paths
    /// are safe. Reuses the rowid cache when populated (O(1)); only
    /// scans the table on a cache miss. Called only for explicit
    /// rowids, which are rare in practice.
    fn explicitRowidExtendsTable(self: *Connection, reader: page.PageReader, info: catalog.TableInfo, rowid: i64) bool {
        _ = reader;
        if (self.next_rowid_cache.get(info.name)) |cached| {
            return rowid >= cached;
        }
        // Conservative: no cache yet → fall through to the slow path,
        // which doesn't care about ordering.
        return false;
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

    /// Same fast path as before, but taking already-parsed schema/info
    /// from the caller and building the cell on the scratch arena. The
    /// row's rowid must already be > every rowid in the table (enforced
    /// upstream by the auto-rowid cache).
    fn tryFastAppendShared(
        self: *Connection,
        scratch: Allocator,
        reader: page.PageReader,
        db_schema: schema.Schema,
        info: catalog.TableInfo,
        values: []const InsertValue,
        rowid: i64,
    ) WriteError!bool {
        // Any index on this table → let the rebuild path keep indexes in sync.
        for (db_schema.entries) |e| {
            if (!e.isIndex() or e.root_page <= 0) continue;
            if (std.ascii.eqlIgnoreCase(e.table_name, info.name)) return false;
        }

        // Walk to the rightmost leaf. A malformed tree aborts the fast
        // path quietly; the rebuild caller will either succeed or
        // surface a real error.
        const rightmost = rightmostTableLeaf(reader, info.root_page) catch return false;

        const payload = try encodeRecord(info, rowid, values, scratch);
        const page_size: usize = reader.db_header.page_size;
        const reserved: usize = reader.db_header.reserved_space;
        const usable = page_size - reserved;
        const info_pl = btree.tableLeafPayloadInfo(payload.len, usable);
        if (info_pl.overflow_page != null) return false;

        // Stack buffer for the cell envelope when it fits. `2 * 9` is
        // the max size of two varints (payload_size + rowid) and the
        // typical payload for a small row is well under 128 bytes, so
        // almost every insert stays in the stack fast path.
        var stack_cell: [256]u8 = undefined;
        const cell_head_max: usize = 2 * 9;
        const cell_total = cell_head_max + payload.len;
        const cell_buf: []u8 = if (cell_total <= stack_cell.len)
            stack_cell[0..]
        else
            try scratch.alloc(u8, cell_total);

        var writer_pos: usize = 0;
        writer_pos += encodeVarintInto(cell_buf[writer_pos..], @intCast(payload.len));
        writer_pos += encodeVarintInto(cell_buf[writer_pos..], @intCast(rowid));
        @memcpy(cell_buf[writer_pos..][0..payload.len], payload);
        const cell_len = writer_pos + payload.len;

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
        const new_cell_start_abs = content_start_abs_old - cell_len;
        // Must fit: new cell content can't collide with the pointer array
        // after we grow that array by one more slot.
        if (new_cell_start_abs < ptr_slot + 2) return false;

        @memcpy(mutable[new_cell_start_abs..][0..cell_len], cell_buf[0..cell_len]);
        const new_rel_off: u16 = @intCast(new_cell_start_abs - page_start);
        writeU16(mutable[ptr_slot..][0..2], new_rel_off);
        writeU16(mutable[base + 3 .. base + 5], cell_count + 1);
        writeU16(mutable[base + 5 .. base + 7], new_rel_off);

        const current_change = readU32(mutable[24..28]);
        writeU32(mutable[24..28], current_change +% 1);
        if (mutable.len >= 96) writeU32(mutable[92..96], current_change +% 1);

        try self.markPageDirty(1);
        try self.markPageDirty(rightmost);
        return true;
    }

    /// Fast path B: the rightmost leaf is full. Find the lowest interior
    /// page on the right-most chain that has room for one more divider
    /// cell, allocate exactly the new pages we need to splice in a fresh
    /// rightmost leaf at that level, and stamp the new cell into it.
    ///
    /// The shape of the splice depends on where the room is:
    ///
    ///   * If the rightmost leaf's parent has room → just one new leaf,
    ///     one new divider in the parent. (The original O(1) fast split.)
    ///
    ///   * If the parent is full but a higher ancestor has room → we
    ///     allocate one fresh interior at every level between that
    ///     ancestor and the leaf, plus the new leaf itself. The chain
    ///     of fresh interiors all carry only a right-most pointer (zero
    ///     divider cells). The ancestor with room gets one new divider
    ///     pointing at its previous right-most subtree, and its
    ///     right_most_pointer is repointed at the top of the fresh
    ///     chain. This handles the case where a freshly-promoted
    ///     interior fills up after ~400 rows past the previous root
    ///     promotion.
    ///
    ///   * If no ancestor has room (the root itself is full) → bail and
    ///     let `tryFastPromoteRoot` grow the tree depth.
    ///
    /// All bookkeeping is on the right edge of the tree. Auto-rowid
    /// guarantees the new cell has the largest rowid by construction,
    /// so this is a strictly-asymmetric split: existing row data is
    /// never moved.
    fn tryFastSplitAppendShared(
        self: *Connection,
        scratch: Allocator,
        reader: page.PageReader,
        db_schema: schema.Schema,
        info: catalog.TableInfo,
        values: []const InsertValue,
        rowid: i64,
    ) WriteError!bool {
        for (db_schema.entries) |e| {
            if (!e.isIndex() or e.root_page <= 0) continue;
            if (std.ascii.eqlIgnoreCase(e.table_name, info.name)) return false;
        }

        const root_ref = reader.page(info.root_page) catch return false;
        const root_hdr = btree.PageHeader.parse(root_ref) catch return false;
        if (root_hdr.page_type != .table_interior) return false;

        // Walk root → leaf via right-most pointers, collecting the
        // interior chain. depth = number of interior levels.
        const max_depth = 8;
        var ancestors: [max_depth]u32 = undefined;
        var depth: usize = 0;
        var walking: u32 = info.root_page;
        while (depth < max_depth) {
            const ref = reader.page(walking) catch return false;
            const hdr = btree.PageHeader.parse(ref) catch return false;
            switch (hdr.page_type) {
                .table_leaf => break,
                .table_interior => {
                    ancestors[depth] = walking;
                    depth += 1;
                    walking = hdr.right_most_pointer orelse return false;
                },
                else => return false,
            }
        }
        if (depth == 0) return false; // root is leaf — handled by the slow path
        if (depth >= max_depth) return false; // tree too deep for this fast path
        const old_rightmost_leaf = walking;

        const last_rowid = lastRowidInTableLeaf(reader, old_rightmost_leaf) catch return false;

        // Divider template; left_child filled in below depending on `s`.
        var divider_buf: [4 + 9]u8 = undefined;
        const div_v_len = encodeVarintInto(divider_buf[4..], @intCast(last_rowid));
        const divider_len: usize = 4 + div_v_len;

        const page_size: usize = reader.db_header.page_size;
        const reserved: usize = reader.db_header.reserved_space;

        // Find the lowest ancestor with room for a new divider.
        var split_at: ?usize = null;
        var i_iter: usize = depth;
        while (i_iter > 0) {
            i_iter -= 1;
            if (interiorHasRoomForDivider(self.image.items, ancestors[i_iter], page_size, reserved, divider_len)) {
                split_at = i_iter;
                break;
            }
        }
        if (split_at == null) return false; // root and all intermediates full → path C
        const s = split_at.?;

        // Build the new row's cell so we can bail before resize if it
        // would never fit a leaf.
        const usable: usize = page_size - reserved;
        const payload = try encodeRecord(info, rowid, values, scratch);
        const info_pl = btree.tableLeafPayloadInfo(payload.len, usable);
        if (info_pl.overflow_page != null) return false;

        var stack_cell: [256]u8 = undefined;
        const cell_total = 2 * 9 + payload.len;
        const cell_buf: []u8 = if (cell_total <= stack_cell.len)
            stack_cell[0..]
        else
            try scratch.alloc(u8, cell_total);
        var cpos: usize = 0;
        cpos += encodeVarintInto(cell_buf[cpos..], @intCast(payload.len));
        cpos += encodeVarintInto(cell_buf[cpos..], @intCast(rowid));
        @memcpy(cell_buf[cpos..][0..payload.len], payload);
        const cell_len = cpos + payload.len;
        if (cell_len + 8 + 2 > usable) return false;

        // ── Past this point we mutate `self.image`. ──

        // Pages we allocate: one intermediate interior at each level in
        // (s, depth-1] plus the new leaf.
        const intermediate_chain: usize = depth - 1 - s;
        const new_pages_needed: usize = intermediate_chain + 1;

        const old_image_len = self.image.items.len;
        const file_pages: u32 = @intCast(old_image_len / page_size);
        const effective_page_count: u32 = @max(reader.db_header.database_page_count, file_pages);
        const first_new_page: u32 = effective_page_count + 1;
        const final_page_count: u32 = effective_page_count + @as(u32, @intCast(new_pages_needed));
        const new_image_len: usize = @as(usize, final_page_count) * page_size;
        try self.image.resize(new_image_len);
        @memset(self.image.items[old_image_len..], 0);
        const mutable = self.image.items;

        writeU32(mutable[28..32], final_page_count);
        const current_change = readU32(mutable[24..28]);
        writeU32(mutable[24..28], current_change +% 1);
        if (mutable.len >= 96) writeU32(mutable[92..96], current_change +% 1);

        // Page-number layout for the freshly-allocated pages.
        //   chain_pages[k] for k in [s+1, depth-1]: intermediate interiors
        //   new_leaf                              : the new rightmost leaf
        var chain_pages: [max_depth]u32 = undefined;
        for (0..intermediate_chain) |k| {
            chain_pages[s + 1 + k] = first_new_page + @as(u32, @intCast(k));
        }
        const new_leaf: u32 = first_new_page + @as(u32, @intCast(intermediate_chain));

        writeSingleCellLeafPage(mutable, new_leaf, page_size, reserved, cell_buf[0..cell_len]);

        if (intermediate_chain > 0) {
            // Bottom of the chain points at the new leaf; the rest of
            // the chain points at its successor.
            writeEmptyInteriorPage(mutable, chain_pages[depth - 1], page_size, reserved, new_leaf);
            for (s + 1..depth - 1) |k| {
                writeEmptyInteriorPage(mutable, chain_pages[k], page_size, reserved, chain_pages[k + 1]);
            }
        }

        // Append a new divider to the ancestor that has room. The
        // divider's left_child is whatever the ancestor's right-most
        // child was a moment ago — i.e. the OLD rightmost subtree at
        // that level. Its right_most_pointer is repointed to the head
        // of our freshly-allocated chain (or the new leaf, if no chain).
        const new_left_child: u32 = if (s == depth - 1) old_rightmost_leaf else ancestors[s + 1];
        const new_right_most: u32 = if (intermediate_chain == 0) new_leaf else chain_pages[s + 1];
        std.mem.writeInt(u32, divider_buf[0..4], new_left_child, .big);
        appendInteriorDivider(
            mutable,
            ancestors[s],
            page_size,
            reserved,
            divider_buf[0..divider_len],
            new_right_most,
        );

        try self.markPageDirty(1);
        try self.markPageDirty(ancestors[s]);
        try self.markPageDirty(new_leaf);
        for (s + 1..depth) |k| try self.markPageDirty(chain_pages[k]);
        return true;
    }

    /// Fast path C: the rightmost leaf is full, its parent is the root,
    /// and the root is itself full. We can't append a divider in place
    /// — we need to grow the tree's depth by one. Allocate three fresh
    /// pages:
    ///
    ///   * `I_root_copy`  — a verbatim copy of the old root's bytes.
    ///   * `I_new_chain`  — a brand-new interior whose right_most_pointer
    ///                       is the new leaf and which has zero divider
    ///                       cells.
    ///   * `new_leaf`     — a fresh leaf containing only the new cell.
    ///
    /// Then rewrite the root page in place as a level-2 interior with a
    /// single divider:
    ///
    ///     cell[0] = [u32 BE I_root_copy] [varint last_rowid_in_old_rightmost]
    ///     right_most_pointer = I_new_chain
    ///
    /// Asymmetry is fine: the new cell has the largest rowid in the
    /// table by construction (auto-rowid + the per-table cache), so the
    /// only divider key we need is the previous rightmost-leaf's last
    /// rowid.
    ///
    /// Bails when the table has any indexes, when the parent of the
    /// rightmost leaf is not the root (depth > 1; deeper trees aren't
    /// handled here yet), or when the root happens to be page 1 (which
    /// would collide with `sqlite_schema` — never the case for a real
    /// user table from `sqlite3`).
    fn tryFastPromoteRoot(
        self: *Connection,
        scratch: Allocator,
        reader: page.PageReader,
        db_schema: schema.Schema,
        info: catalog.TableInfo,
        values: []const InsertValue,
        rowid: i64,
    ) WriteError!bool {
        for (db_schema.entries) |e| {
            if (!e.isIndex() or e.root_page <= 0) continue;
            if (std.ascii.eqlIgnoreCase(e.table_name, info.name)) return false;
        }

        if (info.root_page == 1) return false;
        const root_ref = reader.page(info.root_page) catch return false;
        const root_hdr = btree.PageHeader.parse(root_ref) catch return false;
        if (root_hdr.page_type != .table_interior) return false;

        // Depth = 1 only: rightmost leaf's parent must BE the root.
        const parent_info = rightmostInteriorParent(reader, info.root_page) catch return false;
        if (parent_info.parent != info.root_page) return false;
        const old_rightmost_leaf = parent_info.leaf;

        const last_rowid = lastRowidInTableLeaf(reader, old_rightmost_leaf) catch return false;

        // Build the new row's cell up front so we can bail before resize
        // if it would never fit a leaf.
        const page_size: usize = reader.db_header.page_size;
        const reserved: usize = reader.db_header.reserved_space;
        const usable: usize = page_size - reserved;
        const payload = try encodeRecord(info, rowid, values, scratch);
        const info_pl = btree.tableLeafPayloadInfo(payload.len, usable);
        if (info_pl.overflow_page != null) return false;

        var stack_cell: [256]u8 = undefined;
        const cell_total = 2 * 9 + payload.len;
        const cell_buf: []u8 = if (cell_total <= stack_cell.len)
            stack_cell[0..]
        else
            try scratch.alloc(u8, cell_total);
        var cpos: usize = 0;
        cpos += encodeVarintInto(cell_buf[cpos..], @intCast(payload.len));
        cpos += encodeVarintInto(cell_buf[cpos..], @intCast(rowid));
        @memcpy(cell_buf[cpos..][0..payload.len], payload);
        const cell_len = cpos + payload.len;
        if (cell_len + 8 + 2 > usable) return false;

        // ── Past this point we mutate `self.image`. ──

        const old_image_len = self.image.items.len;
        const file_pages: u32 = @intCast(old_image_len / page_size);
        const effective_page_count: u32 = @max(reader.db_header.database_page_count, file_pages);
        const I_root_copy: u32 = effective_page_count + 1;
        const I_new_chain: u32 = effective_page_count + 2;
        const new_leaf: u32 = effective_page_count + 3;
        const final_page_count: u32 = effective_page_count + 3;
        const new_image_len: usize = @as(usize, final_page_count) * page_size;
        try self.image.resize(new_image_len);
        @memset(self.image.items[old_image_len..], 0);
        const mutable = self.image.items;

        writeU32(mutable[28..32], final_page_count);
        const current_change = readU32(mutable[24..28]);
        writeU32(mutable[24..28], current_change +% 1);
        if (mutable.len >= 96) writeU32(mutable[92..96], current_change +% 1);

        // Copy the entire old root page to I_root_copy. The new
        // `cell_content_start`, pointer array, etc. are byte-for-byte
        // identical, so I_root_copy is now a fully-valid interior page
        // covering the same subtree the old root did.
        const root_page_start: usize = (@as(usize, info.root_page) - 1) * page_size;
        const I_root_copy_start: usize = (@as(usize, I_root_copy) - 1) * page_size;
        @memcpy(
            mutable[I_root_copy_start .. I_root_copy_start + page_size],
            mutable[root_page_start .. root_page_start + page_size],
        );

        // Stamp the new leaf with the single new cell.
        writeSingleCellLeafPage(mutable, new_leaf, page_size, reserved, cell_buf[0..cell_len]);

        // Build I_new_chain — empty interior, only a right-most pointer.
        writeEmptyInteriorPage(mutable, I_new_chain, page_size, reserved, new_leaf);

        // Rewrite the (well-known) root page in place as a level-2
        // interior with one divider cell.
        var divider_buf: [4 + 9]u8 = undefined;
        std.mem.writeInt(u32, divider_buf[0..4], I_root_copy, .big);
        const div_v_len = encodeVarintInto(divider_buf[4..], @intCast(last_rowid));
        const divider_len: usize = 4 + div_v_len;
        writeInteriorWithSingleDivider(
            mutable,
            info.root_page,
            page_size,
            reserved,
            divider_buf[0..divider_len],
            I_new_chain,
        );

        try self.markPageDirty(1);
        try self.markPageDirty(info.root_page);
        try self.markPageDirty(I_root_copy);
        try self.markPageDirty(I_new_chain);
        try self.markPageDirty(new_leaf);
        return true;
    }

    pub fn update(self: *Connection, stmt: @import("ast.zig").UpdateStatement) WriteError!usize {
        const payload = try wal_codec.encodeUpdate(self.gpa, stmt);
        defer self.gpa.free(payload);
        const txn_id = if (self.in_batch) self.batch_txn_id else nextTxnId();
        _ = try self.wal.write(self.io, txn_id, .row_update, wal_mod.DB_TAG_SQLITE, 0, payload);
        if (!self.in_batch) try self.wal.commit(self.io, txn_id, wal_mod.DB_TAG_SQLITE);
        const changed = try applyUpdateCore(self.gpa, &self.image, stmt);
        if (changed > 0) {
            self.image_dirty = true;
            self.full_rewrite = true;
            // UPDATE currently can't touch rowid, but be defensive.
            self.invalidateRowidCache(stmt.table_name);
        }
        if (!self.in_batch) try self.maybeCheckpoint();
        return changed;
    }

    pub fn delete(self: *Connection, stmt: @import("ast.zig").DeleteStatement) WriteError!usize {
        const payload = try wal_codec.encodeDelete(self.gpa, stmt);
        defer self.gpa.free(payload);
        const txn_id = if (self.in_batch) self.batch_txn_id else nextTxnId();
        _ = try self.wal.write(self.io, txn_id, .row_delete, wal_mod.DB_TAG_SQLITE, 0, payload);
        if (!self.in_batch) try self.wal.commit(self.io, txn_id, wal_mod.DB_TAG_SQLITE);
        const changed = try applyDeleteCore(self.gpa, &self.image, stmt);
        if (changed > 0) {
            self.image_dirty = true;
            self.full_rewrite = true;
            // Deleting rows doesn't lower next-rowid (SQLite doesn't
            // reuse rowids), but we invalidate so a future auto-rowid
            // insert re-derives from the authoritative image rather
            // than a stale count.
            self.invalidateRowidCache(stmt.table_name);
        }
        if (!self.in_batch) try self.maybeCheckpoint();
        return changed;
    }
    // ── schema cache helpers ──────────────────────────────────────────────

    /// Invalidate the cached schema + all per-table info.
    /// Call after any DDL that changes the schema (CREATE TABLE, DROP TABLE, ALTER TABLE).
    pub fn invalidateSchemaCache(self: *Connection) void {
        self.dupeSchemaDeinit();
        var it = self.cached_table_infos.iterator();
        while (it.next()) |entry| {
            // Free column names individually (they were duped separately)
            for (entry.value_ptr.columns) |col| {
                self.gpa.free(col.name);
            }
            self.gpa.free(entry.value_ptr.columns);
            self.gpa.free(entry.value_ptr.name);
            self.gpa.free(entry.key_ptr.*);
        }
        self.cached_table_infos.clearAndFree();
    }

    fn dupeSchema(self: *Connection, src: schema.Schema) !void {
        // Deep-copy the entries slice and all string fields within each entry.
        const entries = try self.gpa.alloc(schema.SchemaEntry, src.entries.len);
        for (entries, src.entries) |*dst, src_entry| {
            dst.* = schema.SchemaEntry{
                .rowid = src_entry.rowid,
                .object_type = try self.gpa.dupe(u8, src_entry.object_type),
                .name = try self.gpa.dupe(u8, src_entry.name),
                .table_name = try self.gpa.dupe(u8, src_entry.table_name),
                .root_page = src_entry.root_page,
                .sql = try self.gpa.dupe(u8, src_entry.sql),
            };
        }
        self.cached_schema = schema.Schema{ .entries = entries };
    }

    fn dupeSchemaDeinit(self: *Connection) void {
        const cs = self.cached_schema orelse return;
        for (cs.entries) |entry| {
            self.gpa.free(entry.object_type);
            self.gpa.free(entry.name);
            self.gpa.free(entry.table_name);
            self.gpa.free(entry.sql);
        }
        self.gpa.free(cs.entries);
    }

    fn dupeTableInfo(self: *Connection, src: catalog.TableInfo) !catalog.TableInfo {
        // Deep-copy the columns slice and all column names.
        const columns = try self.gpa.alloc(catalog.Column, src.columns.len);
        for (columns, src.columns) |*dst, src_col| {
            dst.* = .{
                .name = try self.gpa.dupe(u8, src_col.name),
                .affinity = src_col.affinity,
                .is_integer_primary_key = src_col.is_integer_primary_key,
            };
        }
        return catalog.TableInfo{
            .name = try self.gpa.dupe(u8, src.name),
            .root_page = src.root_page,
            .columns = columns,
            .integer_primary_key_index = src.integer_primary_key_index,
        };
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

/// Walk down right-most pointers from `start_page` and return the
/// interior page whose `right_most_pointer` points directly at the
/// rightmost leaf, plus that leaf's page number. Returns an error if
/// the start page is itself a leaf (no interior parent exists yet).
fn rightmostInteriorParent(reader: page.PageReader, start_page: u32) !struct { parent: u32, leaf: u32 } {
    var current = start_page;
    while (true) {
        const ref = try reader.page(current);
        const hdr = try btree.PageHeader.parse(ref);
        switch (hdr.page_type) {
            .table_leaf => return error.NoInteriorParent,
            .table_interior => {
                const right = hdr.right_most_pointer orelse return error.MalformedInterior;
                const child_ref = try reader.page(right);
                const child_hdr = try btree.PageHeader.parse(child_ref);
                if (child_hdr.page_type == .table_leaf) {
                    return .{ .parent = current, .leaf = right };
                }
                current = right;
            },
            else => return error.UnexpectedPageType,
        }
    }
}

/// Read the rowid of the last cell in `leaf_page`. Used to derive the
/// separator key when promoting a full leaf into an interior divider.
fn lastRowidInTableLeaf(reader: page.PageReader, leaf_page: u32) !i64 {
    const ref = try reader.page(leaf_page);
    const hdr = try btree.PageHeader.parse(ref);
    if (hdr.page_type != .table_leaf) return error.UnexpectedPageType;
    if (hdr.cell_count == 0) return error.EmptyLeaf;
    const cell = try hdr.cell(ref, hdr.cell_count - 1);
    const payload_size_v = @import("varint.zig").parse(cell) catch return error.InvalidTableCell;
    const rowid_v = @import("varint.zig").parse(cell[payload_size_v.len..]) catch return error.InvalidTableCell;
    return @intCast(rowid_v.value);
}

/// Stamp `page_num` (must not be page 1) as a fresh `table_leaf`
/// containing exactly `cell` and nothing else. Used by fast paths that
/// allocate a new rightmost leaf for a single row append.
fn writeSingleCellLeafPage(
    mutable: []u8,
    page_num: u32,
    page_size: usize,
    reserved: usize,
    cell: []const u8,
) void {
    std.debug.assert(page_num != 1);
    const start: usize = (@as(usize, page_num) - 1) * page_size;
    const usable_end = start + page_size - reserved;
    const cell_off_abs = usable_end - cell.len;
    @memcpy(mutable[cell_off_abs..][0..cell.len], cell);
    const cell_rel: u16 = @intCast(cell_off_abs - start);
    mutable[start + 0] = @intFromEnum(btree.PageType.table_leaf);
    writeU16(mutable[start + 1 .. start + 3], 0); // first freeblock
    writeU16(mutable[start + 3 .. start + 5], 1); // cell_count
    writeU16(mutable[start + 5 .. start + 7], cell_rel); // cell_content_start
    mutable[start + 7] = 0; // fragmented free
    writeU16(mutable[start + 8 .. start + 10], cell_rel);
}

/// Stamp `page_num` (must not be page 1) as a fresh `table_interior`
/// with zero divider cells and a single right-most pointer. Used by the
/// root-promotion path to add a brand-new interior chain on the right
/// edge of the tree.
fn writeEmptyInteriorPage(
    mutable: []u8,
    page_num: u32,
    page_size: usize,
    reserved: usize,
    right_most_pointer: u32,
) void {
    std.debug.assert(page_num != 1);
    const start: usize = (@as(usize, page_num) - 1) * page_size;
    // For a 0-cell page, `cell_content_start` is the end of the usable
    // area (cells would START there if any existed). SQLite's encoding
    // of `cell_content_start` reads a stored 0 as 65536, so for a
    // 65536-byte page we MUST store 0; for any smaller page size we
    // store the actual offset, otherwise integrity_check flags
    // "free space corruption" because SQLite thinks the cell content
    // area extends past the end of the page.
    const usable_end_rel: usize = page_size - reserved;
    const stored_content_start: u16 = if (usable_end_rel == 65536)
        0
    else
        @intCast(usable_end_rel);
    mutable[start + 0] = @intFromEnum(btree.PageType.table_interior);
    writeU16(mutable[start + 1 .. start + 3], 0); // first freeblock
    writeU16(mutable[start + 3 .. start + 5], 0); // cell_count
    writeU16(mutable[start + 5 .. start + 7], stored_content_start);
    mutable[start + 7] = 0; // fragmented free
    writeU32(mutable[start + 8 .. start + 12], right_most_pointer);
}

/// True iff the given `table_interior` page has enough free bytes to
/// hold one more divider cell of `divider_len` bytes plus its 2-byte
/// pointer-array slot. Cheap O(1) check on the page header — does no
/// allocation.
fn interiorHasRoomForDivider(
    image: []const u8,
    page_num: u32,
    page_size: usize,
    reserved: usize,
    divider_len: usize,
) bool {
    const start = (@as(usize, page_num) - 1) * page_size;
    const hdr_off: usize = if (page_num == 1) header.HEADER_SIZE else 0;
    const base = start + hdr_off;
    const usable_end = start + page_size - reserved;
    if (base + 12 > usable_end) return false;
    const cell_count = readU16(image[base + 3 .. base + 5]);
    const stored_content_start = readU16(image[base + 5 .. base + 7]);
    const content_start_abs: usize = if (stored_content_start == 0)
        start + page_size
    else
        start + stored_content_start;
    if (content_start_abs > usable_end) return false;
    const ptr_slot = base + 12 + @as(usize, cell_count) * 2;
    if (content_start_abs < divider_len) return false;
    const new_div_start = content_start_abs - divider_len;
    return new_div_start >= ptr_slot + 2;
}

/// Append `divider_cell` to an existing `table_interior` page, set its
/// right-most pointer to `new_right_most`, and update the page header
/// (cell_count, cell_content_start). The caller must have verified
/// space via `interiorHasRoomForDivider` first; this routine performs
/// no bounds checks.
fn appendInteriorDivider(
    mutable: []u8,
    page_num: u32,
    page_size: usize,
    reserved: usize,
    divider_cell: []const u8,
    new_right_most: u32,
) void {
    _ = reserved;
    const start = (@as(usize, page_num) - 1) * page_size;
    const hdr_off: usize = if (page_num == 1) header.HEADER_SIZE else 0;
    const base = start + hdr_off;
    const cell_count = readU16(mutable[base + 3 .. base + 5]);
    const stored_content_start = readU16(mutable[base + 5 .. base + 7]);
    const content_start_abs_old: usize = if (stored_content_start == 0)
        start + page_size
    else
        start + stored_content_start;
    const new_cell_start_abs = content_start_abs_old - divider_cell.len;
    @memcpy(mutable[new_cell_start_abs..][0..divider_cell.len], divider_cell);
    const new_cell_rel: u16 = @intCast(new_cell_start_abs - start);
    const ptr_slot = base + 12 + @as(usize, cell_count) * 2;
    writeU16(mutable[ptr_slot..][0..2], new_cell_rel);
    writeU16(mutable[base + 3 .. base + 5], cell_count + 1);
    writeU16(mutable[base + 5 .. base + 7], new_cell_rel);
    writeU32(mutable[base + 8 .. base + 12], new_right_most);
}

/// Stamp `page_num` (which may be the existing root page; the caller is
/// expected to have copied the old contents elsewhere first) as a fresh
/// `table_interior` containing exactly one divider cell, plus a
/// right-most pointer. Used by root promotion when the existing root
/// fills.
fn writeInteriorWithSingleDivider(
    mutable: []u8,
    page_num: u32,
    page_size: usize,
    reserved: usize,
    divider_cell: []const u8,
    right_most_pointer: u32,
) void {
    std.debug.assert(page_num != 1);
    const start: usize = (@as(usize, page_num) - 1) * page_size;
    const usable_end = start + page_size - reserved;
    const cell_off_abs = usable_end - divider_cell.len;
    @memcpy(mutable[cell_off_abs..][0..divider_cell.len], divider_cell);
    const cell_rel: u16 = @intCast(cell_off_abs - start);
    mutable[start + 0] = @intFromEnum(btree.PageType.table_interior);
    writeU16(mutable[start + 1 .. start + 3], 0); // first freeblock
    writeU16(mutable[start + 3 .. start + 5], 1); // cell_count
    writeU16(mutable[start + 5 .. start + 7], cell_rel); // cell_content_start
    mutable[start + 7] = 0; // fragmented free
    writeU32(mutable[start + 8 .. start + 12], right_most_pointer);
    writeU16(mutable[start + 12 .. start + 14], cell_rel); // pointer to cell 0
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

    var image = try MappedFile.open(io, db_path, .read_write);
    defer image.deinit();

    var rc = ReplayContext{ .gpa = gpa, .image = &image, .dirty = false };
    try wal.recover(io, 0, replayApply, &rc);

    // Persist the post-recovery image so the WAL entries we just replayed
    // are on stable storage before we checkpoint them away.
    if (rc.dirty) try image.syncAll();

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
fn resolveInsertRowid(gpa: Allocator, image: *MappedFile, table_name: []const u8, values: []const InsertValue) WriteError!i64 {
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
    image: *MappedFile,
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

fn applyUpdateCore(gpa: Allocator, image: *MappedFile, stmt: @import("ast.zig").UpdateStatement) WriteError!usize {
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

fn applyDeleteCore(gpa: Allocator, image: *MappedFile, stmt: @import("ast.zig").DeleteStatement) WriteError!usize {
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

/// Like `encodeVarint` but writes into the first bytes of `dst` instead
/// of a fixed-size array. `dst` must hold at least 9 bytes. Returns the
/// number of bytes written.
fn encodeVarintInto(dst: []u8, value: u64) usize {
    var buf: [9]u8 = undefined;
    const n = encodeVarint(&buf, value);
    @memcpy(dst[0..n], buf[0..n]);
    return n;
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
    image: *MappedFile,
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
    try image.resize(new_file_size);
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
        conn.image.deinit();
        conn.dirty_pages.deinit(testing.allocator);
        conn.scratch_arena.deinit();
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
