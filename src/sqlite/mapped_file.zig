//! File-backed memory region with an ArrayList-shaped API.
//!
//! The pre-existing sqlnano code kept the entire database file as an
//! `std.ArrayList(u8)` in memory. That made reads extremely fast (no
//! syscalls, no page-cache bounds checks) but meant a 10 GiB file
//! needed 10 GiB of RAM. `MappedFile` replaces the ArrayList with an
//! `mmap`-backed slice so:
//!
//!   * hot pages stay resident via the OS page cache,
//!   * cold pages are paged in on demand,
//!   * total RSS is bounded by what the workload actually touches,
//!   * the in-memory API (`items`, `resize`, `deinit`) matches what
//!     the existing write paths expect so the fast paths keep working
//!     with a one-line swap.
//!
//! Durability model: writes go directly into the mapped region
//! (`MAP_SHARED`), but they're only guaranteed to reach the disk when
//! the caller runs `msync(.sync)` on the affected range. sqlnano's
//! `Connection` still tracks dirty pages in a bitmap; on checkpoint
//! it either `msync`s the full file or, more commonly, calls
//! `syncPage` on each dirty page individually.
//!
//! Platform notes:
//!   * macOS does not implement `mremap`; `resize` falls back to
//!     `munmap` + `ftruncate` + `mmap` at the new length. All
//!     previously-taken slices into `items()` are invalidated by
//!     `resize`, same as `ArrayList.resize` reallocating its backing.
//!   * empty files can't be `mmap`ed. An opened-but-empty file keeps
//!     `len == 0` and `items()` returns an empty slice; the first
//!     `resize` above 0 performs the initial mmap.

const std = @import("std");
const builtin = @import("builtin");

const posix = std.posix;
const Io = std.Io;
const Allocator = std.mem.Allocator;

/// POSIX `MS_SYNC` flag. Zig's std exposes `posix.MSF` only on Linux;
/// on Darwin and the BSDs we supply the platform constants directly.
/// The value is the same across every POSIX platform we run on.
const MS_SYNC: i32 = switch (builtin.os.tag) {
    .linux => @as(i32, @intCast(@intFromEnum(std.posix.system.MSF.SYNC))),
    else => 0x10,
};

/// `madvise` advice codes. Linux and BSD/Darwin agree on the integer
/// values for the four hints we use, which is why we hardcode rather
/// than thread `posix.MADV` (whose tag spelling differs by platform).
pub const Advice = enum(u32) {
    normal = 0,
    random = 1,
    sequential = 2,
    willneed = 3,
};

pub const OpenMode = enum { read_only, read_write };

