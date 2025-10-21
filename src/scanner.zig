const ast = @import("ast.zig");
const std = @import("std");
const StackArray = @import("stack_array.zig").StackArray;

const keywordTable = std.StaticStringMap(TokenKind).initComptime(.{
    .{ "pact", .Pact },
    .{ "import", .Import },
    .{ "message", .Message },
    .{ "interface", .Interface },
    .{ "enum", .Enum },
    .{ "const", .Const },
    .{ "stream", .Stream },
    .{ "func", .Func },
    .{ "true", .True },
    .{ "false", .False },
    .{ "embed", .Embed },
    .{ "list", .List },
    .{ "map", .Map },
    .{ "oneof", .OneOf },
    .{ "for", .For },
    .{ "option", .Option },

    .{ "Pact", .TargetPact },
    .{ "Message", .TargetMessage },
    .{ "Interface", .TargetInterface },
    .{ "Field", .TargetField },
    .{ "OneOf", .TargetOneOf },
    .{ "Enum", .TargetEnum },
    .{ "EnumVariant", .TargetEnumVariant },
    .{ "Func", .TargetFunc },
});

const IteratorError = error{ReceivedNonAscii};

pub const ScanError = struct {
    message: []const u8,
    // literal is the part of the source that is related to the error.
    literal: ?[]const u8,
    position: ast.Position,

    const UnexpectedEOF = "unexpected EOF";
    const UnexpectedChar = "unexpected character";
    const UnterminatedIdentifierLiteral = "unterminated backtick identifier literal";
    const UnterminatedMultiLineComment = "unterminated multi-line comment/documentation";
    const UnterminatedString = "unterminated string";
    const InvalidFloatNumber = "invalid float number";
    const InvalidIntegerNumber = "invalid integer number";
};

pub const TokenKind = union(enum) {
    LeftParan,
    RightParan,
    LeftCurlyBrace,
    RightCurlyBrace,
    LeftBracket,
    RightBracket,
    LessThan,
    GreaterThan,

    Hash,
    RawHash,
    PrivateHash,
    Colon,
    Semicolon,
    Dot,
    QuestionMark,

    Pact,
    Import,
    Message,
    Interface,
    Enum,
    Func,
    Stream,
    Underscore,
    Embed,
    List,
    Map,
    OneOf,
    Option,
    For,
    Const,

    TargetMessage,
    TargetInterface,
    TargetEnum,
    TargetEnumVariant,
    TargetOneOf,
    TargetFunc,
    TargetField,
    TargetPact,

    Equal,
    Return,
    True,
    False,
    Comma,
    Identifier,
    String: []const u8,
    Documentation: struct {
        /// actual content of the documentation segment.
        content: []const u8,
        /// a single line comment would have a value of 0.
        newlineCount: u16,
    },
    Comment: []const u8,
    Integer: i64,
    Float: f64,

    EOF,
};

pub const Token = struct {
    kind: TokenKind,
    literal: []const u8,
    position: ast.Position,

    /// returns a range capturing the start-end for this token.
    pub fn range(self: Token) ast.Range {
        return ast.Range{
            .start = self.position,
            .endOffset = self.endOffset(),
        };
    }

    /// returns a range capturing the start from the current token and the end of the other token.
    pub fn rangeUntilToken(self: Token, other: Token) ast.Range {
        return ast.Range{
            .start = self.position,
            .endOffset = other.endOffset(),
        };
    }

    pub inline fn endOffset(self: Token) usize {
        return self.position.offset + self.literal.len;
    }

    fn eof() Token {
        return .{ .kind = .EOF, .literal = "", .position = ast.Position.empty() };
    }

    pub fn debug(self: Token, writer: anytype) !void {
        return switch (self.kind) {
            .Documentation => {
                var content = self.kind.Documentation.content;
                if (std.mem.indexOf(u8, content, "\n")) |pos| {
                    content = content[0..pos];
                }
                try std.fmt.format(writer, "<{s}:{s}:+{d}>", .{
                    @tagName(self.kind),
                    content,
                    self.kind.Documentation.newlineCount,
                });
            },
            .Comment => {
                const newlineCount = std.mem.count(u8, self.kind.Comment, "\n");
                if (newlineCount > 0) {
                    var content = self.kind.Comment;
                    if (std.mem.indexOf(u8, content, "\n")) |pos| {
                        content = content[0..pos];
                    }
                    try std.fmt.format(
                        writer,
                        "<{s}:{s}:+{d}>",
                        .{ @tagName(self.kind), content, newlineCount },
                    );
                } else {
                    try std.fmt.format(
                        writer,
                        "<{s}:{s}>",
                        .{ @tagName(self.kind), self.kind.Comment },
                    );
                }
            },

            .Identifier => try std.fmt.format(writer, "<{s}:{s}>", .{
                @tagName(self.kind),
                self.literal,
            }),
            .Float => try std.fmt.format(writer, "<{s}:{d}>", .{
                @tagName(self.kind),
                self.kind.Float,
            }),
            .Integer => try std.fmt.format(writer, "<{s}:{d}>", .{
                @tagName(self.kind),
                self.kind.Integer,
            }),
            .String => try std.fmt.format(
                writer,
                "<{s}:{s}>",
                .{ @tagName(self.kind), self.kind.String },
            ),
            else => try std.fmt.format(writer, "<{s}>", .{@tagName(self.kind)}),
        };
    }
};

