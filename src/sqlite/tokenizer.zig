const std = @import("std");

pub const TokenError = error{
    InvalidCharacter,
    UnterminatedString,
    UnterminatedIdentifier,
    InvalidNumber,
};

pub const Keyword = enum {
    select,
    from,
    where,
    insert,
    into,
    values,
    update,
    set,
    delete,
    create,
    table,
    index,
    on,
    null,
    and_,
    or_,
    limit,
    order,
    by,
    desc,
    asc,
    inner,
    join,
    as,
    count,
    is,
    not,
    like,
    in,
    between,
    sum,
    min,
    max,
    avg,
};

pub const Kind = enum {
    eof,
    identifier,
    quoted_identifier,
    keyword,
    integer,
    string,
    star,
    comma,
    semicolon,
    left_paren,
    right_paren,
    equals,
    lt,
    le,
    gt,
    ge,
    ne,
    dot,
    plus,
    minus,
    slash,
    percent,
    concat,
};

pub const Token = struct {
    kind: Kind,
    lexeme: []const u8,
    keyword: ?Keyword = null,
    start: usize,
    end: usize,

    pub fn isKeyword(self: Token, keyword: Keyword) bool {
        return self.kind == .keyword and self.keyword == keyword;
    }

    pub fn identifierText(self: Token) ?[]const u8 {
        return switch (self.kind) {
            .identifier, .quoted_identifier => self.lexeme,
            else => null,
        };
    }
};

