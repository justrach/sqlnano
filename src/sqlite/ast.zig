const std = @import("std");
const write = @import("write.zig");

pub const Literal = union(enum) {
    integer: i64,
    text: []const u8,
    null,

    pub fn toInsertValue(self: Literal) write.InsertValue {
        return switch (self) {
            .integer => |value| .{ .integer = value },
            .text => |value| .{ .text = value },
            .null => .null,
        };
    }
};

pub const WhereClause = struct {
    column_name: []const u8,
    value: Literal,
};

pub const SelectStatement = struct {
    table_name: []const u8,
    where_clause: ?WhereClause = null,
};

pub const InsertStatement = struct {
    table_name: []const u8,
    values: []Literal,

    pub fn deinit(self: InsertStatement, allocator: std.mem.Allocator) void {
        allocator.free(self.values);
    }
};

pub const Assignment = struct {
    column_name: []const u8,
    value: Literal,
};

pub const UpdateStatement = struct {
    table_name: []const u8,
    assignment: Assignment,
    where_clause: WhereClause,
};

pub const DeleteStatement = struct {
    table_name: []const u8,
    where_clause: WhereClause,
};

test "literal converts to insert value" {
    try std.testing.expectEqual(@as(i64, 42), (Literal{ .integer = 42 }).toInsertValue().integer);
    try std.testing.expectEqualStrings("alice", (Literal{ .text = "alice" }).toInsertValue().text);
    try std.testing.expect((Literal{ .null = {} }).toInsertValue() == .null);
}
