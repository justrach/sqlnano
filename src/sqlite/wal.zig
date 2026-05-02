//! sqlnano write-ahead log.
//!
//! On-disk format
//! --------------
//! A WAL file is a contiguous stream of 8-byte-aligned entries:
//!
//!     [ 32-byte header ][ payload (length bytes) ][ 0..7 zero pad ]
//!
//! The header is fixed 32 bytes:
//!
//!     u64  lsn          (1, 2, 3, ...; 0 means "no entry / tail garbage")
//!     u32  length       payload size in bytes
//!     u32  crc32        IEEE CRC over header[0..12] ++ four zero bytes
//!                       (where crc32 lives) ++ header[16..32] ++ payload
//!     u8   op           OpCode
//!     u8   db_tag       caller-defined byte (DB_TAG_SQLITE for sqlnano)
//!     u16  flags        bit 0 = FLAG_COMMIT
//!     u64  txn_id       transaction id; 0 reserved for non-txn ops
//!     u32  reserved     zero
//!
//! Payload semantics are op-specific; this module is intentionally agnostic
//! about row encoding. Higher layers serialise INSERT / UPDATE / DELETE
//! payloads however they like and pass opaque bytes through `write`.
//!
//! Group commit
//! ------------
//! Every `write` call appends header+payload+pad to a shared in-memory buffer
//! protected by `mu`. `commit` writes a `txn_commit` record, then either:
//!   * observes that the desired LSN is already durable and returns; or
//!   * sees an in-progress flush and waits on `cond`; or
//!   * elects itself flusher, snapshots the buffer under the lock, drops the
//!     lock, performs one positional write + one fsync, then broadcasts.
//!
//! This is the same shape as PostgreSQL group commit: one fsync amortises
//! across every commit that arrived in the flush window.
//!
//! Recovery
//! --------
//! `recover` runs in two passes:
//!   1. Walk the file collecting every txn_id that has a `txn_commit` (or
//!      FLAG_COMMIT) entry. Stop on the first short read or CRC mismatch
//!      and remember that offset as `valid_end` — anything after it is
//!      partial-write garbage and will be overwritten by the next append.
//!   2. Walk again up to `valid_end`; for every entry whose txn_id is in the
//!      committed set and whose lsn is past the supplied checkpoint, invoke
//!      the user-provided apply callback. Control entries (txn_*, checkpoint)
//!      are skipped.

const std = @import("std");

pub const HEADER_SIZE: usize = 32;
pub const FLAG_COMMIT: u16 = 0x0001;

/// Caller-supplied tag distinguishing "which engine wrote this entry".
/// sqlnano uses 0x10; pick a different value if you ever multiplex other
/// engines into the same WAL file.
pub const DB_TAG_SQLITE: u8 = 0x10;

pub const OpCode = enum(u8) {
    nop = 0x00,
    txn_begin = 0x40,
    txn_commit = 0x41,
    txn_abort = 0x42,
    checkpoint = 0xF0,
    row_insert = 0x10,
    row_update = 0x11,
    row_delete = 0x12,
    /// Reserved for the upcoming physical-page WAL: a full page image.
    page_image = 0x20,
    _,
};

pub const Entry = struct {
    lsn: u64,
    txn_id: u64,
    op: OpCode,
    db_tag: u8,
    flags: u16,
    /// Borrowed slice into the recovery buffer; valid only for the duration
    /// of the apply callback.
    payload: []const u8,
};

pub const ApplyFn = *const fn (entry: Entry, ctx: ?*anyopaque) anyerror!void;

const HeaderRaw = extern struct {
    lsn: u64 align(1),
    length: u32 align(1),
    crc32: u32 align(1),
    op: u8,
    db_tag: u8,
    flags: u16 align(1),
    txn_id: u64 align(1),
    reserved: u32 align(1),

    comptime {
        std.debug.assert(@sizeOf(HeaderRaw) == HEADER_SIZE);
        std.debug.assert(@alignOf(HeaderRaw) == 1);
    }
};

inline fn paddingTo8(n: usize) usize {
    return (8 - (n & 7)) & 7;
}

