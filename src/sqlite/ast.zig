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

/// Single-predicate WHERE used by UPDATE/DELETE. SELECT uses the
/// richer `Expr` tree below.
pub const WhereClause = struct {
    column_name: []const u8,
    value: Literal,
};

pub const ColumnRef = struct {
    /// Optional table-name or alias prefix, e.g. the `c` in `c.ticker`.
    qualifier: ?[]const u8 = null,
    name: []const u8,
};

pub const BinOp = enum {
    eq,
    ne,
    lt,
    le,
    gt,
    ge,
    and_,
    or_,
    is_null,
    is_not_null,
};

/// Boolean / comparison expression tree used by SELECT's WHERE and
/// JOIN-ON clauses. Allocated out of the caller's allocator; free
/// with `freeExpr` (or drop a shared arena).
pub const Expr = union(enum) {
    literal: Literal,
    column: ColumnRef,
    binary: struct {
        op: BinOp,
        lhs: *Expr,
        rhs: *Expr,
    },
    unary: struct {
        op: BinOp, // only `is_null` / `is_not_null` are meaningful here
        operand: *Expr,
    },
};

pub fn freeExpr(expr: *Expr, allocator: std.mem.Allocator) void {
    switch (expr.*) {
        .literal, .column => {},
        .binary => |bin| {
            freeExpr(bin.lhs, allocator);
            freeExpr(bin.rhs, allocator);
        },
        .unary => |u| freeExpr(u.operand, allocator),
    }
    allocator.destroy(expr);
}

pub const Projection = union(enum) {
    /// `SELECT *` or a bare `*` after a table-star.
    star,
    /// `SELECT t.*`
    table_star: []const u8,
    /// `SELECT col`, `SELECT t.col [AS alias]`
    column: struct {
        ref: ColumnRef,
        alias: ?[]const u8 = null,
    },
    /// `COUNT(*)`
    count_star: struct {
        alias: ?[]const u8 = null,
    },
};

pub const JoinKind = enum { inner };

pub const JoinClause = struct {
    kind: JoinKind,
    table_name: []const u8,
    alias: ?[]const u8 = null,
    on: *Expr,
};

pub const OrderBy = struct {
    column: ColumnRef,
    descending: bool = false,
};

/// A parsed SELECT. Memory:
///
///   * `projections` is allocated with the caller's allocator.
///   * `joins` is allocated with the caller's allocator.
///   * `where_expr` and each join's `on` are heap-allocated expression
///     trees (see `freeExpr`).
///   * `table_name`, `table_alias`, and every `[]const u8` below
///     borrow slices from the original SQL source.
///
/// Call `SelectStatement.deinit(allocator)` to release everything.
pub const SelectStatement = struct {
    projections: []Projection,
    table_name: []const u8,
    table_alias: ?[]const u8 = null,
    joins: []JoinClause = &.{},
    where_expr: ?*Expr = null,
    order_by: ?OrderBy = null,
    limit: ?i64 = null,

    pub fn deinit(self: SelectStatement, allocator: std.mem.Allocator) void {
        for (self.joins) |j| freeExpr(j.on, allocator);
        allocator.free(self.joins);
        allocator.free(self.projections);
        if (self.where_expr) |w| freeExpr(w, allocator);
    }
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