pub const Tokenizer = struct {
    input: []const u8,
    pos: usize = 0,

    pub fn init(input: []const u8) Tokenizer {
        return .{ .input = input };
    }

    pub fn next(self: *Tokenizer) TokenError!Token {
        self.skipTrivia();
        if (self.pos >= self.input.len) return .{
            .kind = .eof,
            .lexeme = "",
            .start = self.pos,
            .end = self.pos,
        };

        const start = self.pos;
        const c = self.input[self.pos];
        switch (c) {
            '*' => return self.single(.star, start),
            ',' => return self.single(.comma, start),
            ';' => return self.single(.semicolon, start),
            '(' => return self.single(.left_paren, start),
            ')' => return self.single(.right_paren, start),
            '=' => return self.single(.equals, start),
            '.' => return self.single(.dot, start),
            '<' => {
                self.pos += 1;
                if (self.pos < self.input.len and self.input[self.pos] == '=') {
                    self.pos += 1;
                    return .{ .kind = .le, .lexeme = self.input[start..self.pos], .start = start, .end = self.pos };
                }
                if (self.pos < self.input.len and self.input[self.pos] == '>') {
                    self.pos += 1;
                    return .{ .kind = .ne, .lexeme = self.input[start..self.pos], .start = start, .end = self.pos };
                }
                return .{ .kind = .lt, .lexeme = self.input[start..self.pos], .start = start, .end = self.pos };
            },
            '>' => {
                self.pos += 1;
                if (self.pos < self.input.len and self.input[self.pos] == '=') {
                    self.pos += 1;
                    return .{ .kind = .ge, .lexeme = self.input[start..self.pos], .start = start, .end = self.pos };
                }
                return .{ .kind = .gt, .lexeme = self.input[start..self.pos], .start = start, .end = self.pos };
            },
            '!' => {
                self.pos += 1;
                if (self.pos < self.input.len and self.input[self.pos] == '=') {
                    self.pos += 1;
                    return .{ .kind = .ne, .lexeme = self.input[start..self.pos], .start = start, .end = self.pos };
                }
                return error.InvalidCharacter;
            },
            '+' => return self.single(.plus, start),
            '-' => {
                // Line-comment `--` is stripped by skipTrivia; if we got here
                // it's a real minus. Emit as its own token; unary negation
                // is handled in the parser's primary.
                return self.single(.minus, start);
            },
            '/' => return self.single(.slash, start),
            '%' => return self.single(.percent, start),
            '|' => {
                self.pos += 1;
                if (self.pos < self.input.len and self.input[self.pos] == '|') {
                    self.pos += 1;
                    return .{ .kind = .concat, .lexeme = self.input[start..self.pos], .start = start, .end = self.pos };
                }
                return error.InvalidCharacter;
            },
            '\'' => return self.string(start),
            '"', '`', '[' => return self.quotedIdentifier(start),
            '0'...'9' => return self.integer(start),
            else => {
                if (isIdentifierStart(c)) return self.identifier(start);
                return error.InvalidCharacter;
            },
        }
    }

    fn single(self: *Tokenizer, kind: Kind, start: usize) Token {
        self.pos += 1;
        return .{
            .kind = kind,
            .lexeme = self.input[start..self.pos],
            .start = start,
            .end = self.pos,
        };
    }

    fn skipTrivia(self: *Tokenizer) void {
        while (self.pos < self.input.len) {
            const c = self.input[self.pos];
            if (std.ascii.isWhitespace(c)) {
                self.pos += 1;
                continue;
            }
            if (c == '-' and self.pos + 1 < self.input.len and self.input[self.pos + 1] == '-') {
                self.pos += 2;
                while (self.pos < self.input.len and self.input[self.pos] != '\n') self.pos += 1;
                continue;
            }
            break;
        }
    }

    fn identifier(self: *Tokenizer, start: usize) Token {
        self.pos += 1;
        while (self.pos < self.input.len and isIdentifierContinue(self.input[self.pos])) self.pos += 1;
        const lexeme = self.input[start..self.pos];
        if (keywordFor(lexeme)) |keyword| {
            return .{
                .kind = .keyword,
                .lexeme = lexeme,
                .keyword = keyword,
                .start = start,
                .end = self.pos,
            };
        }
        return .{
            .kind = .identifier,
            .lexeme = lexeme,
            .start = start,
            .end = self.pos,
        };
    }

    fn quotedIdentifier(self: *Tokenizer, start: usize) TokenError!Token {
        const open = self.input[self.pos];
        const close: u8 = if (open == '[') ']' else open;
        self.pos += 1;
        const text_start = self.pos;
        while (self.pos < self.input.len) {
            if (self.input[self.pos] == close) {
                const lexeme = self.input[text_start..self.pos];
                self.pos += 1;
                return .{
                    .kind = .quoted_identifier,
                    .lexeme = lexeme,
                    .start = start,
                    .end = self.pos,
                };
            }
            self.pos += 1;
        }
        return error.UnterminatedIdentifier;
    }

    fn string(self: *Tokenizer, start: usize) TokenError!Token {
        self.pos += 1;
        const text_start = self.pos;
        while (self.pos < self.input.len) {
            if (self.input[self.pos] == '\'') {
                if (self.pos + 1 < self.input.len and self.input[self.pos + 1] == '\'') {
                    self.pos += 2;
                    continue;
                }
                const lexeme = self.input[text_start..self.pos];
                self.pos += 1;
                return .{
                    .kind = .string,
                    .lexeme = lexeme,
                    .start = start,
                    .end = self.pos,
                };
            }
            self.pos += 1;
        }
        return error.UnterminatedString;
    }

    fn integer(self: *Tokenizer, start: usize) TokenError!Token {
        const digits_start = self.pos;
        while (self.pos < self.input.len and std.ascii.isDigit(self.input[self.pos])) self.pos += 1;
        if (self.pos == digits_start) return error.InvalidNumber;
        return .{
            .kind = .integer,
            .lexeme = self.input[start..self.pos],
            .start = start,
            .end = self.pos,
        };
    }
};