fn entryChecksum(header_bytes: []const u8, payload: []const u8) u32 {
    std.debug.assert(header_bytes.len == HEADER_SIZE);
    var h = std.hash.crc.Crc32.init();
    h.update(header_bytes[0..12]); // lsn + length
    h.update(&[_]u8{ 0, 0, 0, 0 }); // crc32 substituted with zeros
    h.update(header_bytes[16..]); // op .. reserved
    h.update(payload);
    return h.final();
}

/// Mirrors SQLite's `PRAGMA synchronous`:
///   * `.full`   — fsync after every commit AND every checkpoint.
///     Power-loss safe. Default.
///   * `.normal` — fsync only on checkpoint. Commits return after
///     `write(2)` but before `fsync(2)`; an OS crash is safe but
///     hard power loss can lose the last window of commits. This is
///     what SQLite WAL+NORMAL does and is where SQLite's real
///     throughput numbers come from.
///   * `.off`    — never fsync. Data may be lost on any crash.
pub const SyncMode = enum { full, normal, off };

pub const Wal = struct {
    file: std.Io.File,
    write_buf: std.ArrayList(u8),
    /// Number of bytes already on disk. Advanced under `mu` whenever a
    /// flusher claims a chunk of `write_buf`.
    end_offset: u64,
    next_lsn: std.atomic.Value(u64),
    /// LSN of the last `checkpoint` record successfully written; bytes up
    /// through that LSN may be discarded by callers that maintain a
    /// separate canonical data file.
    checkpoint_lsn: u64,
    /// Highest LSN known to be on durable storage.
    synced_lsn: u64,
    /// Chosen durability mode. See `SyncMode`.
    sync_mode: SyncMode,

    mu: std.Io.Mutex,
    cond: std.Io.Condition,
    flushing: bool,

    allocator: std.mem.Allocator,

    /// Open or create a WAL file at `path` relative to `dir`. Recovery is
    /// *not* run here; call `recover` once you have the apply callback ready.
    pub fn open(dir: std.Io.Dir, io: std.Io, allocator: std.mem.Allocator, path: []const u8) !Wal {
        const file = dir.openFile(io, path, .{ .mode = .read_write }) catch |err| switch (err) {
            error.FileNotFound => try dir.createFile(io, path, .{
                .read = true,
                .truncate = false,
                .exclusive = false,
            }),
            else => return err,
        };
        const stat = try file.stat(io);
        return .{
            .file = file,
            .write_buf = .empty,
            .end_offset = stat.size,
            .next_lsn = std.atomic.Value(u64).init(1),
            .checkpoint_lsn = 0,
            .synced_lsn = 0,
            .sync_mode = .full,
            .mu = .init,
            .cond = .init,
            .flushing = false,
            .allocator = allocator,
        };
    }

    pub fn close(self: *Wal, io: std.Io) void {
        self.flushPending(io) catch {};
        self.write_buf.deinit(self.allocator);
        self.file.close(io);
    }

    pub const CompactError = error{
        WalHasPendingWrites,
        WalHasUncheckpointedCommits,
        TruncateFailed,
    };

    /// Truncate the WAL file to zero bytes and reset the in-memory counters.
    /// Only legal when every committed entry has been covered by a
    /// checkpoint *and* the in-memory write buffer is empty — i.e. every
    /// recorded mutation has been applied to its canonical data store and
    /// reflected by a `checkpoint` barrier. The write paths in
    /// `write.zig` ensure this by calling `commit` → apply → `checkpoint`
    /// before invoking `compact`.
    ///
    /// On return, the next `write` will start at LSN 1 again, and a future
    /// `recover` on this file is a no-op.
    pub fn compact(self: *Wal, io: std.Io) (CompactError || error{Canceled})!void {
        self.mu.lockUncancelable(io);
        defer self.mu.unlock(io);
        while (self.flushing) self.cond.waitUncancelable(io, &self.mu);

        if (self.write_buf.items.len > 0) return error.WalHasPendingWrites;
        if (self.synced_lsn > self.checkpoint_lsn) return error.WalHasUncheckpointedCommits;
        if (self.end_offset == 0) return; // already empty

        const rc = std.c.ftruncate(self.file.handle, 0);
        if (rc != 0) return error.TruncateFailed;
        // Best-effort fsync after truncate so the empty length is durable.
        self.file.sync(io) catch {};

        self.end_offset = 0;
        self.next_lsn.store(1, .release);
        self.synced_lsn = 0;
        self.checkpoint_lsn = 0;
    }

    /// Append an entry to the in-memory buffer and return its LSN. The entry
    /// is *not* durable until the next successful `commit`, `checkpoint`, or
    /// `flushPending` call.
    pub fn write(
        self: *Wal,
        io: std.Io,
        txn_id: u64,
        op: OpCode,
        db_tag: u8,
        flags: u16,
        payload: []const u8,
    ) !u64 {
        if (payload.len > std.math.maxInt(u32)) return error.PayloadTooLarge;

        const lsn = self.next_lsn.fetchAdd(1, .monotonic);
        const pad = paddingTo8(HEADER_SIZE + payload.len);

        var hdr = HeaderRaw{
            .lsn = lsn,
            .length = @intCast(payload.len),
            .crc32 = 0,
            .op = @intFromEnum(op),
            .db_tag = db_tag,
            .flags = flags,
            .txn_id = txn_id,
            .reserved = 0,
        };
        const hdr_bytes = std.mem.asBytes(&hdr);
        hdr.crc32 = entryChecksum(hdr_bytes, payload);

        self.mu.lockUncancelable(io);
        defer self.mu.unlock(io);
        try self.write_buf.appendSlice(self.allocator, std.mem.asBytes(&hdr));
        try self.write_buf.appendSlice(self.allocator, payload);
        if (pad != 0) try self.write_buf.appendNTimes(self.allocator, 0, pad);
        return lsn;
    }

    /// Best-effort flush. Returns immediately if nothing is pending or if
    /// another caller is currently flushing. Useful for an idle background
    /// thread; transactional callers should use `commit` instead.
    pub fn flushPending(self: *Wal, io: std.Io) !void {
        self.mu.lockUncancelable(io);
        if (self.write_buf.items.len == 0 or self.flushing) {
            self.mu.unlock(io);
            return;
        }
        // Best-effort idle flush — honor sync_mode rather than forcing.
        try self.flushAndUnlock(io, false);
    }

    /// Append a `txn_commit` record and block until it is durable.
    /// First arrival on the commit path becomes the flusher; everyone else
    /// waits on `cond`.
    pub fn commit(self: *Wal, io: std.Io, txn_id: u64, db_tag: u8) !void {
        var payload: [16]u8 = undefined;
        std.mem.writeInt(u64, payload[0..8], txn_id, .little);
        std.mem.writeInt(u64, payload[8..16], 0, .little); // reserved (timestamp slot)
        const lsn = try self.write(io, txn_id, .txn_commit, db_tag, FLAG_COMMIT, &payload);

        self.mu.lockUncancelable(io);
        if (self.synced_lsn >= lsn) {
            self.mu.unlock(io);
            return;
        }
        if (self.flushing) {
            while (self.synced_lsn < lsn) self.cond.waitUncancelable(io, &self.mu);
            self.mu.unlock(io);
            return;
        }
        // Commit path: let `sync_mode` decide whether to fsync. `.full`
        // fsyncs here (one fsync per commit); `.normal` and `.off` skip
        // and rely on checkpoint for durability.
        try self.flushAndUnlock(io, false);
    }

    /// Force-flush the current buffer (waiting if another flush is in
    /// progress) and write a `checkpoint` barrier whose LSN becomes the new
    /// `checkpoint_lsn`. Higher layers should call this *after* successfully
    /// applying everything up to this point to the canonical data file.
    pub fn checkpoint(self: *Wal, io: std.Io, db_tag: u8) !void {
        var payload: [8]u8 = undefined;
        std.mem.writeInt(u64, &payload, self.checkpoint_lsn, .little);
        const lsn = try self.write(io, 0, .checkpoint, db_tag, FLAG_COMMIT, &payload);

        self.mu.lockUncancelable(io);
        while (self.flushing) self.cond.waitUncancelable(io, &self.mu);
        if (self.write_buf.items.len == 0) {
            self.mu.unlock(io);
            self.checkpoint_lsn = lsn;
            return;
        }
        // Checkpoint: force fsync unless explicitly `.off`. This is the
        // durability boundary for `.normal` mode.
        try self.flushAndUnlock(io, self.sync_mode != .off);
        self.checkpoint_lsn = lsn;
    }

    /// Caller must hold `mu`. On return the lock has been released and any
    /// I/O error from the flush has been raised. `must_sync` overrides the
    /// current `sync_mode` when callers absolutely need disk durability
    /// (e.g. checkpoint or close). When false, we still honor `sync_mode`:
    /// `.full` syncs, `.normal`/`.off` skip the fsync.
    fn flushAndUnlock(self: *Wal, io: std.Io, must_sync: bool) !void {
        self.flushing = true;
        var to_write = self.write_buf;
        self.write_buf = .empty;
        const target = self.next_lsn.load(.monotonic) -| 1;
        const off = self.end_offset;
        self.end_offset += to_write.items.len;
        const should_sync = must_sync or (self.sync_mode == .full);
        self.mu.unlock(io);

        var io_err: ?anyerror = null;
        self.file.writePositionalAll(io, to_write.items, off) catch |e| {
            io_err = e;
        };
        to_write.deinit(self.allocator);
        if (io_err == null and should_sync) {
            self.file.sync(io) catch |e| {
                io_err = e;
            };
        }

        self.mu.lockUncancelable(io);
        if (io_err == null) self.synced_lsn = target;
        self.flushing = false;
        self.cond.broadcast(io);
        self.mu.unlock(io);

        if (io_err) |e| return e;
    }

    /// Replay durable entries through `apply_fn`. Skips entries with
    /// `lsn <= skip_before_lsn` so a caller that has already applied through
    /// some checkpoint can start from there. Control entries
    /// (`txn_begin/commit/abort`, `checkpoint`) are never replayed.
    ///
    /// On return the WAL's append cursor has been positioned past the last
    /// fully-valid entry; any partial trailing entry will be overwritten by
    /// the next `write`.
    pub fn recover(
        self: *Wal,
        io: std.Io,
        skip_before_lsn: u64,
        apply_fn: ApplyFn,
        ctx: ?*anyopaque,
    ) !void {
        if (self.end_offset == 0) return;

        const size: usize = std.math.cast(usize, self.end_offset) orelse return error.WalTooLarge;
        const buf = try self.allocator.alloc(u8, size);
        defer self.allocator.free(buf);
        const n = try self.file.readPositionalAll(io, buf, 0);
        const data = buf[0..n];

        var committed = std.AutoHashMap(u64, void).init(self.allocator);
        defer committed.deinit();
        var max_lsn: u64 = 0;
        var latest_checkpoint: u64 = 0;
        const valid_end = scanCommitted(data, &committed, &max_lsn, &latest_checkpoint) catch |e| return e;

        const effective_skip = @max(skip_before_lsn, latest_checkpoint);

        var pos: usize = 0;
        while (pos < valid_end) {
            const hdr_bytes = data[pos..][0..HEADER_SIZE];
            const hdr: *const HeaderRaw = @ptrCast(hdr_bytes.ptr);
            const len: usize = hdr.length;
            const total = HEADER_SIZE + len + paddingTo8(HEADER_SIZE + len);
            const payload = data[pos + HEADER_SIZE ..][0..len];
            const op_code: OpCode = @enumFromInt(hdr.op);
            const advance = total;

            const skip_control = switch (op_code) {
                .txn_begin, .txn_commit, .txn_abort, .checkpoint => true,
                else => false,
            };
            if (!skip_control and hdr.lsn > effective_skip and committed.contains(hdr.txn_id)) {
                try apply_fn(.{
                    .lsn = hdr.lsn,
                    .txn_id = hdr.txn_id,
                    .op = op_code,
                    .db_tag = hdr.db_tag,
                    .flags = hdr.flags,
                    .payload = payload,
                }, ctx);
            }
            pos += advance;
        }

        self.next_lsn.store(max_lsn + 1, .release);
        self.synced_lsn = max_lsn;
        self.checkpoint_lsn = latest_checkpoint;
        self.end_offset = valid_end;
    }
};