const TokenList = std.ArrayList(Token);
const ErrorList = StackArray(ScanError, 10);
const Context = struct {
    allocator: std.mem.Allocator,
    it: std.unicode.Utf8Iterator,
    /// start is the byte position of the start pointer.
    start: usize,
    /// current is the byte position of the current pointer.
    current: usize,
    /// number of characters in the current line at the current position.
    columnCurrent: u16,
    /// number of characters in the current line at the start position.
    columnStart: u16,
    line: u16,
    tokens: TokenList,
    errors: ErrorList,

    fn init(allocator: std.mem.Allocator, it: std.unicode.Utf8Iterator) std.mem.Allocator.Error!Context {
        return Context{
            .allocator = allocator,
            .it = it,
            .start = 0,
            .current = 0,
            .columnCurrent = 1,
            .columnStart = 1,
            .line = 1,
            .tokens = try TokenList.initCapacity(allocator, InitialTokenCapacity),
            .errors = ErrorList.init(),
        };
    }

    /// allocates precisely the amount necessary to store errors.
    fn buildErrors(self: Context) std.mem.Allocator.Error![]const ScanError {
        const errors = try self.allocator.alloc(ScanError, self.errors.len);
        @memcpy(errors, self.errors.slice());
        return errors;
    }

    inline fn peekAscii(self: *Context) ?u8 {
        if (self.it.i >= self.it.bytes.len or !std.ascii.isAscii(self.it.bytes[self.it.i])) {
            return null;
        }

        return self.it.bytes[self.it.i];
    }

    inline fn startBoundary(self: *Context) void {
        self.start = self.current;
        self.columnStart = self.columnCurrent;
    }

    inline fn advanceAsciiOrSetUnexpectedErr(self: *Context) ?u8 {
        return self.advanceAscii() catch {
            // Received unexpected unicode character.
            self.startBoundary(); // NB: to ensure we only display the unicode character.
            _ = self.advanceUnicode() orelse {
                // Unlikely event but received no unicode character either.
                self.addError(ScanError.UnexpectedEOF);
                return null;
            };
            self.addErrorForCurrentLexeme(ScanError.UnexpectedChar);
            return null;
        } orelse {
            // No character available.
            self.addError(ScanError.UnexpectedEOF);
            return null;
        };
    }

    /// advances the iterator only if the next character is ASCII.
    /// If the character is not ASCII, an error gets returned otherwise
    /// an optional ASCII character.
    inline fn advanceAscii(self: *Context) IteratorError!?u8 {
        if (self.it.i >= self.it.bytes.len) {
            return null;
        }

        if (!std.ascii.isAscii(self.it.bytes[self.it.i])) {
            return IteratorError.ReceivedNonAscii;
        }

        defer {
            self.it.i += 1;
            self.columnCurrent += 1;
            self.current += 1;
        }
        return self.it.bytes[self.it.i];
    }

    inline fn advanceUnicode(self: *Context) ?[]const u8 {
        if (self.it.nextCodepointSlice()) |char| {
            self.current += char.len;
            self.columnCurrent += 1;
            return char;
        }
        return null;
    }

    /// consume would advance all the counters for the next character.
    /// if the len is known, it will be used, otherwise the UTF-8 window
    /// iterator gets used to determine the next unicode character.
    /// WARN: Do NOT use this method for more than a single unicode character.
    inline fn consumeUnicode(self: *Context, len: ?usize) void {
        if (len) |size| {
            self.it.i += size;
            self.current += size;
            self.columnCurrent += 1;
            return;
        }

        if (self.it.nextCodepointSlice()) |slice| {
            self.current += slice.len;
            self.columnCurrent += 1;
        }
    }

    inline fn consumeAscii(self: *Context) void {
        self.it.i += 1;
        self.columnCurrent += 1;
        self.current += 1;
    }

    inline fn currentLexeme(self: Context) []const u8 {
        return self.it.bytes[self.start..self.current];
    }

    inline fn currentPosition(self: Context) ast.Position {
        return .{
            .line = self.line,
            .column = self.columnStart,
            .offset = self.start,
        };
    }

    inline fn markNewLine(self: *Context) void {
        self.columnCurrent = 1;
        self.line += 1;
    }

    inline fn addToken(self: *Context, kind: TokenKind) !void {
        try self.tokens.append(self.allocator, Token{
            .position = self.currentPosition(),
            .literal = self.currentLexeme(),
            .kind = kind,
        });
    }

    inline fn addError(self: *Context, message: []const u8) void {
        if (self.errors.len == self.errors.capacity()) {
            return;
        }
        self.errors.appendAssumeCapacity(ScanError{
            .message = message,
            .position = self.currentPosition(),
            .literal = "",
        });
    }

    inline fn addErrorForCurrentLexeme(self: *Context, message: []const u8) void {
        if (self.errors.len == self.errors.capacity()) {
            return;
        }
        self.errors.appendAssumeCapacity(ScanError{
            .message = message,
            .position = self.currentPosition(),
            .literal = self.currentLexeme(),
        });
    }

    /// scan all the tokens until EOF is reached or an error is encountered.
    fn scanAll(self: *Context) !void {
        while (true) {
            self.startBoundary();
            const char = self.advanceAscii() catch {
                // capture the next unicode character and
                // report unexpected unicode character.
                _ = self.advanceUnicode() orelse return;
                self.addErrorForCurrentLexeme(ScanError.UnexpectedChar);
                continue;
            } orelse return;
            switch (char) {
                'r', 'p' => {
                    switch (self.peekAscii() orelse break) {
                        '#' => {
                            self.consumeAscii(); // consume the #
                            if (char == 'r') {
                                try self.addToken(.RawHash);
                            } else {
                                try self.addToken(.PrivateHash);
                            }
                            continue;
                        },
                        '`' => {
                            self.consumeAscii();
                            try self.scanIdentifierLiteral();
                            continue;
                        },
                        else => {},
                    }
                },
                else => {},
            }

            switch (char) {
                // Main character matching
                '(' => try self.addToken(.LeftParan),
                ')' => try self.addToken(.RightParan),
                '[' => try self.addToken(.LeftBracket),
                ']' => try self.addToken(.RightBracket),
                '{' => try self.addToken(.LeftCurlyBrace),
                '}' => try self.addToken(.RightCurlyBrace),
                '<' => try self.addToken(.LessThan),
                '>' => try self.addToken(.GreaterThan),
                ';' => try self.addToken(.Semicolon),
                '?' => try self.addToken(.QuestionMark),
                ',' => try self.addToken(.Comma),
                '.' => try self.addToken(.Dot),
                ':' => try self.addToken(.Colon),
                '=' => try self.addToken(.Equal),
                '#' => try self.addToken(.Hash),
                '/' => try self.scanComment(),
                '-' => {
                    const nextChar = self.advanceAsciiOrSetUnexpectedErr() orelse continue;
                    if (nextChar == '>') {
                        try self.addToken(.Return);
                    } else if (std.ascii.isDigit(nextChar)) {
                        try self.scanNumber();
                    } else {
                        self.start += 1; // NB: to generate the error for the last character.
                        self.addErrorForCurrentLexeme(ScanError.UnexpectedChar);
                        continue;
                    }
                },
                '_' => try self.addToken(.Underscore),
                ' ', '\t', '\r' => {},
                '\n' => self.markNewLine(),
                '`' => try self.scanIdentifierLiteral(),
                '\'' => try self.scanString('\''),
                '"' => try self.scanString('"'),
                else => {
                    if (std.ascii.isDigit(char)) {
                        try self.scanNumber();
                    } else if (std.ascii.isAlphanumeric(char)) {
                        try self.scanIdentifier();
                    } else {
                        self.addError(ScanError.UnexpectedChar);
                    }
                },
            }
        }
    }

    fn skipUntilNewLine(self: *Context) void {
        while (self.it.i < self.it.bytes.len) {
            if (self.it.bytes[self.it.i] == '\n') {
                self.consumeAscii();
                self.markNewLine();
                return;
            }
            self.it.i += 1;
        }
    }

    fn scanString(self: *Context, comptime quoteChar: u8) !void {
        var needsToSkip = false; // if we need to replace quote skip characters.
        while (true) {
            const nextUnicode = self.advanceUnicode() orelse {
                self.addErrorForCurrentLexeme(ScanError.UnterminatedString);
                try self.addToken(.{ .String = self.it.bytes[self.start + 1 .. self.current] });
                return;
            };
            if (nextUnicode.len == 1) switch (nextUnicode[0]) {
                '\n' => {
                    self.current -= 1;
                    self.addErrorForCurrentLexeme(ScanError.UnterminatedString);
                    try self.addToken(.{ .String = self.it.bytes[self.start + 1 .. self.current] });
                    self.current += 1;
                    self.markNewLine();
                    return;
                },
                '\\' => {
                    if (self.peekAscii()) |nextAscii| {
                        if (nextAscii == quoteChar) {
                            needsToSkip = true;
                            self.consumeAscii();
                        }
                    }
                },
                quoteChar => break,
                else => {},
            };
        }

        if (needsToSkip) {
            const content = try std.mem.replaceOwned(
                u8,
                self.allocator,
                self.it.bytes[self.start + 1 .. self.current - 1],
                "\\" ++ .{quoteChar},
                &[_]u8{quoteChar},
            );
            try self.addToken(.{ .String = content });
        } else {
            try self.addToken(.{ .String = self.it.bytes[self.start + 1 .. self.current - 1] });
        }
    }

    fn scanComment(self: *Context) !void {
        // expect either * or /
        const char = self.advanceAsciiOrSetUnexpectedErr() orelse return;
        switch (char) {
            '/' => {
                var slashCount: u8 = 2;
                while (true) {
                    const nextChar = self.peekAscii() orelse break;
                    if (nextChar == '/') {
                        self.consumeAscii();
                        slashCount += 1;
                    } else {
                        break;
                    }
                }
                const start = self.current;
                // NB: consume all characters until the end of the line.
                while (true) {
                    const nextChar = self.it.peek(1);
                    if ((nextChar.len == 1 and nextChar[0] == '\n') or nextChar.len == 0) {
                        break;
                    }
                    self.consumeUnicode(nextChar.len);
                }
                if (slashCount == 3) {
                    try self.addToken(.{ .Documentation = .{
                        .content = self.it.bytes[start..self.current],
                        .newlineCount = 0,
                    } });
                } else {
                    try self.addToken(.{ .Comment = self.it.bytes[start..self.current] });
                }
            },
            '*' => {
                var starCount: u8 = 1;
                while (true) {
                    const nextChar = self.peekAscii() orelse break;
                    if (nextChar == '*') {
                        starCount += 1;
                        self.consumeAscii();
                    } else {
                        break;
                    }
                }
                const start = self.current;
                const startPosition = self.currentPosition();
                var end: usize = undefined;
                var newlineCount: u16 = 0;
                while (true) {
                    // NB: consume all characters until */ is discovered.
                    const nextChar = self.advanceUnicode() orelse {
                        self.addErrorForCurrentLexeme(ScanError.UnterminatedMultiLineComment);
                        return;
                    };
                    if (nextChar.len == 1) switch (nextChar[0]) {
                        '\n' => { // NB: Count the new lines!
                            self.markNewLine();
                            newlineCount += 1;
                        },
                        '*' => { // NB: If "*" is followed by ascii char "/" then break out!
                            if (self.peekAscii()) |nextAscii| {
                                if (nextAscii == '/') {
                                    end = self.current - 1;
                                    self.consumeAscii();
                                    break;
                                }
                            }
                        },
                        else => {},
                    };
                }
                if (starCount == 2) {
                    // NB: since we need to use the startPosition, we can't use addToken().
                    try self.tokens.append(self.allocator, .{
                        .kind = .{
                            .Documentation = .{
                                .content = self.it.bytes[start..end],
                                .newlineCount = newlineCount,
                            },
                        },
                        .position = startPosition,
                        .literal = self.currentLexeme(),
                    });
                } else {
                    try self.tokens.append(self.allocator, .{
                        .kind = .{
                            .Comment = self.it.bytes[start..end],
                        },
                        .position = startPosition,
                        .literal = self.currentLexeme(),
                    });
                }
            },
            else => self.addErrorForCurrentLexeme(ScanError.UnexpectedChar),
        }
    }

    fn scanNumber(self: *Context) !void {
        var nextChar = self.peekAscii();
        if (self.it.bytes[self.start] != '-') {
            if (nextChar != null and nextChar == '-') {
                self.consumeAscii();
            }
        }

        while (true) {
            nextChar = self.peekAscii() orelse break;
            if (std.ascii.isDigit(nextChar.?)) {
                self.consumeAscii();
            } else {
                break;
            }
        }

        var isFloat = false;
        const nextChars = self.it.peek(2);
        if (nextChars.len == 2 and nextChars[0] == '.' and std.ascii.isDigit(nextChars[1])) {
            isFloat = true;
            self.consumeAscii();
            self.consumeAscii();
            while (true) {
                nextChar = self.peekAscii() orelse break;
                if (std.ascii.isDigit(nextChar.?)) {
                    self.consumeAscii();
                } else {
                    break;
                }
            }
        }

        if (isFloat) {
            const number = std.fmt.parseFloat(f64, self.currentLexeme()) catch {
                try self.addToken(.{ .Float = 0 });
                return self.addErrorForCurrentLexeme(ScanError.InvalidFloatNumber);
            };
            try self.addToken(.{ .Float = number });
        } else {
            const number = std.fmt.parseInt(i64, self.currentLexeme(), 10) catch {
                try self.addToken(.{ .Integer = 0 });
                return self.addErrorForCurrentLexeme(ScanError.InvalidIntegerNumber);
            };
            try self.addToken(.{ .Integer = number });
        }
    }

    fn scanIdentifier(self: *Context) !void {
        while (true) {
            const nextChar = self.peekAscii() orelse break;
            if (std.ascii.isAlphanumeric(nextChar) or nextChar == '_') {
                self.consumeAscii();
            } else {
                break;
            }
        }

        if (keywordTable.get(self.currentLexeme())) |kind| {
            try self.addToken(kind);
        } else {
            try self.addToken(.Identifier);
        }
    }

    /// assumes that a backtick is already consumed and proceeds to read all the
    /// alphanumeric characters until next backtick.
    fn scanIdentifierLiteral(self: *Context) !void {
        while (true) {
            const nextChar = self.it.peek(1);
            if (nextChar.len == 1 and (std.ascii.isAlphanumeric(nextChar[0]) or nextChar[0] == '_')) {
                self.consumeAscii();
            } else {
                break;
            }
        }

        self.start += 1; // skip the backtick.
        const nextChar = self.it.peek(1);
        if (nextChar.len != 1 or nextChar[0] != '`') {
            return self.addError(ScanError.UnterminatedIdentifierLiteral);
        }
        try self.addToken(.Identifier);
        self.consumeAscii(); // consume the backtick.
    }
};

