const std = @import("std");
const ast = @import("ast.zig");
const tokenizer = @import("tokenizer.zig");

pub const ParseError = error{
    OutOfMemory,
    InvalidSql,
    InvalidSelect,
    InvalidInsert,
    UnsupportedSql,
    UnsupportedSelect,
    UnsupportedInsert,
    UnsupportedUpdate,
    UnsupportedDelete,
    UnsupportedWhere,
};

pub const Statement = union(enum) {
    select: ast.SelectStatement,
    insert: ast.InsertStatement,
    update: ast.UpdateStatement,
    delete: ast.DeleteStatement,

    pub fn deinit(self: Statement, allocator: std.mem.Allocator) void {
        switch (self) {
            .select => {},
            .insert => |insert| insert.deinit(allocator),
            .update => {},
            .delete => {},
        }
    }
};

pub const Parser = struct {
    stream: tokenizer.TokenStream,

    pub fn init(sql: []const u8) ParseError!Parser {
        return .{ .stream = tokenizer.TokenStream.init(sql) catch return error.InvalidSql };
    }

    pub fn parseStatement(self: *Parser, allocator: std.mem.Allocator) ParseError!Statement {
        const statement: Statement = if (self.stream.current.isKeyword(.select))
            .{ .select = try self.parseSelect() }
        else if (self.stream.current.isKeyword(.insert))
            .{ .insert = try self.parseInsert(allocator) }
        else if (self.stream.current.isKeyword(.update))
            .{ .update = try self.parseUpdate() }
        else if (self.stream.current.isKeyword(.delete))
            .{ .delete = try self.parseDelete() }
        else
            return error.UnsupportedSql;
        _ = try self.consume(.semicolon);
        try self.expectEof();
        return statement;
    }

    pub fn parseSelect(self: *Parser) ParseError!ast.SelectStatement {
        try self.expectKeyword(.select, error.InvalidSelect);
        try self.expect(.star, error.UnsupportedSelect);
        try self.expectKeyword(.from, error.InvalidSelect);
        const table_name = try self.identifier(error.InvalidSelect);
        var where_clause: ?ast.WhereClause = null;
        if (try self.consumeKeyword(.where)) {
            const column_name = try self.identifier(error.UnsupportedWhere);
            try self.expect(.equals, error.UnsupportedWhere);
            const lit = try self.literal(error.UnsupportedWhere);
            where_clause = .{ .column_name = column_name, .value = lit };
        }
        return .{ .table_name = table_name, .where_clause = where_clause };
    }

    pub fn parseInsert(self: *Parser, allocator: std.mem.Allocator) ParseError!ast.InsertStatement {
        try self.expectKeyword(.insert, error.InvalidInsert);
        try self.expectKeyword(.into, error.InvalidInsert);
        const table_name = try self.identifier(error.InvalidInsert);
        try self.expectKeyword(.values, error.UnsupportedInsert);
        try self.expect(.left_paren, error.InvalidInsert);

        var values: std.ArrayList(ast.Literal) = .empty;
        errdefer values.deinit(allocator);

        if (try self.consume(.right_paren) == null) {
            while (true) {
                try values.append(allocator, try self.literal(error.InvalidInsert));
                if (try self.consume(.comma) != null) continue;
                try self.expect(.right_paren, error.InvalidInsert);
                break;
            }
        }

        return .{ .table_name = table_name, .values = try values.toOwnedSlice(allocator) };
    }

    pub fn parseUpdate(self: *Parser) ParseError!ast.UpdateStatement {
        try self.expectKeyword(.update, error.UnsupportedUpdate);
        const table_name = try self.identifier(error.UnsupportedUpdate);
        try self.expectKeyword(.set, error.UnsupportedUpdate);
        const assignment_column = try self.identifier(error.UnsupportedUpdate);
        try self.expect(.equals, error.UnsupportedUpdate);
        const assignment_value = try self.literal(error.UnsupportedUpdate);
        try self.expectKeyword(.where, error.UnsupportedWhere);
        return .{
            .table_name = table_name,
            .assignment = .{ .column_name = assignment_column, .value = assignment_value },
            .where_clause = try self.parseWhereClause(),
        };
    }

    pub fn parseDelete(self: *Parser) ParseError!ast.DeleteStatement {
        try self.expectKeyword(.delete, error.UnsupportedDelete);
        try self.expectKeyword(.from, error.UnsupportedDelete);
        const table_name = try self.identifier(error.UnsupportedDelete);
        try self.expectKeyword(.where, error.UnsupportedWhere);
        return .{ .table_name = table_name, .where_clause = try self.parseWhereClause() };
    }

    fn parseWhereClause(self: *Parser) ParseError!ast.WhereClause {
        const column_name = try self.identifier(error.UnsupportedWhere);
        try self.expect(.equals, error.UnsupportedWhere);
        const lit = try self.literal(error.UnsupportedWhere);
        return .{ .column_name = column_name, .value = lit };
    }

    fn expectKeyword(self: *Parser, keyword: tokenizer.Keyword, err: ParseError) ParseError!void {
        if (!try self.consumeKeyword(keyword)) return err;
    }

    fn consumeKeyword(self: *Parser, keyword: tokenizer.Keyword) ParseError!bool {
        return self.stream.consumeKeyword(keyword) catch return error.InvalidSql;
    }

    fn expect(self: *Parser, kind: tokenizer.Kind, err: ParseError) ParseError!void {
        if (try self.consume(kind) == null) return err;
    }

    fn consume(self: *Parser, kind: tokenizer.Kind) ParseError!?tokenizer.Token {
        return self.stream.consume(kind) catch return error.InvalidSql;
    }

    fn expectEof(self: *Parser) ParseError!void {
        if (self.stream.current.kind != .eof) return error.UnsupportedSql;
    }

    fn identifier(self: *Parser, err: ParseError) ParseError![]const u8 {
        const token = self.stream.current;
        const text = token.identifierText() orelse return err;
        self.stream.advance() catch return error.InvalidSql;
        return text;
    }

    fn literal(self: *Parser, err: ParseError) ParseError!ast.Literal {
        const token = self.stream.current;
        switch (token.kind) {
            .string => {
                self.stream.advance() catch return error.InvalidSql;
                return .{ .text = token.lexeme };
            },
            .integer => {
                self.stream.advance() catch return error.InvalidSql;
                return .{ .integer = std.fmt.parseInt(i64, token.lexeme, 10) catch return err };
            },
            .keyword => if (token.keyword == .null) {
                self.stream.advance() catch return error.InvalidSql;
                return .null;
            },
            else => {},
        }
        return err;
    }
};