fn scanCommitted(
    data: []const u8,
    committed: *std.AutoHashMap(u64, void),
    max_lsn: *u64,
    latest_checkpoint: *u64,
) !usize {
    var pos: usize = 0;
    var valid_end: usize = 0;
    while (pos + HEADER_SIZE <= data.len) {
        const hdr_bytes = data[pos..][0..HEADER_SIZE];
        const hdr: *const HeaderRaw = @ptrCast(hdr_bytes.ptr);
        if (hdr.lsn == 0) break; // sentinel / zeroed tail
        const len: usize = hdr.length;
        const total = HEADER_SIZE + len + paddingTo8(HEADER_SIZE + len);
        if (pos + total > data.len) break; // partial trailing entry
        const payload = data[pos + HEADER_SIZE ..][0..len];
        if (entryChecksum(hdr_bytes, payload) != hdr.crc32) break; // corruption / torn write
        if (hdr.op == @intFromEnum(OpCode.txn_commit) or (hdr.flags & FLAG_COMMIT) != 0) {
            try committed.put(hdr.txn_id, {});
        }
        if (hdr.op == @intFromEnum(OpCode.checkpoint) and hdr.lsn > latest_checkpoint.*) {
            latest_checkpoint.* = hdr.lsn;
        }
        if (hdr.lsn > max_lsn.*) max_lsn.* = hdr.lsn;
        valid_end = pos + total;
        pos = valid_end;
    }
    return valid_end;
}