pub const TokenStream = struct {
    tokenizer: Tokenizer,
    current: Token,

    pub fn init(input: []const u8) TokenError!TokenStream {
        var tokenizer = Tokenizer.init(input);
        const current = try tokenizer.next();
        return .{ .tokenizer = tokenizer, .current = current };
    }

    pub fn advance(self: *TokenStream) TokenError!void {
        self.current = try self.tokenizer.next();
    }

    pub fn consume(self: *TokenStream, kind: Kind) TokenError!?Token {
        if (self.current.kind != kind) return null;
        const token = self.current;
        try self.advance();
        return token;
    }

    pub fn consumeKeyword(self: *TokenStream, keyword: Keyword) TokenError!bool {
        if (!self.current.isKeyword(keyword)) return false;
        try self.advance();
        return true;
    }
};

pub fn keywordFor(text: []const u8) ?Keyword {
    inline for (.{
        .{ "SELECT", Keyword.select },
        .{ "FROM", Keyword.from },
        .{ "WHERE", Keyword.where },
        .{ "INSERT", Keyword.insert },
        .{ "INTO", Keyword.into },
        .{ "VALUES", Keyword.values },
        .{ "UPDATE", Keyword.update },
        .{ "SET", Keyword.set },
        .{ "DELETE", Keyword.delete },
        .{ "CREATE", Keyword.create },
        .{ "TABLE", Keyword.table },
        .{ "INDEX", Keyword.index },
        .{ "ON", Keyword.on },
        .{ "NULL", Keyword.null },
        .{ "AND", Keyword.and_ },
        .{ "OR", Keyword.or_ },
        .{ "LIMIT", Keyword.limit },
        .{ "ORDER", Keyword.order },
        .{ "BY", Keyword.by },
        .{ "DESC", Keyword.desc },
        .{ "ASC", Keyword.asc },
        .{ "INNER", Keyword.inner },
        .{ "JOIN", Keyword.join },
        .{ "AS", Keyword.as },
        .{ "COUNT", Keyword.count },
        .{ "IS", Keyword.is },
        .{ "NOT", Keyword.not },
        .{ "LIKE", Keyword.like },
        .{ "IN", Keyword.in },
        .{ "BETWEEN", Keyword.between },
        .{ "SUM", Keyword.sum },
        .{ "MIN", Keyword.min },
        .{ "MAX", Keyword.max },
        .{ "AVG", Keyword.avg },
    }) |entry| {
        if (std.ascii.eqlIgnoreCase(text, entry[0])) return entry[1];
    }
    return null;
}

pub fn isIdentifierStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_';
}

pub fn isIdentifierContinue(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

test "tokenizes basic select" {
    var stream = try TokenStream.init("SELECT * FROM users WHERE rowid = 1;");
    try std.testing.expect(stream.current.isKeyword(.select));
    try stream.advance();
    try std.testing.expectEqual(Kind.star, stream.current.kind);
    try stream.advance();
    try std.testing.expect(stream.current.isKeyword(.from));
    try stream.advance();
    try std.testing.expectEqualStrings("users", stream.current.identifierText().?);
    try stream.advance();
    try std.testing.expect(stream.current.isKeyword(.where));
    try stream.advance();
    try std.testing.expectEqualStrings("rowid", stream.current.identifierText().?);
    try stream.advance();
    try std.testing.expectEqual(Kind.equals, stream.current.kind);
    try stream.advance();
    try std.testing.expectEqualStrings("1", stream.current.lexeme);
    try stream.advance();
    try std.testing.expectEqual(Kind.semicolon, stream.current.kind);
}

test "tokenizes comments and quoted identifiers" {
    var stream = try TokenStream.init("-- c\nselect * from [user table] where `name` = 'alice'");
    try std.testing.expect(stream.current.isKeyword(.select));
    try stream.advance();
    _ = try stream.consume(.star);
    _ = try stream.consumeKeyword(.from);
    try std.testing.expectEqualStrings("user table", stream.current.identifierText().?);
    try stream.advance();
    _ = try stream.consumeKeyword(.where);
    try std.testing.expectEqualStrings("name", stream.current.identifierText().?);
    try stream.advance();
    _ = try stream.consume(.equals);
    try std.testing.expectEqual(Kind.string, stream.current.kind);
    try std.testing.expectEqualStrings("alice", stream.current.lexeme);
}
