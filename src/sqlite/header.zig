const std = @import("std");

pub const MAGIC = "SQLite format 3\x00";
pub const HEADER_SIZE: usize = 100;

pub const HeaderError = error{
    TooSmall,
    BadMagic,
    InvalidPageSize,
    InvalidWriteVersion,
    InvalidReadVersion,
    InvalidReservedSpace,
    InvalidPayloadFractions,
};

pub const JournalVersion = enum(u8) {
    legacy = 1,
    wal = 2,

    pub fn fromByte(value: u8) HeaderError!JournalVersion {
        return switch (value) {
            1 => .legacy,
            2 => .wal,
            else => error.InvalidReadVersion,
        };
    }
};

pub const Header = struct {
    page_size: u32,
    write_version: JournalVersion,
    read_version: JournalVersion,
    reserved_space: u8,
    max_payload_fraction: u8,
    min_payload_fraction: u8,
    leaf_payload_fraction: u8,
    file_change_counter: u32,
    database_page_count: u32,
    first_freelist_trunk_page: u32,
    freelist_page_count: u32,
    schema_cookie: u32,
    schema_format: u32,
    default_page_cache_size: u32,
    largest_root_btree_page: u32,
    text_encoding: u32,
    user_version: u32,
    incremental_vacuum: u32,
    application_id: u32,
    version_valid_for: u32,
    sqlite_version_number: u32,

    pub fn parse(bytes: []const u8) HeaderError!Header {
        if (bytes.len < HEADER_SIZE) return error.TooSmall;
        if (!std.mem.eql(u8, bytes[0..16], MAGIC)) return error.BadMagic;

        const page_size = parsePageSize(bytes[16..18].*);
        if (!validPageSize(page_size)) return error.InvalidPageSize;

        const write_version = JournalVersion.fromByte(bytes[18]) catch return error.InvalidWriteVersion;
        const read_version = JournalVersion.fromByte(bytes[19]) catch return error.InvalidReadVersion;

        const reserved_space = bytes[20];
        if (reserved_space > page_size - 480) return error.InvalidReservedSpace;

        const max_payload_fraction = bytes[21];
        const min_payload_fraction = bytes[22];
        const leaf_payload_fraction = bytes[23];
        if (max_payload_fraction != 64 or min_payload_fraction != 32 or leaf_payload_fraction != 32) {
            return error.InvalidPayloadFractions;
        }

        return .{
            .page_size = page_size,
            .write_version = write_version,
            .read_version = read_version,
            .reserved_space = reserved_space,
            .max_payload_fraction = max_payload_fraction,
            .min_payload_fraction = min_payload_fraction,
            .leaf_payload_fraction = leaf_payload_fraction,
            .file_change_counter = readU32(bytes[24..28]),
            .database_page_count = readU32(bytes[28..32]),
            .first_freelist_trunk_page = readU32(bytes[32..36]),
            .freelist_page_count = readU32(bytes[36..40]),
            .schema_cookie = readU32(bytes[40..44]),
            .schema_format = readU32(bytes[44..48]),
            .default_page_cache_size = readU32(bytes[48..52]),
            .largest_root_btree_page = readU32(bytes[52..56]),
            .text_encoding = readU32(bytes[56..60]),
            .user_version = readU32(bytes[60..64]),
            .incremental_vacuum = readU32(bytes[64..68]),
            .application_id = readU32(bytes[68..72]),
            .version_valid_for = readU32(bytes[92..96]),
            .sqlite_version_number = readU32(bytes[96..100]),
        };
    }

    pub fn isWal(self: Header) bool {
        return self.write_version == .wal or self.read_version == .wal;
    }
};

pub fn isSQLiteDatabase(bytes: []const u8) bool {
    _ = Header.parse(bytes) catch return false;
    return true;
}

fn parsePageSize(raw: [2]u8) u32 {
    const value = std.mem.readInt(u16, &raw, .big);
    return if (value == 1) 65536 else value;
}

fn validPageSize(page_size: u32) bool {
    return page_size >= 512 and page_size <= 65536 and std.math.isPowerOfTwo(page_size);
}

fn readU32(bytes: []const u8) u32 {
    return std.mem.readInt(u32, bytes[0..4], .big);
}

test "parse valid minimal SQLite header" {
    var bytes = [_]u8{0} ** HEADER_SIZE;
    @memcpy(bytes[0..16], MAGIC);
    bytes[16] = 0x10;
    bytes[17] = 0x00;
    bytes[18] = 1;
    bytes[19] = 1;
    bytes[20] = 0;
    bytes[21] = 64;
    bytes[22] = 32;
    bytes[23] = 32;
    bytes[56] = 0;
    bytes[57] = 0;
    bytes[58] = 0;
    bytes[59] = 1;

    const header = try Header.parse(&bytes);
    try std.testing.expectEqual(@as(u32, 4096), header.page_size);
    try std.testing.expectEqual(JournalVersion.legacy, header.write_version);
    try std.testing.expectEqual(JournalVersion.legacy, header.read_version);
    try std.testing.expectEqual(@as(u32, 1), header.text_encoding);
    try std.testing.expect(!header.isWal());
    try std.testing.expect(isSQLiteDatabase(&bytes));
}

test "parse 65536 byte page marker" {
    var bytes = [_]u8{0} ** HEADER_SIZE;
    @memcpy(bytes[0..16], MAGIC);
    bytes[16] = 0;
    bytes[17] = 1;
    bytes[18] = 2;
    bytes[19] = 2;
    bytes[21] = 64;
    bytes[22] = 32;
    bytes[23] = 32;

    const header = try Header.parse(&bytes);
    try std.testing.expectEqual(@as(u32, 65536), header.page_size);
    try std.testing.expect(header.isWal());
}

test "reject bad magic" {
    var bytes = [_]u8{0} ** HEADER_SIZE;
    try std.testing.expectError(error.BadMagic, Header.parse(&bytes));
    try std.testing.expect(!isSQLiteDatabase(&bytes));
}

test "reject invalid page size" {
    var bytes = [_]u8{0} ** HEADER_SIZE;
    @memcpy(bytes[0..16], MAGIC);
    bytes[16] = 0x03;
    bytes[17] = 0x00;
    bytes[18] = 1;
    bytes[19] = 1;
    bytes[21] = 64;
    bytes[22] = 32;
    bytes[23] = 32;

    try std.testing.expectError(error.InvalidPageSize, Header.parse(&bytes));
}