pub fn parseStatement(sql: []const u8, allocator: std.mem.Allocator) ParseError!Statement {
    var parser = try Parser.init(sql);
    return parser.parseStatement(allocator);
}

pub fn parseSelect(sql: []const u8) ParseError!ast.SelectStatement {
    var parser = try Parser.init(sql);
    const select = try parser.parseSelect();
    _ = try parser.consume(.semicolon);
    try parser.expectEof();
    return select;
}

pub fn parseInsert(sql: []const u8, allocator: std.mem.Allocator) ParseError!ast.InsertStatement {
    var parser = try Parser.init(sql);
    const insert = try parser.parseInsert(allocator);
    errdefer insert.deinit(allocator);
    _ = try parser.consume(.semicolon);
    try parser.expectEof();
    return insert;
}

test "parse basic select" {
    const stmt = try parseSelect("SELECT * FROM users WHERE rowid = 1;");
    try std.testing.expectEqualStrings("users", stmt.table_name);
    try std.testing.expectEqualStrings("rowid", stmt.where_clause.?.column_name);
    try std.testing.expectEqual(@as(i64, 1), stmt.where_clause.?.value.integer);
}

test "parse quoted text where" {
    const stmt = try parseSelect("select * from users where name = 'alice'");
    try std.testing.expectEqualStrings("users", stmt.table_name);
    try std.testing.expectEqualStrings("alice", stmt.where_clause.?.value.text);
}

test "parse quoted identifier and comments" {
    const stmt = try parseSelect("-- leading comment\nselect * from [user table] where `name` = 'alice';");
    try std.testing.expectEqualStrings("user table", stmt.table_name);
    try std.testing.expectEqualStrings("name", stmt.where_clause.?.column_name);
}

test "parse insert values" {
    const stmt = try parseInsert("INSERT INTO users VALUES (1, 'alice', NULL);", std.testing.allocator);
    defer stmt.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("users", stmt.table_name);
    try std.testing.expectEqual(@as(usize, 3), stmt.values.len);
    try std.testing.expectEqual(@as(i64, 1), stmt.values[0].integer);
    try std.testing.expectEqualStrings("alice", stmt.values[1].text);
    try std.testing.expect(stmt.values[2] == .null);
}

test "parse statement dispatch" {
    const stmt = try parseStatement("INSERT INTO users VALUES (2, 'bob');", std.testing.allocator);
    defer stmt.deinit(std.testing.allocator);
    try std.testing.expect(stmt == .insert);
    try std.testing.expectEqualStrings("users", stmt.insert.table_name);
}
