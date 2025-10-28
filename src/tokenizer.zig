const ast = @import("ast.zig");
const std = @import("std");
const StackArray = @import("stack_array.zig").StackArray;
const Allocator = std.mem.Allocator;

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
    .{ "Const", .TargetConst },
    .{ "Interface", .TargetInterface },
    .{ "Field", .TargetField },
    .{ "OneOf", .TargetOneOf },
    .{ "Enum", .TargetEnum },
    .{ "EnumVariant", .TargetEnumVariant },
    .{ "Func", .TargetFunc },
});

pub const Error = struct {
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
    TargetConst,
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
    String: struct {
        /// content of the string as it appears in the source file.
        content: []const u8,
        /// whether or not the string needs to escape double quotes.
        escape: enum(u3) { None, SingleQuotes, DoubleQuotes },

        const Self = @This();
        pub fn toOwnedAndEscaped(self: Self, ally: Allocator) Allocator.Error![]u8 {
            return switch (self.escape) {
                .None => {
                    const data = try ally.alloc(u8, self.content.len);
                    @memcpy(data, self.content);
                    return data;
                },
                .SingleQuotes => std.mem.replaceOwned(u8, ally, self.content, "\\'", &.{'\''}),
                .DoubleQuotes => std.mem.replaceOwned(u8, ally, self.content, "\\\"", &.{'"'}),
            };
        }
    },
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

    pub fn debug(self: Token, ally: Allocator, writer: *std.Io.Writer) !void {
        return switch (self.kind) {
            .Documentation => {
                var content = self.kind.Documentation.content;
                if (std.mem.indexOf(u8, content, "\n")) |pos| {
                    content = content[0..pos];
                }
                try writer.print("<{s}:{s}:+{d}>", .{
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
                    try writer.print(
                        "<{s}:{s}:+{d}>",
                        .{ @tagName(self.kind), content, newlineCount },
                    );
                } else {
                    try writer.print(
                        "<{s}:{s}>",
                        .{ @tagName(self.kind), self.kind.Comment },
                    );
                }
            },

            .Identifier => try writer.print("<{s}:{s}>", .{
                @tagName(self.kind),
                self.literal,
            }),
            .Float => try writer.print("<{s}:{d}>", .{
                @tagName(self.kind),
                self.kind.Float,
            }),
            .Integer => try writer.print("<{s}:{d}>", .{
                @tagName(self.kind),
                self.kind.Integer,
            }),
            .String => try writer.print(
                "<{s}:{s}>",
                .{ @tagName(self.kind), try self.kind.String.toOwnedAndEscaped(ally) },
            ),
            else => try writer.print("<{s}>", .{@tagName(self.kind)}),
        };
    }
};

const TokenList = StackArray(Token, 1024);
const ErrorList = StackArray(Error, 10);
pub const Iterator = struct {
    /// position of the next token in the tokens buffer.
    i: usize,
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

    const ForwardPeekBufferSize = 2;
    const BackwardPeekBufferSize = 2;

    fn init(it: std.unicode.Utf8Iterator) Iterator {
        return Iterator{
            .i = 0,
            .it = it,
            .start = 0,
            .current = 0,
            .columnCurrent = 1,
            .columnStart = 1,
            .line = 1,
            .tokens = TokenList.init(),
            .errors = ErrorList.init(),
        };
    }

    inline fn peekAscii(self: *Iterator) ?u8 {
        if (self.it.i >= self.it.bytes.len or !std.ascii.isAscii(self.it.bytes[self.it.i])) {
            return null;
        }

        return self.it.bytes[self.it.i];
    }

    inline fn startBoundary(self: *Iterator) void {
        self.start = self.current;
        self.columnStart = self.columnCurrent;
    }

    inline fn advanceAsciiOrSetUnexpectedErr(self: *Iterator) ?u8 {
        return self.advanceAscii() catch {
            // Received unexpected unicode character.
            self.startBoundary(); // NB: to ensure we only display the unicode character.
            _ = self.advanceUnicode() orelse {
                // Unlikely event but received no unicode character either.
                self.addError(Error.UnexpectedEOF);
                return null;
            };
            self.addErrorForCurrentLexeme(Error.UnexpectedChar);
            return null;
        } orelse {
            // No character available.
            self.addError(Error.UnexpectedEOF);
            return null;
        };
    }

    /// advances the iterator only if the next character is ASCII.
    /// If the character is not ASCII, an error gets returned otherwise
    /// an optional ASCII character.
    inline fn advanceAscii(self: *Iterator) error{ReceivedNonAscii}!?u8 {
        if (self.it.i >= self.it.bytes.len) {
            return null;
        }

        if (!std.ascii.isAscii(self.it.bytes[self.it.i])) {
            return error.ReceivedNonAscii;
        }

        defer {
            self.it.i += 1;
            self.columnCurrent += 1;
            self.current += 1;
        }
        return self.it.bytes[self.it.i];
    }

    inline fn advanceUnicode(self: *Iterator) ?[]const u8 {
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
    inline fn consumeUnicode(self: *Iterator, len: ?usize) void {
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

    inline fn consumeAscii(self: *Iterator) void {
        self.it.i += 1;
        self.columnCurrent += 1;
        self.current += 1;
    }

    inline fn currentLexeme(self: Iterator) []const u8 {
        return self.it.bytes[self.start..self.current];
    }

    inline fn currentPosition(self: Iterator) ast.Position {
        return .{
            .line = self.line,
            .column = self.columnStart,
            .offset = self.start,
        };
    }

    inline fn markNewLine(self: *Iterator) void {
        self.columnCurrent = 1;
        self.line += 1;
    }

    inline fn addToken(self: *Iterator, kind: TokenKind) void {
        std.debug.assert(self.tokens.len < self.tokens.capacity());
        self.tokens.appendAssumeCapacity(Token{
            .position = self.currentPosition(),
            .literal = self.currentLexeme(),
            .kind = kind,
        });
    }

    inline fn addError(self: *Iterator, message: []const u8) void {
        if (self.errors.len == self.errors.capacity()) {
            return;
        }
        self.errors.appendAssumeCapacity(Error{
            .message = message,
            .position = self.currentPosition(),
            .literal = "",
        });
    }

    inline fn addErrorForCurrentLexeme(self: *Iterator, message: []const u8) void {
        if (self.errors.len == self.errors.capacity()) {
            return;
        }
        self.errors.appendAssumeCapacity(Error{
            .message = message,
            .position = self.currentPosition(),
            .literal = self.currentLexeme(),
        });
    }

    pub fn peek(self: Iterator, i: usize) ?Token {
        const cursor = self.i + i;
        if (cursor > self.tokens.len or cursor <= 0) {
            return null;
        }

        return self.tokens.buffer[cursor - 1];
    }

    pub inline fn goBack(self: *Iterator) void {
        std.debug.assert(self.i > 0);
        self.i -= 1;
    }

    /// Fills the token buffer if needed for peek operations.
    ///
    /// The `next()` method automatically fills the buffer when called, but `peek()`
    /// operations require the buffer to be populated beforehand. Call this function
    /// before peeking to ensure tokens are available.
    ///
    /// This design maintains lazy evaluation by avoiding redundant buffer checks
    /// during peek operations.
    pub inline fn fillTokenBufferIfNeeded(self: *Iterator) void {
        if (self.i + ForwardPeekBufferSize >= self.tokens.len) {
            // NB: Either reached the end of the buffer and needs refilling or has reached end of file.
            if (self.tokens.len == 0 or self.tokens.getLastAssumeSafe().kind != .EOF)
                self.fillTokenBuffer();
        }
    }

    pub fn next(self: *Iterator) ?Token {
        if (self.i + ForwardPeekBufferSize >= self.tokens.len) {
            @branchHint(.unlikely);
            // NB: Either reached the end of the buffer and needs refilling or has reached end of file.
            if (self.tokens.len == 0 or self.tokens.getLastAssumeSafe().kind != .EOF)
                self.fillTokenBuffer()
            else if (self.tokens.len < self.tokens.capacity() and self.i < self.tokens.len) {
                // NB: do nothing, buffer is actually full and does not need to refill and should drain to end.
                @branchHint(.unlikely);
            } else return null;
        }

        defer self.i += 1;
        return self.tokens.buffer[self.i];
    }

    /// consumes the next token without any safety checks.
    pub inline fn consumeTokenAssumeSafe(self: *Iterator) void {
        self.fillTokenBufferIfNeeded();
        self.i += 1;
    }

    pub inline fn currentAssumeSafe(self: *Iterator) Token {
        return self.tokens.buffer[self.i - 1];
    }

    /// fills the token buffer leaving 2 items in history to allow going backwards.
    fn fillTokenBuffer(self: *Iterator) void {
        const PeekBufferSize = ForwardPeekBufferSize + BackwardPeekBufferSize;
        if (self.tokens.len > PeekBufferSize) {
            @memmove(
                self.tokens.buffer[0..PeekBufferSize],
                self.tokens.buffer[self.tokens.len - PeekBufferSize .. self.tokens.len],
            );
            self.tokens.len = PeekBufferSize;
            self.i = BackwardPeekBufferSize;
        }

        while (self.tokens.len < self.tokens.capacity()) {
            self.startBoundary();
            const char = self.advanceAscii() catch {
                // capture the next unicode character and
                // report unexpected unicode character.
                _ = self.advanceUnicode() orelse return;
                self.addErrorForCurrentLexeme(Error.UnexpectedChar);
                continue;
            } orelse return self.addToken(.EOF);
            switch (char) {
                'r', 'p' => {
                    switch (self.peekAscii() orelse break) {
                        '#' => {
                            self.consumeAscii(); // consume the #
                            if (char == 'r')
                                self.addToken(.RawHash)
                            else
                                self.addToken(.PrivateHash);
                            continue;
                        },
                        else => {},
                    }
                },
                else => {},
            }

            switch (char) {
                // Main character matching
                '(' => self.addToken(.LeftParan),
                ')' => self.addToken(.RightParan),
                '[' => self.addToken(.LeftBracket),
                ']' => self.addToken(.RightBracket),
                '{' => self.addToken(.LeftCurlyBrace),
                '}' => self.addToken(.RightCurlyBrace),
                '<' => self.addToken(.LessThan),
                '>' => self.addToken(.GreaterThan),
                ';' => self.addToken(.Semicolon),
                '?' => self.addToken(.QuestionMark),
                ',' => self.addToken(.Comma),
                '.' => self.addToken(.Dot),
                ':' => self.addToken(.Colon),
                '=' => self.addToken(.Equal),
                '#' => self.addToken(.Hash),
                '/' => self.scanComment(),
                '-' => {
                    const nextChar = self.advanceAsciiOrSetUnexpectedErr() orelse continue;
                    if (nextChar == '>') {
                        self.addToken(.Return);
                    } else if (std.ascii.isDigit(nextChar)) {
                        self.scanNumber();
                    } else {
                        self.start += 1; // NB: to generate the error for the last character.
                        self.addErrorForCurrentLexeme(Error.UnexpectedChar);
                        continue;
                    }
                },
                '_' => self.addToken(.Underscore),
                ' ', '\t', '\r' => {},
                '\n' => self.markNewLine(),
                '`' => self.scanIdentifierLiteral(),
                '\'' => self.scanString('\''),
                '"' => self.scanString('"'),
                else => {
                    if (std.ascii.isDigit(char)) {
                        self.scanNumber();
                    } else if (std.ascii.isAlphanumeric(char)) {
                        self.scanIdentifier();
                    } else {
                        self.addError(Error.UnexpectedChar);
                    }
                },
            }
        }
    }

    fn skipUntilNewLine(self: *Iterator) void {
        while (self.it.i < self.it.bytes.len) {
            if (self.it.bytes[self.it.i] == '\n') {
                self.consumeAscii();
                self.markNewLine();
                return;
            }
            self.it.i += 1;
        }
    }

    fn scanString(self: *Iterator, comptime quoteChar: u8) void {
        var needsToSkip = false; // if we need to replace quote skip characters.
        while (true) {
            const nextUnicode = self.advanceUnicode() orelse {
                self.addErrorForCurrentLexeme(Error.UnterminatedString);
                self.addToken(.{
                    .String = .{
                        .content = self.it.bytes[self.start + 1 .. self.current],
                        .escape = .None,
                    },
                });
                return;
            };
            if (nextUnicode.len == 1) switch (nextUnicode[0]) {
                '\n' => {
                    self.current -= 1;
                    self.addErrorForCurrentLexeme(Error.UnterminatedString);
                    self.addToken(.{
                        .String = .{
                            .content = self.it.bytes[self.start + 1 .. self.current],
                            .escape = .None,
                        },
                    });
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

        self.addToken(.{
            .String = .{
                .content = self.it.bytes[self.start + 1 .. self.current - 1],
                .escape = if (!needsToSkip)
                    .None
                else
                    comptime if (quoteChar == '\'') .SingleQuotes else .DoubleQuotes,
            },
        });
    }

    fn scanComment(self: *Iterator) void {
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
                    self.addToken(.{ .Documentation = .{
                        .content = self.it.bytes[start..self.current],
                        .newlineCount = 0,
                    } });
                } else {
                    self.addToken(.{ .Comment = self.it.bytes[start..self.current] });
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
                        self.addErrorForCurrentLexeme(Error.UnterminatedMultiLineComment);
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
                    self.tokens.appendAssumeCapacity(.{
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
                    self.tokens.appendAssumeCapacity(.{
                        .kind = .{
                            .Comment = self.it.bytes[start..end],
                        },
                        .position = startPosition,
                        .literal = self.currentLexeme(),
                    });
                }
            },
            else => self.addErrorForCurrentLexeme(Error.UnexpectedChar),
        }
    }

    fn scanNumber(self: *Iterator) void {
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
                self.addToken(.{ .Float = 0 });
                return self.addErrorForCurrentLexeme(Error.InvalidFloatNumber);
            };
            self.addToken(.{ .Float = number });
        } else {
            const number = std.fmt.parseInt(i64, self.currentLexeme(), 10) catch {
                self.addToken(.{ .Integer = 0 });
                return self.addErrorForCurrentLexeme(Error.InvalidIntegerNumber);
            };
            self.addToken(.{ .Integer = number });
        }
    }

    fn scanIdentifier(self: *Iterator) void {
        while (true) {
            const nextChar = self.peekAscii() orelse break;
            if (std.ascii.isAlphanumeric(nextChar) or nextChar == '_') {
                self.consumeAscii();
            } else {
                break;
            }
        }

        if (keywordTable.get(self.currentLexeme())) |kind| {
            self.addToken(kind);
        } else {
            self.addToken(.Identifier);
        }
    }

    /// assumes that a backtick is already consumed and proceeds to read all the
    /// alphanumeric characters until next backtick.
    fn scanIdentifierLiteral(self: *Iterator) void {
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
            return self.addError(Error.UnterminatedIdentifierLiteral);
        }
        self.addToken(.Identifier);
        self.consumeAscii(); // consume the backtick.
    }
};

pub const Result = struct {
    tokens: []const Token,
    errors: []const Error,
    allocator: std.heap.ArenaAllocator,

    pub fn deinit(self: *Result) void {
        self.allocator.deinit();
    }

    pub fn ok(self: Result) bool {
        return self.errors.len == 0;
    }

    /// debug returns a string representation for the Result.
    pub fn debug(
        self: *const Result,
        ally: Allocator,
        writer: *std.Io.Writer,
    ) error{ OutOfMemory, WriteFailed }!void {
        for (self.tokens) |item| {
            try item.debug(ally, writer);
        }
    }
};

pub const TokenizeError = error{InvalidUtf8};

pub fn tokenize(data: []const u8) TokenizeError!Iterator {
    const utf8View = std.unicode.Utf8View.init(data) catch {
        return TokenizeError.InvalidUtf8;
    };

    return Iterator.init(utf8View.iterator());
}

pub fn tokenizeAlloc(ally: Allocator, data: []const u8) !Result {
    var arena = std.heap.ArenaAllocator.init(ally);
    const allocator = arena.allocator();

    var it = try tokenize(data);
    var tokens = try std.ArrayList(Token).initCapacity(allocator, 1024);
    while (it.next()) |token| try tokens.append(allocator, token);

    const errors = if (it.errors.len > 0) blk: {
        const items = try allocator.alloc(Error, it.errors.len);
        @memcpy(items, it.errors.slice());
        break :blk items;
    } else &.{};

    return .{
        .allocator = arena,
        .tokens = tokens.items,
        .errors = errors,
    };
}