// ---------- tests ----------

const testing = std.testing;

const Captured = struct {
    list: std.ArrayList(struct {
        op: OpCode,
        txn_id: u64,
        lsn: u64,
        payload: []u8,
    }) = .empty,
    allocator: std.mem.Allocator,

    fn deinit(self: *Captured) void {
        for (self.list.items) |item| self.allocator.free(item.payload);
        self.list.deinit(self.allocator);
    }

    fn apply(entry: Entry, ctx: ?*anyopaque) anyerror!void {
        const self: *Captured = @ptrCast(@alignCast(ctx.?));
        const dup = try self.allocator.dupe(u8, entry.payload);
        try self.list.append(self.allocator, .{
            .op = entry.op,
            .txn_id = entry.txn_id,
            .lsn = entry.lsn,
            .payload = dup,
        });
    }
};

test "append, commit, recover replays committed entries" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = "wal.log";

    {
        var wal = try Wal.open(tmp.dir, testing.io, testing.allocator, path);
        defer wal.close(testing.io);
        _ = try wal.write(testing.io, 1, .row_insert, DB_TAG_SQLITE, 0, "row-1");
        _ = try wal.write(testing.io, 1, .row_insert, DB_TAG_SQLITE, 0, "row-2");
        try wal.commit(testing.io, 1, DB_TAG_SQLITE);

        // Uncommitted txn must be ignored on replay.
        _ = try wal.write(testing.io, 2, .row_delete, DB_TAG_SQLITE, 0, "row-uncommitted");
        try wal.flushPending(testing.io);
    }

    var captured = Captured{ .allocator = testing.allocator };
    defer captured.deinit();

    var wal = try Wal.open(tmp.dir, testing.io, testing.allocator, path);
    defer wal.close(testing.io);
    try wal.recover(testing.io, 0, Captured.apply, &captured);

    try testing.expectEqual(@as(usize, 2), captured.list.items.len);
    try testing.expectEqual(OpCode.row_insert, captured.list.items[0].op);
    try testing.expectEqualStrings("row-1", captured.list.items[0].payload);
    try testing.expectEqualStrings("row-2", captured.list.items[1].payload);
}