pub const MappedFile = struct {
    /// Underlying Zig Io file. Owned — closed on `deinit`.
    file: Io.File,
    /// Cached Io so `resize` / `syncAll` can issue filesystem ops
    /// without the caller having to thread it through every call.
    io: Io,
    /// Page-aligned backing slice. Used by `msync`, which requires a
    /// page-aligned pointer.
    map: []align(std.heap.page_size_min) u8,
    /// Byte-aligned view of `map` that matches
    /// `std.ArrayList(u8).items`. This is the slice callers mutate
    /// and hand to `PageReader.init`. Invalidated on every `resize`
    /// — cache-holding callers must re-fetch.
    items: []u8,
    mode: OpenMode,

    /// Open `path` relative to cwd and mmap the entire file. For
    /// read-only opens the mapping is `PROT_READ`; for read-write
    /// it's `PROT_READ | PROT_WRITE`. Creates the file if missing
    /// when opened read-write.
    pub fn open(io: Io, path: []const u8, mode: OpenMode) !MappedFile {
        const cwd = Io.Dir.cwd();
        const file = switch (mode) {
            .read_only => try cwd.openFile(io, path, .{ .mode = .read_only }),
            .read_write => cwd.openFile(io, path, .{ .mode = .read_write }) catch |err| switch (err) {
                error.FileNotFound => try cwd.createFile(io, path, .{
                    .read = true,
                    .truncate = false,
                    .exclusive = false,
                }),
                else => return err,
            },
        };
        return try fromFile(io, file, mode);
    }

    /// Adopt an already-opened `Io.File` and mmap its full extent.
    /// The returned `MappedFile` takes ownership of the file handle
    /// and closes it on `deinit`.
    pub fn fromFile(io: Io, file: Io.File, mode: OpenMode) !MappedFile {
        const stat = try file.stat(io);
        const len: u64 = stat.size;

        var self = MappedFile{
            .file = file,
            .io = io,
            .map = &.{},
            .items = &.{},
            .mode = mode,
        };
        if (len > 0) try self.mapFullFile(len);
        return self;
    }

    /// Close the file and release the mapping.
    pub fn deinit(self: *MappedFile) void {
        if (self.map.len > 0) posix.munmap(self.map);
        self.map = &.{};
        self.items = &.{};
        self.file.close(self.io);
    }

    /// Extend (or shrink) the underlying file and remap. After this
    /// call, the `items` slice is a fresh view — any previously-held
    /// pointer into it is invalid.
    pub fn resize(self: *MappedFile, new_len: u64) !void {
        if (self.mode != .read_write) return error.MappedFileReadOnly;
        if (new_len == self.items.len) return;

        try self.file.setLength(self.io, new_len);

        if (self.map.len > 0) {
            posix.munmap(self.map);
            self.map = &.{};
            self.items = &.{};
        }
        if (new_len > 0) try self.mapFullFile(new_len);
    }

    /// Byte length — same as `items.len`.
    pub fn length(self: *const MappedFile) u64 {
        return self.items.len;
    }

    /// `msync` a single page back to disk. `offset` and `size` are in
    /// bytes; the kernel aligns as needed. A no-op on read-only maps.
    pub fn syncRange(self: *MappedFile, offset: u64, size: u64) !void {
        if (self.mode != .read_write) return;
        if (self.map.len == 0) return;
        if (offset + size > self.map.len) return error.OutOfBounds;

        // `msync` requires the address to be page-aligned but accepts
        // arbitrary lengths. Round the offset down to the system page
        // boundary and extend the size to cover the overhang.
        const sys_page: u64 = @intCast(std.heap.page_size_min);
        const aligned_off: u64 = offset & ~(sys_page - 1);
        const aligned_end: u64 = ((offset + size + sys_page - 1) / sys_page) * sys_page;
        const clamped_end = @min(aligned_end, self.map.len);
        const slice_ptr = self.map.ptr + aligned_off;
        const slice = @as([*]align(std.heap.page_size_min) u8, @alignCast(slice_ptr))[0 .. clamped_end - aligned_off];
        try posix.msync(slice, MS_SYNC);
    }

    /// Flush the entire mapping — equivalent to `fsync(fd)` for this
    /// file's dirty pages, whether sqlnano owns the bitmap or not.
    pub fn syncAll(self: *MappedFile) !void {
        if (self.mode != .read_write) return;
        if (self.map.len == 0) return;
        try posix.msync(self.map, MS_SYNC);
    }

    /// Hint the kernel about access pattern over the entire mapping.
    /// `.sequential` enables aggressive readahead for table scans;
    /// `.willneed` triggers an immediate prefetch (kernel populates
    /// the page cache eagerly); `.random` disables readahead. We use
    /// these to close the cold-cache gap vs SQLite's pread-based
    /// pager, which gets readahead from the kernel for free.
    pub fn advise(self: *MappedFile, advice: Advice) !void {
        if (self.map.len == 0) return;
        try posix.madvise(self.map.ptr, self.map.len, @intFromEnum(advice));
    }

    pub fn adviseRange(self: *MappedFile, offset: u64, size: u64, advice: Advice) !void {
        if (self.map.len == 0) return;
        if (offset + size > self.map.len) return error.OutOfBounds;
        const sys_page: u64 = @intCast(std.heap.page_size_min);
        const aligned_off: u64 = offset & ~(sys_page - 1);
        const slice_ptr = self.map.ptr + aligned_off;
        const slice_len: usize = @intCast(@min(self.map.len - aligned_off, offset + size - aligned_off));
        try posix.madvise(@alignCast(slice_ptr), slice_len, @intFromEnum(advice));
    }

    fn mapFullFile(self: *MappedFile, new_len: u64) !void {
        std.debug.assert(new_len > 0);
        const prot: posix.PROT = switch (self.mode) {
            .read_only => .{ .READ = true },
            .read_write => .{ .READ = true, .WRITE = true },
        };
        const flags: posix.MAP = .{ .TYPE = .SHARED };
        const mapped = try posix.mmap(null, @intCast(new_len), prot, flags, self.file.handle, 0);
        self.map = mapped;
        self.items = mapped[0..@intCast(new_len)];
    }
};

test "mmap round-trip" {
    const io = std.testing.io;
    const path = "/tmp/sqlnano_mapped_file_test.bin";
    defer Io.Dir.cwd().deleteFile(io, path) catch {};

    {
        var mf = try MappedFile.open(io, path, .read_write);
        defer mf.deinit();
        try mf.resize(4096);
        @memset(mf.items[0..16], 0xAB);
        try mf.syncAll();
    }

    {
        var mf = try MappedFile.open(io, path, .read_only);
        defer mf.deinit();
        try std.testing.expectEqual(@as(usize, 4096), mf.items.len);
        for (mf.items[0..16]) |b| try std.testing.expectEqual(@as(u8, 0xAB), b);
    }
    _ = builtin;
}

test "resize grows and shrinks" {
    const io = std.testing.io;
    const path = "/tmp/sqlnano_mapped_file_resize.bin";
    defer Io.Dir.cwd().deleteFile(io, path) catch {};

    var mf = try MappedFile.open(io, path, .read_write);
    defer mf.deinit();

    try mf.resize(1024);
    try std.testing.expectEqual(@as(usize, 1024), mf.items.len);

    try mf.resize(8192);
    try std.testing.expectEqual(@as(usize, 8192), mf.items.len);

    try mf.resize(256);
    try std.testing.expectEqual(@as(usize, 256), mf.items.len);

    // Writes persist across resizes.
    mf.items[0] = 0x42;
    try mf.resize(4096);
    try std.testing.expectEqual(@as(u8, 0x42), mf.items[0]);
}