pub const Result = struct {
    tokens: []const Token,
    errors: []const ScanError,
    allocator: std.heap.ArenaAllocator,

    pub fn deinit(self: *Result) void {
        self.allocator.deinit();
    }

    pub fn ok(self: Result) bool {
        return self.errors.len == 0;
    }

    /// debug returns a string representation for the Result.
    pub fn debug(self: *Result, writer: anytype) !void {
        for (self.tokens) |item| {
            try item.debug(writer);
        }
    }
};

const InitialTokenCapacity = 1000;

pub const TokenizeError = error{
    InvalidUtf8,
} || std.mem.Allocator.Error;

pub fn tokenize(allocator: std.mem.Allocator, data: []const u8) TokenizeError!Result {
    const utf8View = std.unicode.Utf8View.init(data) catch {
        return TokenizeError.InvalidUtf8;
    };

    var arenaAllocator = std.heap.ArenaAllocator.init(allocator);
    errdefer arenaAllocator.deinit();

    const ally = arenaAllocator.allocator();
    var ctx = try Context.init(ally, utf8View.iterator());
    try ctx.scanAll();
    try ctx.tokens.append(ally, Token.eof());

    return Result{
        .tokens = ctx.tokens.items,
        .errors = try ctx.buildErrors(),
        .allocator = arenaAllocator,
    };
}
