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
            .select => |sel| sel.deinit(allocator),
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
            .{ .select = try self.parseSelect(allocator) }
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

    /// Grammar (informal, see ast.SelectStatement):
    ///
    ///   select_stmt := SELECT projections FROM table_ref (join_clause)*
    ///                  (WHERE expr)? (ORDER BY col_ref (ASC|DESC)?)?
    ///                  (LIMIT integer)?
    ///   projections := '*' | projection (',' projection)*
    ///   projection  := col_ref (AS? identifier)? | COUNT '(' '*' ')' (AS? identifier)? | qualifier '.' '*'
    ///   table_ref   := identifier (AS? identifier)?
    ///   join_clause := (INNER)? JOIN table_ref ON expr
    ///   col_ref     := (identifier '.')? identifier
    ///   expr        := or_expr
    ///   or_expr     := and_expr (OR and_expr)*
    ///   and_expr    := comparison (AND comparison)*
    ///   comparison  := primary (op primary)?           op := = | != | <> | < | <= | > | >=
    ///                | primary IS (NOT)? NULL
    ///   primary     := literal | col_ref | '(' expr ')'
    pub fn parseSelect(self: *Parser, allocator: std.mem.Allocator) ParseError!ast.SelectStatement {
        try self.expectKeyword(.select, error.InvalidSelect);

        var projections: std.ArrayList(ast.Projection) = .empty;
        errdefer projections.deinit(allocator);
        try self.parseProjections(allocator, &projections);

        try self.expectKeyword(.from, error.InvalidSelect);
        const table_ref = try self.parseTableRef();

        var joins: std.ArrayList(ast.JoinClause) = .empty;
        errdefer {
            for (joins.items) |j| ast.freeExpr(j.on, allocator);
            joins.deinit(allocator);
        }
        while (true) {
            const is_join = self.stream.current.isKeyword(.inner) or self.stream.current.isKeyword(.join);
            if (!is_join) break;
            _ = try self.consumeKeyword(.inner);
            try self.expectKeyword(.join, error.UnsupportedSql);
            const jref = try self.parseTableRef();
            try self.expectKeyword(.on, error.UnsupportedSql);
            const on_expr = try self.parseExpr(allocator);
            try joins.append(allocator, .{
                .kind = .inner,
                .table_name = jref.table_name,
                .alias = jref.alias,
                .on = on_expr,
            });
        }

        var where_expr: ?*ast.Expr = null;
        errdefer if (where_expr) |w| ast.freeExpr(w, allocator);
        if (try self.consumeKeyword(.where)) {
            where_expr = try self.parseExpr(allocator);
        }

        var order_by: ?ast.OrderBy = null;
        if (try self.consumeKeyword(.order)) {
            try self.expectKeyword(.by, error.UnsupportedSql);
            const col = try self.parseColumnRef();
            var descending = false;
            if (try self.consumeKeyword(.desc)) descending = true
            else _ = try self.consumeKeyword(.asc);
            order_by = .{ .column = col, .descending = descending };
        }

        var limit: ?i64 = null;
        if (try self.consumeKeyword(.limit)) {
            const tok = self.stream.current;
            if (tok.kind != .integer) return error.UnsupportedSql;
            self.stream.advance() catch return error.InvalidSql;
            limit = std.fmt.parseInt(i64, tok.lexeme, 10) catch return error.UnsupportedSql;
        }

        return .{
            .projections = try projections.toOwnedSlice(allocator),
            .table_name = table_ref.table_name,
            .table_alias = table_ref.alias,
            .joins = try joins.toOwnedSlice(allocator),
            .where_expr = where_expr,
            .order_by = order_by,
            .limit = limit,
        };
    }

    const TableRef = struct { table_name: []const u8, alias: ?[]const u8 };

    fn parseTableRef(self: *Parser) ParseError!TableRef {
        const name = try self.identifier(error.InvalidSelect);
        var alias: ?[]const u8 = null;
        // Optional `AS alias` or bare `alias`. A bare alias only
        // matches if the next token is a plain identifier (keyword
        // tokens like JOIN/WHERE/ORDER must not be swallowed here).
        const consumed_as = try self.consumeKeyword(.as);
        const tok = self.stream.current;
        const is_plain_ident = tok.kind == .identifier or tok.kind == .quoted_identifier;
        if (consumed_as) {
            if (!is_plain_ident) return error.InvalidSelect;
            alias = tok.lexeme;
            self.stream.advance() catch return error.InvalidSql;
        } else if (is_plain_ident) {
            alias = tok.lexeme;
            self.stream.advance() catch return error.InvalidSql;
        }
        return .{ .table_name = name, .alias = alias };
    }

    fn parseProjections(self: *Parser, allocator: std.mem.Allocator, out: *std.ArrayList(ast.Projection)) ParseError!void {
        while (true) {
            const proj = try self.parseProjection();
            try out.append(allocator, proj);
            if (try self.consume(.comma) != null) continue;
            break;
        }
    }

    fn parseProjection(self: *Parser) ParseError!ast.Projection {
        // `SELECT *`
        if (try self.consume(.star) != null) return .star;

        // `COUNT ( * )`
        if (self.stream.current.isKeyword(.count)) {
            self.stream.advance() catch return error.InvalidSql;
            try self.expect(.left_paren, error.UnsupportedSql);
            try self.expect(.star, error.UnsupportedSql);
            try self.expect(.right_paren, error.UnsupportedSql);
            const alias = try self.consumeOptionalAlias();
            return .{ .count_star = .{ .alias = alias } };
        }

        // Identifier chain: `ident` | `ident . ident` | `ident . *`
        const first_tok = self.stream.current;
        if (first_tok.kind != .identifier and first_tok.kind != .quoted_identifier) return error.UnsupportedSql;
        const first = first_tok.lexeme;
        self.stream.advance() catch return error.InvalidSql;

        if (try self.consume(.dot) != null) {
            if (try self.consume(.star) != null) return .{ .table_star = first };
            const col_tok = self.stream.current;
            if (col_tok.kind != .identifier and col_tok.kind != .quoted_identifier) return error.UnsupportedSql;
            self.stream.advance() catch return error.InvalidSql;
            const alias = try self.consumeOptionalAlias();
            return .{ .column = .{ .ref = .{ .qualifier = first, .name = col_tok.lexeme }, .alias = alias } };
        }

        const alias = try self.consumeOptionalAlias();
        return .{ .column = .{ .ref = .{ .name = first }, .alias = alias } };
    }

    fn consumeOptionalAlias(self: *Parser) ParseError!?[]const u8 {
        const consumed_as = try self.consumeKeyword(.as);
        const tok = self.stream.current;
        const is_ident = tok.kind == .identifier or tok.kind == .quoted_identifier;
        if (consumed_as) {
            if (!is_ident) return error.InvalidSelect;
            self.stream.advance() catch return error.InvalidSql;
            return tok.lexeme;
        }
        // Bare alias only when the next token is a non-keyword
        // identifier AND is not part of the clause-terminating
        // vocabulary. We don't swallow bare identifiers here to keep
        // `FROM x JOIN y` parseable without special-casing every
        // keyword; projection aliases must use AS when ambiguous.
        return null;
    }

    fn parseColumnRef(self: *Parser) ParseError!ast.ColumnRef {
        const first_tok = self.stream.current;
        if (first_tok.kind != .identifier and first_tok.kind != .quoted_identifier) return error.UnsupportedSql;
        const first = first_tok.lexeme;
        self.stream.advance() catch return error.InvalidSql;
        if (try self.consume(.dot) != null) {
            const col_tok = self.stream.current;
            if (col_tok.kind != .identifier and col_tok.kind != .quoted_identifier) return error.UnsupportedSql;
            self.stream.advance() catch return error.InvalidSql;
            return .{ .qualifier = first, .name = col_tok.lexeme };
        }
        return .{ .name = first };
    }

    /// Expression parser: OR < AND < comparison.
    pub fn parseExpr(self: *Parser, allocator: std.mem.Allocator) ParseError!*ast.Expr {
        return try self.parseOr(allocator);
    }

    fn parseOr(self: *Parser, allocator: std.mem.Allocator) ParseError!*ast.Expr {
        var lhs = try self.parseAnd(allocator);
        errdefer ast.freeExpr(lhs, allocator);
        while (try self.consumeKeyword(.or_)) {
            const rhs = try self.parseAnd(allocator);
            lhs = try makeBinary(allocator, .or_, lhs, rhs);
        }
        return lhs;
    }

    fn parseAnd(self: *Parser, allocator: std.mem.Allocator) ParseError!*ast.Expr {
        var lhs = try self.parseComparison(allocator);
        errdefer ast.freeExpr(lhs, allocator);
        while (try self.consumeKeyword(.and_)) {
            const rhs = try self.parseComparison(allocator);
            lhs = try makeBinary(allocator, .and_, lhs, rhs);
        }
        return lhs;
    }

    fn parseComparison(self: *Parser, allocator: std.mem.Allocator) ParseError!*ast.Expr {
        const lhs = try self.parsePrimary(allocator);
        errdefer ast.freeExpr(lhs, allocator);

        // IS [NOT] NULL
        if (try self.consumeKeyword(.is)) {
            const is_not = try self.consumeKeyword(.not);
            try self.expectKeyword(.null, error.UnsupportedWhere);
            return try makeUnary(allocator, if (is_not) .is_not_null else .is_null, lhs);
        }

        const op: ?ast.BinOp = switch (self.stream.current.kind) {
            .equals => .eq,
            .ne => .ne,
            .lt => .lt,
            .le => .le,
            .gt => .gt,
            .ge => .ge,
            else => null,
        };
        if (op) |o| {
            self.stream.advance() catch return error.InvalidSql;
            const rhs = try self.parsePrimary(allocator);
            return try makeBinary(allocator, o, lhs, rhs);
        }
        return lhs;
    }

    fn parsePrimary(self: *Parser, allocator: std.mem.Allocator) ParseError!*ast.Expr {
        if (try self.consume(.left_paren) != null) {
            const inner = try self.parseExpr(allocator);
            try self.expect(.right_paren, error.UnsupportedWhere);
            return inner;
        }
        const tok = self.stream.current;
        switch (tok.kind) {
            .integer => {
                self.stream.advance() catch return error.InvalidSql;
                const v = std.fmt.parseInt(i64, tok.lexeme, 10) catch return error.UnsupportedWhere;
                return try makeLiteral(allocator, .{ .integer = v });
            },
            .string => {
                self.stream.advance() catch return error.InvalidSql;
                return try makeLiteral(allocator, .{ .text = tok.lexeme });
            },
            .keyword => if (tok.keyword == .null) {
                self.stream.advance() catch return error.InvalidSql;
                return try makeLiteral(allocator, .null);
            },
            .identifier, .quoted_identifier => {
                const col = try self.parseColumnRef();
                const node = try allocator.create(ast.Expr);
                node.* = .{ .column = col };
                return node;
            },
            else => {},
        }
        return error.UnsupportedWhere;
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

fn makeBinary(allocator: std.mem.Allocator, op: ast.BinOp, lhs: *ast.Expr, rhs: *ast.Expr) ParseError!*ast.Expr {
    const node = try allocator.create(ast.Expr);
    node.* = .{ .binary = .{ .op = op, .lhs = lhs, .rhs = rhs } };
    return node;
}

fn makeUnary(allocator: std.mem.Allocator, op: ast.BinOp, operand: *ast.Expr) ParseError!*ast.Expr {
    const node = try allocator.create(ast.Expr);
    node.* = .{ .unary = .{ .op = op, .operand = operand } };
    return node;
}

fn makeLiteral(allocator: std.mem.Allocator, lit: ast.Literal) ParseError!*ast.Expr {
    const node = try allocator.create(ast.Expr);
    node.* = .{ .literal = lit };
    return node;
}

pub fn parseStatement(sql: []const u8, allocator: std.mem.Allocator) ParseError!Statement {
    var parser = try Parser.init(sql);
    return parser.parseStatement(allocator);
}

pub fn parseSelect(sql: []const u8, allocator: std.mem.Allocator) ParseError!ast.SelectStatement {
    var parser = try Parser.init(sql);
    const select = try parser.parseSelect(allocator);
    errdefer select.deinit(allocator);
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
    const stmt = try parseSelect("SELECT * FROM users WHERE rowid = 1;", std.testing.allocator);
    defer stmt.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("users", stmt.table_name);
    try std.testing.expectEqual(@as(usize, 1), stmt.projections.len);
    try std.testing.expect(stmt.projections[0] == .star);
    const w = stmt.where_expr.?;
    try std.testing.expect(w.* == .binary);
    try std.testing.expect(w.binary.op == .eq);
    try std.testing.expectEqualStrings("rowid", w.binary.lhs.column.name);
    try std.testing.expectEqual(@as(i64, 1), w.binary.rhs.literal.integer);
}

test "parse quoted text where" {
    const stmt = try parseSelect("select * from users where name = 'alice'", std.testing.allocator);
    defer stmt.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("users", stmt.table_name);
    try std.testing.expectEqualStrings("alice", stmt.where_expr.?.binary.rhs.literal.text);
}

test "parse quoted identifier and comments" {
    const stmt = try parseSelect("-- leading comment\nselect * from [user table] where `name` = 'alice';", std.testing.allocator);
    defer stmt.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("user table", stmt.table_name);
    try std.testing.expectEqualStrings("name", stmt.where_expr.?.binary.lhs.column.name);
}

test "parse column list + limit + order by" {
    const stmt = try parseSelect("SELECT name, ticker FROM companies ORDER BY cik DESC LIMIT 5", std.testing.allocator);
    defer stmt.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), stmt.projections.len);
    try std.testing.expectEqualStrings("name", stmt.projections[0].column.ref.name);
    try std.testing.expectEqualStrings("ticker", stmt.projections[1].column.ref.name);
    try std.testing.expect(stmt.order_by.?.descending);
    try std.testing.expectEqualStrings("cik", stmt.order_by.?.column.name);
    try std.testing.expectEqual(@as(i64, 5), stmt.limit.?);
}