test "skip_before_lsn skips already-applied entries" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = "wal.log";

    var first_lsn: u64 = 0;
    {
        var wal = try Wal.open(tmp.dir, testing.io, testing.allocator, path);
        defer wal.close(testing.io);
        first_lsn = try wal.write(testing.io, 1, .row_insert, DB_TAG_SQLITE, 0, "first");
        _ = try wal.write(testing.io, 1, .row_insert, DB_TAG_SQLITE, 0, "second");
        try wal.commit(testing.io, 1, DB_TAG_SQLITE);
    }

    var captured = Captured{ .allocator = testing.allocator };
    defer captured.deinit();
    var wal = try Wal.open(tmp.dir, testing.io, testing.allocator, path);
    defer wal.close(testing.io);
    try wal.recover(testing.io, first_lsn, Captured.apply, &captured);

    try testing.expectEqual(@as(usize, 1), captured.list.items.len);
    try testing.expectEqualStrings("second", captured.list.items[0].payload);
}

test "torn-write tail is truncated on recovery" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = "wal.log";

    {
        var wal = try Wal.open(tmp.dir, testing.io, testing.allocator, path);
        defer wal.close(testing.io);
        _ = try wal.write(testing.io, 1, .row_insert, DB_TAG_SQLITE, 0, "good");
        try wal.commit(testing.io, 1, DB_TAG_SQLITE);
    }

    // Append garbage that will look like a partial header.
    {
        const file = try tmp.dir.openFile(testing.io, path, .{ .mode = .read_write });
        defer file.close(testing.io);
        const st = try file.stat(testing.io);
        try file.writePositionalAll(testing.io, "\xff\xff\xff\xff\xff\xff", st.size);
    }

    var captured = Captured{ .allocator = testing.allocator };
    defer captured.deinit();
    var wal = try Wal.open(tmp.dir, testing.io, testing.allocator, path);
    defer wal.close(testing.io);
    try wal.recover(testing.io, 0, Captured.apply, &captured);

    // Good entry should still replay; tail garbage ignored.
    try testing.expectEqual(@as(usize, 1), captured.list.items.len);
    try testing.expectEqualStrings("good", captured.list.items[0].payload);

    // And the next append should overwrite the garbage in place.
    _ = try wal.write(testing.io, 2, .row_insert, DB_TAG_SQLITE, 0, "after");
    try wal.commit(testing.io, 2, DB_TAG_SQLITE);
}

test "compact zeroes the file after a clean checkpoint" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = "wal.log";

    var wal = try Wal.open(tmp.dir, testing.io, testing.allocator, path);
    defer wal.close(testing.io);
    _ = try wal.write(testing.io, 1, .row_insert, DB_TAG_SQLITE, 0, "x");
    try wal.commit(testing.io, 1, DB_TAG_SQLITE);
    try wal.checkpoint(testing.io, DB_TAG_SQLITE);
    try testing.expect(wal.end_offset > 0);

    try wal.compact(testing.io);
    try testing.expectEqual(@as(u64, 0), wal.end_offset);
    try testing.expectEqual(@as(u64, 1), wal.next_lsn.load(.monotonic));

    // Subsequent writes start fresh at LSN 1 and round-trip through recover().
    _ = try wal.write(testing.io, 2, .row_insert, DB_TAG_SQLITE, 0, "after");
    try wal.commit(testing.io, 2, DB_TAG_SQLITE);
    try testing.expect(wal.end_offset > 0);

    var captured = Captured{ .allocator = testing.allocator };
    defer captured.deinit();
    var wal2 = try Wal.open(tmp.dir, testing.io, testing.allocator, path);
    defer wal2.close(testing.io);
    try wal2.recover(testing.io, 0, Captured.apply, &captured);
    try testing.expectEqual(@as(usize, 1), captured.list.items.len);
    try testing.expectEqualStrings("after", captured.list.items[0].payload);
}

test "compact refuses when commits are not checkpointed" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = "wal.log";

    var wal = try Wal.open(tmp.dir, testing.io, testing.allocator, path);
    defer wal.close(testing.io);
    _ = try wal.write(testing.io, 1, .row_insert, DB_TAG_SQLITE, 0, "x");
    try wal.commit(testing.io, 1, DB_TAG_SQLITE);
    // No checkpoint yet → must refuse.
    try testing.expectError(error.WalHasUncheckpointedCommits, wal.compact(testing.io));
}

test "checkpoint advances checkpoint_lsn and forces durability" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = "wal.log";

    var wal = try Wal.open(tmp.dir, testing.io, testing.allocator, path);
    defer wal.close(testing.io);
    _ = try wal.write(testing.io, 1, .row_insert, DB_TAG_SQLITE, 0, "x");
    try wal.commit(testing.io, 1, DB_TAG_SQLITE);
    const before = wal.checkpoint_lsn;
    try wal.checkpoint(testing.io, DB_TAG_SQLITE);
    try testing.expect(wal.checkpoint_lsn > before);
    try testing.expectEqual(wal.synced_lsn, wal.next_lsn.load(.monotonic) - 1);
}