test "parse AND + comparison ops" {
    const stmt = try parseSelect("SELECT * FROM t WHERE a >= 1 AND b < 10 AND c != 'x'", std.testing.allocator);
    defer stmt.deinit(std.testing.allocator);
    const w = stmt.where_expr.?;
    try std.testing.expect(w.* == .binary);
    try std.testing.expect(w.binary.op == .and_);
}

test "parse count(*)" {
    const stmt = try parseSelect("SELECT COUNT(*) FROM t WHERE a = 1", std.testing.allocator);
    defer stmt.deinit(std.testing.allocator);
    try std.testing.expect(stmt.projections[0] == .count_star);
}

test "parse inner join with qualified names" {
    const stmt = try parseSelect("SELECT c.ticker, f.accession FROM companies c JOIN filings f ON c.cik = f.cik", std.testing.allocator);
    defer stmt.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("c", stmt.table_alias.?);
    try std.testing.expectEqual(@as(usize, 1), stmt.joins.len);
    try std.testing.expectEqualStrings("filings", stmt.joins[0].table_name);
    try std.testing.expectEqualStrings("f", stmt.joins[0].alias.?);
    const on = stmt.joins[0].on;
    try std.testing.expectEqualStrings("c", on.binary.lhs.column.qualifier.?);
    try std.testing.expectEqualStrings("cik", on.binary.lhs.column.name);
}

test "parse is null" {
    const stmt = try parseSelect("SELECT * FROM t WHERE a IS NOT NULL", std.testing.allocator);
    defer stmt.deinit(std.testing.allocator);
    const w = stmt.where_expr.?;
    try std.testing.expect(w.* == .unary);
    try std.testing.expect(w.unary.op == .is_not_null);
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
