const std = @import("std");
const scanner = @import("scanner.zig");
const ast = @import("ast.zig");

const Allocator = std.mem.Allocator;

const Error = error{ UnexpectedToken, NestingDepthReached } || Allocator.Error;
const FatalError = error{NestingDepthReached} || Allocator.Error;

const OptionModifiers = struct {
    raw: bool,
    shared: bool,

    fn default() OptionModifiers {
        return .{ .raw = false, .shared = false };
    }
};

/// Holds boundary for documentations along with the total content size so that
/// it can be allocated all at once.
const StagedDocumentation = struct {
    startIndex: usize,
    endIndex: usize,
    contentSize: usize,
    lastDocLine: u16,
};

const TokenIterator = struct {
    data: []const scanner.Token,
    i: usize,

    fn init(data: []const scanner.Token) TokenIterator {
        return .{ .data = data, .i = 0 };
    }

    fn peek(self: TokenIterator, i: usize) ?scanner.Token {
        const cursor = self.i + i;
        if (cursor > self.data.len or cursor <= 0) {
            return null;
        }

        return self.data[cursor - 1];
    }

    fn next(self: *TokenIterator) ?scanner.Token {
        if (self.i >= self.data.len) {
            return null;
        }

        defer self.i += 1;
        return self.data[self.i];
    }

    inline fn currentAssumeSafe(self: *TokenIterator) scanner.Token {
        return self.data[self.i - 1];
    }
};

pub const SyntaxError = struct {
    pub const Location = union(enum) {
        Position: ast.Position,
        Range: ast.Range,
    };

    message: []const u8,
    literal: ?[]const u8,
    location: ?Location,

    fn nestingDepthReached(position: ast.Position) SyntaxError {
        return .{
            .message = "maximum nesting level of 10 reached",
            .literal = "",
            .location = Location{ .Position = position },
        };
    }

    fn unexpectedToken(token: *const scanner.Token) SyntaxError {
        if (token.kind == .EOF) {
            return .unexpectedEOF();
        }

        return .{
            .message = "unexpected token",
            .literal = token.literal,
            .location = Location{ .Range = token.range() },
        };
    }

    fn redundantOptionHash(position: ast.Position) SyntaxError {
        return .{
            .message = "redundant use of option symbol # in option block",
            .literal = "#",
            .location = Location{ .Position = position },
        };
    }

    fn rawStringOptionWithoutRawMarker(token: *const scanner.Token) SyntaxError {
        return .{
            .message = "use of raw identifier without raw modifier prefix, did you mean to use r# ?",
            .literal = token.literal,
            .location = Location{ .Range = token.range() },
        };
    }

    fn looseDocumentation(token: *const scanner.Token) SyntaxError {
        return .{
            .message = "unused documentation, use plain comments instead",
            .literal = token.literal,
            .location = Location{ .Range = token.range() },
        };
    }

    fn unexpectedEOF() SyntaxError {
        return .{
            .message = "unexpected end of file",
            .literal = "",
            .location = Location{ .Position = .empty() },
        };
    }

    fn enumVariantNumericalError(token: *const scanner.Token) SyntaxError {
        return .{
            .message = "enum value must be a positive integer from 0 to 2^32-1",
            .literal = token.literal,
            .location = Location{ .Range = token.range() },
        };
    }

    fn fieldTagNumericalError(token: *const scanner.Token) SyntaxError {
        return .{
            .message = "field tag value must be a positive integer from 1 to 2^32-1",
            .literal = token.literal,
            .location = Location{ .Range = token.range() },
        };
    }

    fn funcTagNumericalError(token: *const scanner.Token) SyntaxError {
        return .{
            .message = "func tag value must be a positive integer from 1 to 2^32-1",
            .literal = token.literal,
            .location = Location{ .Range = token.range() },
        };
    }

    fn duplicatedPact(selector: []const u8, range: ast.Range) SyntaxError {
        return .{
            .message = "duplicated pact statement, each document can have a single pact statement",
            .literal = selector,
            .location = Location{ .Range = range },
        };
    }

    fn expectToken(token: *const scanner.Token, comptime expected: []const u8) SyntaxError {
        if (token.kind == .EOF) {
            return .unexpectedEOF();
        }

        return .{
            .message = "expected " ++ expected,
            .literal = token.literal,
            .location = Location{ .Position = token.position },
        };
    }
};

/// A result type that can be used to communicated partial data with need for recovery, complete data without any need
/// for recovery or no data with only an error.
fn ParseResult(T: type) type {
    return union(enum) {
        /// regardless of any syntax error, some data is parsed and if as part of any recovery process, the current
        /// scope is exited, the caller need to cease processing their scope immediately without consuming any tokens.
        some: struct { data: T, scopeExited: bool },
        /// a syntax error is encountered and no data could be parsed as a result of it.
        syntaxErr: void,

        const Self = @This();

        fn initOk(value: T) Self {
            return .{ .some = .{ .data = value, .scopeExited = false } };
        }

        fn initScopeExited(value: T) Self {
            return .{ .some = .{ .data = value, .scopeExited = true } };
        }

        fn initSyntaxErr() Self {
            return .{ .syntaxErr = {} };
        }

        fn unwrap(self: Self) Error!T {
            return switch (self) {
                .some => |v| v.data,
                .syntaxErr => Error.UnexpectedToken,
            };
        }

        fn initValue(value: T, scopeExited: bool) Self {
            return .{ .some = .{ .data = value, .scopeExited = scopeExited } };
        }

        fn initErr(err: Error) FatalError!Self {
            return switch (err) {
                Error.UnexpectedToken => .initSyntaxErr(),
                else => |e| e,
            };
        }
    };
}

// Context is a state object to track all the errors and captured data from the tokens.
//
// processX -> the first token is already consumed the and the function expects that.
// parseX -> all components of the AST node must be read and consumed.
const Context = struct {
    const ScopeDelimiter = enum {
        CurlyBrace,
        Bracket,
        Paran,
    };
    const ErrorList = std.BoundedArray(SyntaxError, 10);
    const ScopeDelimiterList = std.BoundedArray(ScopeDelimiter, 10);

    const TokenKindTag = std.meta.Tag(scanner.TokenKind);

    allocator: Allocator,
    it: TokenIterator,
    errors: ErrorList,
    scopeDelimiters: ScopeDelimiterList,
    stagedDocumentation: ?StagedDocumentation,

    pact: ?ast.Selector,
    imports: std.ArrayList(ast.Import),
    options: std.ArrayList(ast.OptionAssignmentNode),
    constants: std.ArrayList(ast.Constant),
    enums: std.ArrayList(ast.Enum),
    messages: std.ArrayList(ast.Message),
    optionDefinitions: std.ArrayList(ast.OptionDefinition),
    interfaces: std.ArrayList(ast.Interface),
    documentation: ?ast.Documentation,

    const EntryKeywords: []const TokenKindTag = &.{
        .Pact,
        .Import,
        .RawHash,
        .Hash,
        .SharedHash,
        .Const,
        .Enum,
        .Message,
        .Option,
        .Interface,
        .Documentation,
    };

    const ScopeDelimiterTokens: []const TokenKindTag = &.{
        .LeftCurlyBrace,
        .LeftBracket,
        .LeftParan,
        .RightCurlyBrace,
        .RightBracket,
        .RightParan,
    };

    const EnumBodyRecoveryPoints: []const TokenKindTag = &.{
        .Hash,
        .RawHash,
        .SharedHash,
        .Identifier,
        .Documentation,
    };

    fn init(allocator: Allocator, tokens: []const scanner.Token) Context {
        return .{
            .allocator = allocator,
            .it = TokenIterator.init(tokens),
            .errors = ErrorList.init(0) catch unreachable,
            .scopeDelimiters = ScopeDelimiterList.init(0) catch unreachable,
            .stagedDocumentation = null,
            .pact = null,
            .imports = std.ArrayList(ast.Import).init(allocator),
            .options = std.ArrayList(ast.OptionAssignmentNode).init(allocator),
            .constants = std.ArrayList(ast.Constant).init(allocator),
            .enums = std.ArrayList(ast.Enum).init(allocator),
            .messages = std.ArrayList(ast.Message).init(allocator),
            .optionDefinitions = std.ArrayList(ast.OptionDefinition).init(allocator),
            .interfaces = std.ArrayList(ast.Interface).init(allocator),
            .documentation = null,
        };
    }

    fn parse(self: *Context) ParseError!void {
        if (self.parseDocumentationGroup()) |doc| {
            if (self.nextTokenAcceptsTopLevelDocumentation(doc)) {
                self.stagedDocumentation = doc;
            } else {
                self.documentation = try self.processStagedDocumentation(doc);
            }
        }

        while (self.it.next()) |token| {
            (switch (token.kind) {
                .Pact => self.processPact(),
                .Import => self.processImport(),
                .RawHash, .Hash, .SharedHash => option: {
                    // NB: Special case where we need to consume the first token itself.
                    self.it.i -= 1;
                    break :option self.processOption();
                },
                .Const => self.processConst(),
                .Enum => self.processEnum(),
                .Message => self.processMessage(),
                .Option => self.processOptionDefinition(),
                .Interface => self.processInterface(),
                .Comment => {}, // ignore comments.
                .Documentation => documentation: {
                    // NB: Special case where we need to consume the first token itself.
                    self.it.i -= 1;
                    break :documentation self.captureDocumentationGroup();
                },
                .EOF => break,
                else => self.addError(SyntaxError.unexpectedToken(&token)),
            }) catch |err| switch (err) {
                Allocator.Error.OutOfMemory => return Allocator.Error.OutOfMemory,
                Error.NestingDepthReached => {
                    self.addError(SyntaxError.nestingDepthReached(self.it.currentAssumeSafe().position));
                    return;
                },
                Error.UnexpectedToken => {
                    _ = self.skipTokensUntil(EntryKeywords, false) catch {
                        self.addError(SyntaxError.nestingDepthReached(self.it.currentAssumeSafe().position));
                        return;
                    };
                },
            };
        }
    }

    fn processPact(self: *Context) Error!void {
        const selector = try self.parseSelector();
        if (self.pact == null) {
            self.pact = selector;
        } else self.addError(SyntaxError.duplicatedPact(selector.content, selector.range));
    }

    fn processImport(self: *Context) Error!void {
        try self.processGroup(processImportBody);
    }

    fn processImportBody(self: *Context) Error!void {
        const start = self.currentPosition();
        const implicit = self.consumeOptionalTokenBool(.Underscore);
        var alias: []const u8 = "";

        if (!implicit) {
            if (self.consumeOptionalToken(.Identifier)) |aliasToken| {
                alias = try self.copyString(aliasToken.literal);
            }
        }

        const pathToken = self.consumeRequiredToken(.String, "path string") catch |err| {
            return self.recover(err, &[_]TokenKindTag{ .String, .Underscore, .Identifier }, true);
        };
        try self.imports.append(.{
            .implicit = implicit,
            .alias = alias,
            .path = try self.copyString(pathToken.kind.String),
            .range = .{ .start = start, .endOffset = pathToken.endOffset() },
        });
    }

    fn processConst(self: *Context) Error!void {
        try self.processGroup(processConstBody);
    }

    inline fn addConst(
        self: *Context,
        name: []const u8,
        value: ast.RangedValue,
        documentation: ?ast.Documentation,
        start: ast.Position,
        options: []ast.OptionAssignmentNode,
    ) Allocator.Error!void {
        try self.constants.append(ast.Constant{
            .name = try self.copyString(name),
            .value = value,
            .documentation = documentation,
            .options = options,
            .range = .{ .start = start, .endOffset = self.it.currentAssumeSafe().endOffset() },
        });
    }

    fn processConstBody(self: *Context) Error!void {
        const ConstRecoveryPoints = &[_]TokenKindTag{ .Documentation, .Identifier };
        const documentation = try self.parseDocumentationGroupForCurrentPosition();
        const start = self.currentPosition();
        const nameToken = self.consumeRequiredToken(.Identifier, "const name") catch |err| {
            return self.recover(err, ConstRecoveryPoints, false);
        };
        _ = self.consumeRequiredToken(.Equal, "=") catch |err| {
            return self.recover(err, ConstRecoveryPoints, false);
        };

        const value = switch (try self.parseValue()) {
            .some => |v| blk: {
                if (v.scopeExited) {
                    try self.addConst(nameToken.literal, v.data, documentation, start, &.{});
                    return;
                }
                break :blk v.data;
            },
            // TODO: we might need a different version of self.recover, something like recoverSyntaxError
            // and maybe the recoverSyntaxError should gaurantee FatalError.
            .syntaxErr => return self.recover(error.UnexpectedToken, ConstRecoveryPoints, false),
        };

        const options: []ast.OptionAssignmentNode = if (self.nextTokenIs(.LeftCurlyBrace)) blk: {
            switch (try self.parseOptionBlock()) {
                .some => |v| {
                    if (v.scopeExited) {
                        try self.addConst(nameToken.literal, value, documentation, start, v.data);
                        return Error.UnexpectedToken;
                    }
                    break :blk v.data;
                },
                .syntaxErr => {
                    // TODO: same as above.
                    try self.addConst(nameToken.literal, value, documentation, start, &.{});
                    return self.recover(error.UnexpectedToken, ConstRecoveryPoints, false);
                },
            }
        } else &.{};

        try self.addConst(nameToken.literal, value, documentation, start, options);
    }

    fn processEnum(self: *Context) Error!void {
        try self.processGroup(processEnumBody);
    }

    fn processEnumBody(self: *Context) Error!void {
        const EnumEntryRecoveryPoints: []const TokenKindTag = &.{ .Documentation, .Identifier };
        const documentation = try self.parseDocumentationGroupForCurrentPosition();
        const nameToken = self.consumeRequiredToken(.Identifier, "enum name") catch |err| {
            return self.recover(err, EnumEntryRecoveryPoints, false);
        };
        _ = self.consumeRequiredToken(.LeftCurlyBrace, "{") catch |err| {
            return self.recover(err, EnumEntryRecoveryPoints, false);
        };

        var options = std.ArrayList(ast.OptionAssignmentNode).init(self.allocator);
        var variants = std.ArrayList(ast.EnumVariant).init(self.allocator);
        while (true) {
            const token = self.it.peek(1) orelse {
                self.addError(SyntaxError.unexpectedEOF());
                return Error.UnexpectedToken;
            };
            switch (token.kind) {
                .Comment => self.consume(),
                .Hash, .RawHash, .SharedHash => {
                    switch (try self.parseOption(false, null)) {
                        .some => |v| {
                            try options.append(v.data);
                            if (v.scopeExited) break;
                        },
                        .syntaxErr => if (try self.recoverSyntaxError(EnumBodyRecoveryPoints, true)) break,
                    }
                },
                .Identifier => {
                    switch (try self.parseEnumVariant()) {
                        .some => |value| {
                            try variants.append(value.data);
                            if (value.scopeExited) break;
                        },
                        .syntaxErr => if (try self.recoverSyntaxError(EnumBodyRecoveryPoints, true)) break,
                    }
                },
                .Documentation => try self.captureDocumentationGroup(),
                .RightCurlyBrace => {
                    self.consume();
                    self.popScopeDelimiter(.CurlyBrace);
                    break;
                },
                else => {
                    self.addError(SyntaxError.unexpectedToken(&token));
                    if (try self.skipTokensUntil(EnumBodyRecoveryPoints, false)) {
                        break;
                    }
                },
            }
            _ = self.consumeOptionalTokenBool(.Comma);
        }

        try self.enums.append(ast.Enum{
            .name = ast.Identifier{ .value = try self.copyString(nameToken.literal), .range = nameToken.range() },
            .variants = variants.items,
            .documentation = documentation,
            .options = options.items,
            .range = .{ .start = nameToken.position, .endOffset = self.it.currentAssumeSafe().endOffset() },
        });
    }

    inline fn buildEnumVariant(
        self: *Context,
        nameToken: scanner.Token,
        value: ?u32,
        documentation: ?ast.Documentation,
        options: []const ast.OptionAssignmentNode,
    ) Allocator.Error!ast.EnumVariant {
        return .{
            .name = ast.Identifier{
                .value = try self.copyString(nameToken.literal),
                .range = nameToken.range(),
            },
            .value = value,
            .documentation = documentation,
            .options = options,
            .range = .{
                .start = nameToken.position,
                .endOffset = self.it.currentAssumeSafe().endOffset(),
            },
        };
    }

    fn parseEnumVariant(self: *Context) FatalError!ParseResult(ast.EnumVariant) {
        const documentation = try self.consumeStagedDocumentationFor(self.it.currentAssumeSafe().position);
        const nameToken = self.consumeRequiredToken(.Identifier, "enum value") catch |err| return .initErr(err);
        var value: ?u32 = null;

        if (self.consumeOptionalTokenBool(.Equal)) {
            // explicit assignment.
            if (self.consumeRequiredToken(.Integer, "enum variant numerical value")) |valueToken| {
                if (std.math.cast(u32, valueToken.kind.Integer)) |tag| {
                    value = tag;
                } else self.addError(SyntaxError.enumVariantNumericalError(&valueToken));
            } else |err| if (try self.recoverExitsScope(err, &.{ .RawHash, .Hash, .SharedHash, .Comma }, false)) {
                return .initScopeExited(
                    try self.buildEnumVariant(nameToken, null, documentation, &.{}),
                );
            }
        }

        return switch (try self.parseItemOptions()) {
            .some => |v| .initValue(
                try self.buildEnumVariant(nameToken, value, documentation, v.data),
                v.scopeExited,
            ),
            .syntaxErr => .initValue(
                try self.buildEnumVariant(nameToken, value, documentation, &.{}),
                try self.recoverSyntaxError(EnumBodyRecoveryPoints, true),
            ),
        };
    }

    fn processMessage(self: *Context) Error!void {
        try self.processGroup(processMessageBody);
    }

    fn processMessageBody(self: *Context) Error!void {
        const MessageEntryRecoveryPoints: []const TokenKindTag = &.{ .Documentation, .Identifier };
        const MessageBodyRecoveryPoints: []const TokenKindTag = &.{
            .Identifier,
            .Embed,
            .Documentation,
            .Hash,
            .RawHash,
            .SharedHash,
            .OneOf,
        };
        const documentation = try self.parseDocumentationGroupForCurrentPosition();
        const nameToken = self.consumeRequiredToken(.Identifier, "message name") catch |err| {
            return self.recover(err, MessageEntryRecoveryPoints, true);
        };
        _ = self.consumeRequiredToken(.LeftCurlyBrace, "{") catch |err| {
            return self.recover(err, MessageEntryRecoveryPoints, false);
        };

        var options = std.ArrayList(ast.OptionAssignmentNode).init(self.allocator);
        var fields = std.ArrayList(ast.Field).init(self.allocator);
        var embeddedMessages = std.ArrayList(ast.Selector).init(self.allocator);
        var oneOfGroups = std.ArrayList(ast.OneOf).init(self.allocator);

        while (true) {
            const token = self.it.peek(1) orelse {
                self.addError(SyntaxError.unexpectedEOF());
                return Error.UnexpectedToken;
            };
            switch (token.kind) {
                .Comment => self.consume(),
                .Documentation => try self.captureDocumentationGroup(),
                .Hash, .RawHash, .SharedHash => {
                    switch (try self.parseOption(false, null)) {
                        .some => |v| {
                            try options.append(v.data);
                            if (v.scopeExited) {
                                break;
                            }
                        },
                        .syntaxErr => if (try self.recoverSyntaxError(MessageBodyRecoveryPoints, true)) break,
                    }
                },
                .Identifier => try fields.append(try self.parseField(null)),
                .Embed => {
                    self.consume();
                    try embeddedMessages.append(try self.parseSelector());
                },
                .OneOf => {
                    const start = token.position;
                    self.consume();
                    const oneOfNameToken = try self.consumeRequiredToken(.Identifier, "oneof group name");
                    const oneOfBlock = try self.parseOneOfBody(oneOfGroups.items.len, &fields);
                    try oneOfGroups.append(ast.OneOf{
                        .name = ast.Identifier{
                            .value = try self.copyString(oneOfNameToken.literal),
                            .range = nameToken.range(),
                        },
                        .options = oneOfBlock.options,
                        .range = ast.Range{
                            .start = start,
                            .endOffset = self.it.currentAssumeSafe().endOffset(),
                        },
                    });
                },
                .RightCurlyBrace => {
                    self.consume();
                    self.popScopeDelimiter(.CurlyBrace);
                    break;
                },
                else => {
                    self.addError(SyntaxError.unexpectedToken(&token));
                    if (try self.skipTokensUntil(MessageBodyRecoveryPoints, false)) {
                        break;
                    }
                },
            }
            _ = self.consumeOptionalTokenBool(.Comma);
        }

        try self.messages.append(ast.Message{
            .name = ast.Identifier{ .value = try self.copyString(nameToken.literal), .range = nameToken.range() },
            .embeddedMessages = embeddedMessages.items,
            .documentation = documentation,
            .fields = fields.items,
            .options = options.items,
            .oneOfGroups = oneOfGroups.items,
            .range = .{ .start = nameToken.position, .endOffset = self.it.currentAssumeSafe().endOffset() },
        });
    }

    fn parseField(self: *Context, oneOfGroupIndex: ?usize) Error!ast.Field {
        const documentation = try self.consumeStagedDocumentationFor(self.it.currentAssumeSafe().position);
        const nameToken = try self.consumeRequiredToken(.Identifier, "field name");
        _ = try self.consumeRequiredToken(.Colon, ":");

        const dataType = try self.parseFieldDataType();
        var tag: ?u32 = null;
        if (self.consumeOptionalTokenBool(.Equal)) {
            const tagToken = try self.consumeRequiredToken(.Integer, "field tag number");
            if (std.math.cast(u32, tagToken.kind.Integer)) |tagValue| {
                if (tagValue == 0) {
                    self.addError(SyntaxError.fieldTagNumericalError(&tagToken));
                }
                tag = tagValue;
            } else {
                self.addError(SyntaxError.fieldTagNumericalError(&tagToken));
            }
        }
        const options = try self.parseItemOptions();

        return ast.Field{
            .name = .{
                .value = try self.copyString(nameToken.literal),
                .range = nameToken.range(),
            },
            .documentation = documentation,
            .options = try options.unwrap(),
            .range = ast.Range{
                .start = nameToken.position,
                .endOffset = self.it.currentAssumeSafe().endOffset(),
            },
            .tag = tag,
            .dataType = dataType,
            .oneOfGroupIndex = oneOfGroupIndex,
        };
    }

    fn parseFieldDataType(self: *Context) Error!ast.Field.RangedDataType {
        const nextToken = self.it.peek(1) orelse {
            self.addError(SyntaxError.unexpectedEOF());
            return Error.UnexpectedToken;
        };
        switch (nextToken.kind) {
            .Identifier => {
                const typeSelector = try self.parseSelector();
                return ast.Field.RangedDataType{
                    .value = .{ .String = typeSelector },
                    .range = typeSelector.range,
                };
            },
            .OneOf => {
                const start = nextToken.position;
                self.consume();
                var fieldList = std.ArrayList(ast.Field).init(self.allocator);
                const oneOf = try self.parseOneOfBody(null, &fieldList);
                return ast.Field.RangedDataType{
                    .value = .{ .OneOf = oneOf },
                    .range = ast.Range{
                        .start = start,
                        .endOffset = self.it.currentAssumeSafe().endOffset(),
                    },
                };
            },
            .List => {
                const start = nextToken.position;
                self.consume();
                _ = try self.consumeRequiredToken(.LessThan, "<");
                const typeSelector = try self.parseSelector();
                const lastToken = try self.consumeRequiredToken(.GreaterThan, ">");
                return ast.Field.RangedDataType{
                    .value = .{ .List = typeSelector },
                    .range = ast.Range{ .start = start, .endOffset = lastToken.endOffset() },
                };
            },
            .Map => {
                const start = nextToken.position;
                self.consume();
                _ = try self.consumeRequiredToken(.LessThan, "<");
                const keyTypeSelector = try self.parseSelector();
                _ = try self.consumeRequiredToken(.Comma, ",");
                const valueTypeSelector = try self.parseSelector();
                const lastToken = try self.consumeRequiredToken(.GreaterThan, ">");
                return ast.Field.RangedDataType{
                    .value = .{ .Map = .{ .key = keyTypeSelector, .value = valueTypeSelector } },
                    .range = ast.Range{ .start = start, .endOffset = lastToken.endOffset() },
                };
            },
            else => {
                self.addError(SyntaxError.expectToken(&nextToken, "field type"));
                return Error.UnexpectedToken;
            },
        }
    }

    /// parses oneof bodies. It can append to an existing ArrayList if one is provided.
    fn parseOneOfBody(
        self: *Context,
        oneOfGroupIndex: ?usize,
        fields: *std.ArrayList(ast.Field),
    ) Error!ast.Field.OneOfTypeInfo {
        _ = try self.consumeRequiredToken(.LeftCurlyBrace, "{");
        var options = std.ArrayList(ast.OptionAssignmentNode).init(self.allocator);
        const initialPosition = fields.items.len;

        while (true) {
            const nextToken = self.it.peek(1) orelse {
                self.addError(SyntaxError.unexpectedEOF());
                return Error.UnexpectedToken;
            };
            switch (nextToken.kind) {
                .Identifier => try fields.append(try self.parseField(oneOfGroupIndex)),
                .Hash, .RawHash, .SharedHash => try options.append(try (try self.parseOption(false, null)).unwrap()),
                .RightCurlyBrace => {
                    self.consume();
                    break;
                },
                else => {
                    self.addError(SyntaxError.unexpectedToken(&nextToken));
                    return Error.UnexpectedToken;
                },
            }
            _ = self.consumeOptionalTokenBool(.Comma);
        }

        return ast.Field.OneOfTypeInfo{
            .fields = fields.items[initialPosition..],
            .options = options.items,
        };
    }

    fn parseItemOptions(self: *Context) FatalError!ParseResult([]ast.OptionAssignmentNode) {
        const RecoveryPoints: []const TokenKindTag = &.{ .Comma, .RawHash, .Hash, .SharedHash };

        if (self.nextTokenIs(.LeftCurlyBrace)) {
            return self.parseOptionBlock();
        }

        var values = std.ArrayList(ast.OptionAssignmentNode).init(self.allocator);
        const scopeExited = blk: {
            mainLoop: while (true) {
                const token = self.it.peek(1) orelse break :blk false;
                if (token.kind == .RightCurlyBrace or token.kind == .Comma) {
                    break :blk false;
                }
                switch (try self.parseOption(false, null)) {
                    .some => |v| {
                        try values.append(v.data);
                        if (v.scopeExited) {
                            break :blk true;
                        }
                    },
                    .syntaxErr => if (try self.recoverSyntaxError(RecoveryPoints, true))
                        break :blk true
                    else
                        continue :mainLoop,
                }
            }
        };

        return .initValue(values.items, scopeExited);
    }

    fn processOptionDefinition(self: *Context) Error!void {
        const start = self.it.currentAssumeSafe().position;
        _ = try self.consumeRequiredToken(.For, "for");

        var targetSet = ast.OptionTargetSet.init(.{});
        targetSet.insert(try self.parseOptionTarget());
        while (true) {
            const nextToken = self.it.peek(1) orelse {
                self.addError(SyntaxError.unexpectedEOF());
                return Error.UnexpectedToken;
            };
            if (nextToken.kind == .LeftCurlyBrace) {
                self.consume();
                break;
            }
            _ = try self.consumeRequiredToken(.Comma, ",");
            targetSet.insert(try self.parseOptionTarget());
        }

        var fields = std.ArrayList(ast.Field).init(self.allocator);

        while (true) {
            const nextToken = self.it.peek(1) orelse {
                self.addError(SyntaxError.unexpectedEOF());
                return Error.UnexpectedToken;
            };
            switch (nextToken.kind) {
                .Comment => self.consume(),
                .RightCurlyBrace => {
                    self.consume();
                    break;
                },
                else => try fields.append(try self.parseField(null)),
            }
            _ = self.consumeOptionalTokenBool(.Comma);
        }

        try self.optionDefinitions.append(ast.OptionDefinition{
            .targets = targetSet,
            .fields = fields.items,
            .range = .{
                .start = start,
                .endOffset = self.it.currentAssumeSafe().endOffset(),
            },
        });
    }

    inline fn parseOptionTarget(self: *Context) Error!ast.OptionTarget {
        const targetToken = self.it.next() orelse {
            self.addError(SyntaxError.unexpectedEOF());
            return Error.UnexpectedToken;
        };
        switch (targetToken.kind) {
            .TargetPact => return ast.OptionTarget.Pact,
            .TargetOneOf => return ast.OptionTarget.OneOf,
            .TargetEnum => return ast.OptionTarget.Enum,
            .TargetEnumVariant => return ast.OptionTarget.EnumVariant,
            .TargetMessage => return ast.OptionTarget.Message,
            .TargetField => return ast.OptionTarget.Field,
            .TargetInterface => return ast.OptionTarget.Interface,
            .TargetFunc => return ast.OptionTarget.Func,
            else => {
                self.addError(SyntaxError.expectToken(&targetToken, "option target"));
                return Error.UnexpectedToken;
            },
        }
    }

    fn processInterface(self: *Context) Error!void {
        try self.processGroup(processInterfaceBody);
    }

    fn processInterfaceBody(self: *Context) Error!void {
        const documentation = try self.parseDocumentationGroupForCurrentPosition();
        const nameToken = try self.consumeRequiredToken(.Identifier, "interface name");

        _ = try self.consumeRequiredToken(.LeftCurlyBrace, "");
        var funcs = std.ArrayList(ast.Func).init(self.allocator);
        var options = std.ArrayList(ast.OptionAssignmentNode).init(self.allocator);

        while (true) {
            const nextToken = self.it.peek(1) orelse {
                self.addError(SyntaxError.unexpectedEOF());
                return Error.UnexpectedToken;
            };

            switch (nextToken.kind) {
                .Comment => self.consume(),
                .Hash, .SharedHash, .RawHash => {
                    try options.append(try (try self.parseOption(false, null)).unwrap());
                    _ = self.consumeOptionalTokenBool(.Comma);
                },
                .Documentation => try self.captureDocumentationGroup(),
                .Identifier => try funcs.append(try self.parseFunc()),
                .RightCurlyBrace => {
                    self.consume();
                    break;
                },
                else => {
                    self.addError(SyntaxError.unexpectedToken(&nextToken));
                    return Error.UnexpectedToken;
                },
            }
        }

        try self.interfaces.append(ast.Interface{
            .name = ast.Identifier{
                .value = try self.copyString(nameToken.literal),
                .range = nameToken.range(),
            },
            .funcs = funcs.items,
            .documentation = documentation,
            .options = options.items,
            .range = ast.Range{
                .start = nameToken.position,
                .endOffset = self.it.currentAssumeSafe().endOffset(),
            },
        });
    }

    fn parseFunc(self: *Context) Error!ast.Func {
        const documentation = try self.consumeStagedDocumentationFor(self.it.currentAssumeSafe().position);
        const nameToken = try self.consumeRequiredToken(.Identifier, "func name");
        _ = try self.consumeRequiredToken(.LeftParan, "(");
        var input: ?ast.FuncArg = null;
        var output: ?ast.FuncArg = null;

        // Input
        if (!self.consumeOptionalExitScopeTokenBool(.RightParan)) {
            input = try self.parseFuncArg();
            _ = try self.consumeRequiredToken(.RightParan, ")");
        }

        // Output
        if (self.consumeOptionalTokenBool(.Return)) {
            if (try self.consumeOptionalEnterScopeTokenBool(.LeftParan)) {
                if (self.nextTokenIs(.Identifier)) {
                    output = try self.parseFuncArg();
                }
                _ = try self.consumeRequiredToken(.RightParan, ")");
            } else {
                output = try self.parseFuncArg();
            }
        }

        // Optional Tag
        var tag: ?u32 = null;
        if (self.consumeOptionalTokenBool(.Equal)) {
            const tagToken = try self.consumeRequiredToken(.Integer, "func tag");
            if (std.math.cast(u32, tagToken.kind.Integer)) |tagValue| {
                if (tagValue == 0) {
                    self.addError(SyntaxError.funcTagNumericalError(&tagToken));
                }
                tag = tagValue;
            } else self.addError(SyntaxError.funcTagNumericalError(&tagToken));
        }

        var options: []ast.OptionAssignmentNode = undefined;
        if (self.nextTokenIs(.LeftCurlyBrace)) {
            // 1. Either a block with an optional semicolon.
            const optionBlock = try self.parseOptionBlock();
            options = try optionBlock.unwrap();
            _ = self.consumeOptionalTokenBool(.Semicolon);
        } else {
            // 2. or a series of option statement followed by a semicolon.
            var list = std.ArrayList(ast.OptionAssignmentNode).init(self.allocator);
            while (true) {
                const nextToken = self.it.peek(1) orelse {
                    self.addError(SyntaxError.unexpectedEOF());
                    return Error.UnexpectedToken;
                };
                if (nextToken.kind == .Semicolon) {
                    self.consume();
                    break;
                }
                try list.append(try (try self.parseOption(false, null)).unwrap());
            }
            options = list.items;
        }

        return ast.Func{
            .name = ast.Identifier{
                .value = try self.copyString(nameToken.literal),
                .range = nameToken.range(),
            },
            .options = options,
            .input = input,
            .output = output,
            .documentation = documentation,
            .tag = tag,
            .range = .{
                .start = nameToken.position,
                .endOffset = self.it.currentAssumeSafe().endOffset(),
            },
        };
    }

    fn parseFuncArg(self: *Context) Error!ast.FuncArg {
        const streaming = self.consumeOptionalTokenBool(.Stream);
        const name = try self.parseSelector();
        return ast.FuncArg{
            .name = name,
            .streaming = streaming,
        };
    }

    inline fn processGroup(self: *Context, comptime handler: fn (self: *Context) Error!void) Error!void {
        // NB: If there is no left paran '(', then it's not a group, just run the handler.
        if (!(try self.consumeOptionalEnterScopeTokenBool(.LeftParan))) {
            return handler(self);
        }

        while (true) {
            if (self.it.peek(1)) |next| {
                if (next.kind == .RightParan) {
                    self.popScopeDelimiter(.Paran);
                    self.consume();
                    break;
                } else {
                    handler(self) catch |err| switch (err) {
                        Error.UnexpectedToken => {
                            switch (self.scopeDelimiterContext()) {
                                // outside of the paran scope; stop iterating.
                                0 => break,
                                // in the paran scope; skip the current line.
                                1 => _ = try self.skipTokensUntil(&.{}, true),
                                // unlikely event, get out of the paran scope.
                                else => {
                                    try self.skipTokensUntilRootScope();
                                    break;
                                },
                            }
                        },
                        else => return err,
                    };
                }
            } else {
                self.addError(SyntaxError.unexpectedEOF());
                break;
            }
        }
    }

    fn processOption(self: *Context) Error!void {
        const modifiers = try self.parseOptionModifiers(true);

        if (self.nextTokenIs(.LeftCurlyBrace)) {
            // block mode.
            const start = self.currentPosition();
            const blockOptions = try self.parseOptionBlock();
            const rootOption = ast.OptionAssignmentNode{
                .shared = modifiers.shared,
                .raw = modifiers.raw,
                .selector = ast.Selector.init(&[_]u8{}, ast.Range.empty()),
                .range = ast.Range{ .start = start, .endOffset = self.it.currentAssumeSafe().endOffset() },
                .value = .{ .Group = try blockOptions.unwrap() },
            };
            try self.options.append(rootOption);
        } else {
            const option = try self.parseOption(false, modifiers);
            try self.options.append(try option.unwrap());
        }
    }

    fn parseOptionModifiers(self: *Context, comptime needsHashPrefix: bool) Error!OptionModifiers {
        const token = self.it.peek(1) orelse {
            if (needsHashPrefix) {
                try self.addErrorTerminal(SyntaxError.unexpectedEOF());
            }

            return .default();
        };

        switch (token.kind) {
            .Hash => {
                self.consume();
                if (!needsHashPrefix) {
                    self.addError(SyntaxError.redundantOptionHash(token.position));
                }
                return .default();
            },
            .RawHash => {
                self.consume();
                return .{ .raw = true, .shared = true };
            },
            .SharedHash => {
                self.consume();
                return .{ .shared = true, .raw = false };
            },
            else => if (needsHashPrefix) {
                self.addError(SyntaxError.expectToken(&token, "option setting modifier"));
                return Error.UnexpectedToken;
            } else return .default(),
        }
    }

    fn parseOption(
        self: *Context,
        comptime blockMode: bool,
        capturedModifiers: ?OptionModifiers,
    ) FatalError!ParseResult(ast.OptionAssignmentNode) {
        const modifiers = capturedModifiers orelse
            self.parseOptionModifiers(!blockMode) catch |err| return .initErr(err);
        const start = self.currentPosition();

        // Parse the key.
        const keyToken = self.it.peek(1) orelse {
            self.addError(SyntaxError.unexpectedEOF());
            return .initSyntaxErr();
        };
        const selector = switch (keyToken.kind) {
            .String => blk: {
                if (!modifiers.raw) {
                    self.addError(SyntaxError.rawStringOptionWithoutRawMarker(&keyToken));
                }
                self.consume();
                break :blk ast.Selector.init(keyToken.kind.String, keyToken.range());
            },
            .Identifier => self.parseSelector() catch |err| return .initErr(err),
            else => {
                self.addError(SyntaxError.expectToken(&keyToken, "option identifier or key"));
                self.consume();
                return .initSyntaxErr();
            },
        };
        // Parse the value, which can be a curly braces for blocks, a literal or nothing at all to indicate a flag.
        if (self.it.peek(1)) |valueToken| switch (valueToken.kind) {
            .LeftCurlyBrace => {
                const currentScope = self.scopeDelimiterContext();
                return switch (try self.parseOptionBlock()) {
                    .some => |v| .initValue(.{
                        .shared = modifiers.shared,
                        .raw = modifiers.raw,
                        .selector = selector,
                        .value = .{ .Group = v.data },
                        .range = .{
                            .start = start,
                            .endOffset = self.it.currentAssumeSafe().endOffset(),
                        },
                    }, v.scopeExited and (self.scopeDelimiterContext() + 1 != currentScope)),
                    .syntaxErr => .initSyntaxErr(),
                };
            },
            .Equal => {
                self.consume();
                const currentScope = self.scopeDelimiterContext();
                return switch (try self.parseValue()) {
                    .some => |v| .initValue(.{
                        .shared = modifiers.shared,
                        .raw = modifiers.raw,
                        .selector = selector,
                        .value = .{ .Leaf = v.data },
                        .range = .{
                            .start = start,
                            .endOffset = v.data.range.endOffset,
                        },
                    }, v.scopeExited and (self.scopeDelimiterContext() + 1 != currentScope)),
                    .syntaxErr => .initSyntaxErr(),
                };
            },
            else => {},
        };

        const range = ast.Range{ .start = start, .endOffset = selector.range.endOffset };
        return .initOk(.{
            .shared = modifiers.shared,
            .raw = modifiers.raw,
            .selector = selector,
            .value = .{
                .Leaf = .{
                    .value = .{ .Bool = true },
                    .range = range,
                },
            },
            .range = range,
        });
    }

    fn parseOptionBlock(self: *Context) FatalError!ParseResult([]ast.OptionAssignmentNode) {
        const OptionBlockRecoveryPoints: []const TokenKindTag = &.{
            .Comma,
            .Identifier,
            .String,
            .Hash,
            .RawHash,
            .SharedHash,
        };
        var values = std.ArrayList(ast.OptionAssignmentNode).init(self.allocator);
        _ = self.consumeRequiredToken(.LeftCurlyBrace, "{") catch |err| return .initErr(err);
        const currentScope = self.scopeDelimiterContext();
        const needsRecovery = blk: {
            while (true) {
                const token = self.it.peek(1) orelse {
                    self.addError(SyntaxError.unexpectedEOF());
                    return .initSyntaxErr();
                };
                if (token.kind == .RightCurlyBrace) {
                    self.consume();
                    self.popScopeDelimiter(.CurlyBrace);
                    break :blk false;
                }
                switch (try self.parseOption(true, null)) {
                    .some => |v| {
                        try values.append(v.data);
                        if (v.scopeExited) {
                            break :blk true;
                        }
                    },
                    .syntaxErr => if (try self.recoverSyntaxError(OptionBlockRecoveryPoints, true)) {
                        break :blk true;
                    },
                }

                _ = self.consumeOptionalTokenBool(.Comma);
            }
        };

        return .initValue(values.items, needsRecovery and (self.scopeDelimiterContext() + 1 != currentScope));
    }

    /// parses an array of ranged values.
    ///
    /// NOTE: It assumes the the left bracket is already consumed.
    fn parseValueArray(self: *Context) FatalError!ParseResult(ast.RangedValue) {
        const ArrayRecoveryPoints: []const TokenKindTag = &.{
            .String,
            .Integer,
            .Float,
            .True,
            .False,
            .LeftCurlyBrace,
            .LeftBracket,
            .Comma,
        };
        try self.pushScopeDelimiter(.Bracket);
        var values = std.ArrayList(ast.RangedValue).init(self.allocator);
        const start = self.it.currentAssumeSafe().position;
        var end: usize = undefined;
        const currentScope = self.scopeDelimiterContext();

        const needsRecovery = blk: {
            while (true) {
                const next = self.it.peek(1) orelse {
                    self.addError(SyntaxError.unexpectedEOF());
                    // TODO: would it not be better to just return UnexpectedEOF?
                    // and to provide a helper method try self.peekNextOrError()?
                    return .initSyntaxErr();
                };
                if (next.kind == .RightBracket) {
                    self.popScopeDelimiter(.Bracket);
                    self.consume();
                    end = next.endOffset();
                    break :blk false;
                }
                switch (try self.parseValue()) {
                    .some => |v| {
                        try values.append(v.data);
                        if (v.scopeExited) {
                            end = self.it.currentAssumeSafe().endOffset();
                            break :blk true;
                        }
                    },
                    .syntaxErr => if (try self.recoverSyntaxError(ArrayRecoveryPoints, false)) {
                        end = self.it.currentAssumeSafe().endOffset();
                        break :blk true;
                    },
                }
                _ = self.consumeOptionalTokenBool(.Comma);
            }
        };

        return .initValue(.{
            .value = .{ .Array = values.items },
            .range = .{ .start = start, .endOffset = end },
        }, needsRecovery and (self.scopeDelimiterContext() + 1 != currentScope));
    }

    /// parses a map of ranged values.
    ///
    /// NOTE: It assumes the the left curly brace is already consumed.
    fn parseValueObject(self: *Context) FatalError!ParseResult(ast.RangedValue) {
        const ObjectRecoveryPoints: []const TokenKindTag = &.{ .String, .Comma };
        try self.pushScopeDelimiter(.CurlyBrace);
        var values = std.ArrayList(ast.Entry).init(self.allocator);
        const start = self.it.currentAssumeSafe().position;
        var end: usize = undefined;
        const currentScope = self.scopeDelimiterContext();

        const needsRecovery = blk: {
            mainLoop: while (true) {
                const next = self.it.next() orelse {
                    self.addError(SyntaxError.unexpectedEOF());
                    return .initSyntaxErr();
                };
                switch (next.kind) {
                    .RightCurlyBrace => {
                        end = next.endOffset();
                        break :blk false;
                    },
                    .String => {
                        _ = self.consumeRequiredToken(.Equal, "=") catch |err| {
                            if (try self.recoverExitsScope(err, ObjectRecoveryPoints, false)) {
                                end = self.it.currentAssumeSafe().endOffset();
                                break :blk true;
                            }
                            _ = self.consumeOptionalTokenBool(.Comma);
                            continue :mainLoop;
                        };
                        switch (try self.parseValue()) {
                            .some => |v| {
                                try values.append(.{
                                    .key = try self.copyString(next.kind.String),
                                    .value = v.data,
                                });
                                if (v.scopeExited) {
                                    end = self.it.currentAssumeSafe().endOffset();
                                    break :blk true;
                                }
                            },
                            .syntaxErr => if (try self.recoverSyntaxError(ObjectRecoveryPoints, false)) {
                                end = self.it.currentAssumeSafe().endOffset();
                                break :blk true;
                            },
                        }
                        _ = self.consumeOptionalTokenBool(.Comma);
                    },
                    else => {
                        self.addError(SyntaxError.expectToken(&next, "key string literal"));
                        return .initSyntaxErr();
                    },
                }
            }
        };

        return .initValue(.{
            .value = .{ .Object = values.items },
            .range = .{ .start = start, .endOffset = end },
        }, needsRecovery and (self.scopeDelimiterContext() + 1 != currentScope));
    }

    fn parseValue(self: *Context) FatalError!ParseResult(ast.RangedValue) {
        const token = self.it.next() orelse {
            self.addError(SyntaxError.unexpectedEOF());
            return .initSyntaxErr();
        };
        return switch (token.kind) {
            .String => .initOk(.{
                .range = token.range(),
                .value = .{ .String = try self.copyString(token.kind.String) },
            }),
            .Integer => .initOk(.{
                .range = token.range(),
                .value = .{ .Number = token.kind.Integer },
            }),
            .Float => .initOk(.{
                .range = token.range(),
                .value = .{ .Float = token.kind.Float },
            }),
            .True => .initOk(.{
                .range = token.range(),
                .value = .{ .Bool = true },
            }),
            .False => .initOk(.{
                .range = token.range(),
                .value = .{ .Bool = false },
            }),
            .LeftBracket => self.parseValueArray(),
            .LeftCurlyBrace => self.parseValueObject(),
            else => {
                self.addError(SyntaxError.expectToken(&token, "value"));
                return .initSyntaxErr();
            },
        };
    }

    fn parseSelector(self: *Context) Error!ast.Selector {
        var dotCount: u16 = 0;
        var contentSize: usize = 0;
        var tokenCount: u16 = 0;

        const initialPosition = self.it.i;
        while (self.it.next()) |token| {
            const expectIdentifier = tokenCount % 2 == 0;
            switch (token.kind) {
                .Identifier => {
                    if (expectIdentifier) {
                        tokenCount += 1;
                        contentSize += token.literal.len;
                    } else try self.addErrorTerminal(SyntaxError.unexpectedToken(&token));
                },
                .Dot => {
                    if (!expectIdentifier) {
                        tokenCount += 1;
                        contentSize += 1;
                        dotCount += 1;
                    } else try self.addErrorTerminal(SyntaxError.unexpectedToken(&token));
                },
                else => break,
            }
        }
        if (tokenCount % 2 == 0) {
            // NB: Consume at least one token but go backwards if the unexpected token
            // comes after some other expected token.
            if (tokenCount > 0) {
                self.it.i -= 1;
            }
            if (self.it.peek(0)) |token| {
                self.addError(SyntaxError.unexpectedToken(&token));
            } else {
                self.addError(SyntaxError.unexpectedEOF());
            }
            return Error.UnexpectedToken;
        }

        self.it.i = initialPosition;
        if (dotCount == 0) {
            const segment = self.it.next().?;
            return ast.Selector.init(try self.copyString(segment.literal), segment.range());
        }

        var builder = try ast.Selector.builder(self.allocator, contentSize, dotCount + 1);
        for (0..tokenCount) |_| {
            const token = self.it.next() orelse @panic("major bug in parseSelector, incorrect tokenCount used!");
            if (std.meta.activeTag(token.kind) == .Identifier) {
                builder.appendSegment(token.literal, token.position) catch
                    @panic("major bug in parseSelector, too little allocation for the builder");
            } else {
                builder.appendSeparator() catch
                    @panic("major bug in parseSelector, too little allocation for the builder");
            }
        }
        return builder.build(self.it.data[initialPosition].rangeUntilToken(self.it.data[self.it.i - 1]));
    }

    fn parseDocumentationGroup(self: *Context) ?StagedDocumentation {
        var startIndex: ?usize = null;
        var lastDocIndex: usize = undefined;
        var lastDocLine: u16 = undefined;
        var totalContentSize: usize = 0;
        while (true) {
            const nextToken = self.it.peek(1) orelse break;
            switch (nextToken.kind) {
                .Documentation => {
                    if (startIndex == null) {
                        startIndex = self.it.i;
                    } else if (nextToken.position.line > lastDocLine + 1) {
                        // documentations are too far apart.
                        break;
                    }

                    lastDocIndex = self.it.i;
                    lastDocLine = nextToken.position.line + nextToken.kind.Documentation.newlineCount;
                    totalContentSize += nextToken.kind.Documentation.content.len + 1; // NB: 1 for the new line!
                    self.consume();
                },
                .Comment => {
                    // don't include the comment but don't break the doc group.
                    lastDocLine = nextToken.position.line;
                    self.consume();
                },
                else => break,
            }
        }

        if (totalContentSize > 0) {
            return StagedDocumentation{
                .startIndex = startIndex.?,
                .endIndex = lastDocIndex,
                .contentSize = totalContentSize,
                .lastDocLine = lastDocLine,
            };
        } else return null;
    }

    fn captureDocumentationGroup(self: *Context) Allocator.Error!void {
        if (self.parseDocumentationGroup()) |doc| {
            if (self.stagedDocumentation) |stagedDoc| {
                self.addError(SyntaxError.looseDocumentation(&self.it.data[stagedDoc.startIndex]));
            }

            self.stagedDocumentation = doc;
        }
        return;
    }

    fn consumeStagedDocumentationFor(self: *Context, position: ast.Position) Allocator.Error!?ast.Documentation {
        if (self.stagedDocumentation) |stagedDoc| {
            if (stagedDocumentationBelongsToLine(stagedDoc, position.line)) {
                defer self.stagedDocumentation = null;
                return try self.processStagedDocumentation(stagedDoc);
            }
        }
        return null;
    }

    fn parseDocumentationGroupForCurrentPosition(self: *Context) Allocator.Error!?ast.Documentation {
        var token = self.it.peek(1) orelse return null;
        if (try self.consumeStagedDocumentationFor(token.position)) |doc| {
            return doc;
        }

        if (self.parseDocumentationGroup()) |doc| {
            token = self.it.peek(1) orelse return null;
            if (stagedDocumentationBelongsToLine(doc, token.position.line)) {
                return try self.processStagedDocumentation(doc);
            } else self.addError(SyntaxError.looseDocumentation(&token));
        }

        return null;
    }

    fn processStagedDocumentation(self: *Context, stagedDoc: StagedDocumentation) Allocator.Error!ast.Documentation {
        var contentBuffer = try std.ArrayList(u8).initCapacity(self.allocator, stagedDoc.contentSize);
        for (stagedDoc.startIndex..stagedDoc.endIndex + 1) |index| {
            if (self.it.data[index].kind == .Documentation) {
                contentBuffer.appendSliceAssumeCapacity(self.it.data[index].kind.Documentation.content);
                contentBuffer.appendAssumeCapacity('\n');
            }
        }
        return ast.Documentation{
            .content = contentBuffer.items,
        };
    }

    /// whether or not the next token is a top-level AST object captures documentation
    /// such as a message, enum, interface or const.
    fn nextTokenAcceptsTopLevelDocumentation(self: *const Context, stagedDoc: StagedDocumentation) bool {
        const nextToken = self.it.peek(1) orelse return false;
        switch (nextToken.kind) {
            .Message, .Enum, .Const, .Interface => {
                return stagedDocumentationBelongsToLine(stagedDoc, nextToken.position.line);
            },
            else => return false,
        }
    }

    inline fn stagedDocumentationBelongsToLine(
        stagedDoc: StagedDocumentation,
        line: u16,
    ) bool {
        return stagedDoc.lastDocLine <= line and line <= stagedDoc.lastDocLine + 1;
    }

    fn addError(self: *Context, err: SyntaxError) void {
        if (self.errors.len == self.errors.capacity()) {
            return;
        }
        self.errors.appendAssumeCapacity(err);
    }

    /// allocates precisely the amount necessary to store errors.
    fn buildErrors(self: Context) std.mem.Allocator.Error![]const SyntaxError {
        const errors = try self.allocator.alloc(SyntaxError, self.errors.len);
        @memcpy(errors, self.errors.slice());
        return errors;
    }

    /// addErrorTerminal always returns an error. It is a convenient way to add error and then return UnexpectedToken.
    inline fn addErrorTerminal(self: *Context, err: SyntaxError) Error!void {
        self.addError(err);
        return Error.UnexpectedToken;
    }

    inline fn consumeRequiredToken(
        self: *Context,
        comptime tag: TokenKindTag,
        comptime expectedToken: ?[]const u8,
    ) !scanner.Token {
        if (self.it.next()) |token| {
            if (std.meta.activeTag(token.kind) == tag) {
                // in a successful match, if the token kind is a delimiter, handle the scope change.
                if (comptime std.mem.indexOfScalar(TokenKindTag, ScopeDelimiterTokens, tag) != null) {
                    try self.handleScopeDelimiter(tag);
                }
                return token;
            }
            // error state
            if (expectedToken) |name| {
                self.addError(SyntaxError.expectToken(&token, name));
            } else {
                self.addError(SyntaxError.unexpectedToken(&token));
            }
            return Error.UnexpectedToken;
        } else {
            self.addError(SyntaxError.unexpectedEOF());
            return Error.UnexpectedToken;
        }
    }

    inline fn consumeOptionalTokenBool(self: *Context, comptime tag: TokenKindTag) bool {
        // ensure that no scope delimiter token gets used with this function.
        comptime if (std.mem.indexOfScalar(TokenKindTag, ScopeDelimiterTokens, tag)) |_| {
            @compileError(
                "do not use scope delimiter tokens such as " ++ @tagName(tag) ++
                    " with this fn, instead use consumeOptional[Enter/Exit]ScopeTokenBool",
            );
        };

        if (self.it.peek(1)) |token| {
            if (std.meta.activeTag(token.kind) == tag) {
                defer self.consume();
                return true;
            }
        }
        return false;
    }

    inline fn consumeOptionalEnterScopeTokenBool(
        self: *Context,
        comptime tag: TokenKindTag,
    ) error{NestingDepthReached}!bool {
        if (self.it.peek(1)) |token| {
            if (std.meta.activeTag(token.kind) == tag) {
                defer self.consume();
                try self.handleEnterScopeDelimiter(tag);
                return true;
            }
        }
        return false;
    }

    inline fn consumeOptionalExitScopeTokenBool(
        self: *Context,
        comptime tag: TokenKindTag,
    ) bool {
        if (self.it.peek(1)) |token| {
            if (std.meta.activeTag(token.kind) == tag) {
                defer self.consume();
                self.handleExitScopeDelimiter(tag);
                return true;
            }
        }
        return false;
    }

    inline fn nextTokenIs(self: *const Context, tag: TokenKindTag) bool {
        if (self.it.peek(1)) |token| {
            if (std.meta.activeTag(token.kind) == tag) {
                return true;
            }
        }
        return false;
    }

    inline fn consumeOptionalToken(self: *Context, tag: TokenKindTag) ?scanner.Token {
        // ensure that no scope delimiter token gets used with this function.
        comptime if (std.mem.indexOfScalar(TokenKindTag, ScopeDelimiterTokens, tag)) |_| {
            @compileError(
                "do not use scope delimiter tokens such as " ++ @tagName(tag) ++
                    " with this fn, instead use consumeOptionalScopeTokenBool",
            );
        };

        if (self.it.peek(1)) |token| {
            if (std.meta.activeTag(token.kind) == tag) {
                defer self.consume();
                return self.it.data[self.it.i];
            }
        }
        return null;
    }

    inline fn consume(self: *Context) void {
        self.it.i += 1;
    }

    inline fn copyString(self: Context, ref: []const u8) Allocator.Error![]const u8 {
        const data = try self.allocator.alloc(u8, ref.len);
        std.mem.copyForwards(u8, data, ref);
        return data;
    }

    inline fn currentPosition(self: Context) ast.Position {
        const token = self.it.peek(1) orelse return ast.Position.empty(); // NB: not reachable.
        return token.position;
    }

    inline fn pushScopeDelimiter(self: *Context, delimiter: ScopeDelimiter) error{NestingDepthReached}!void {
        self.scopeDelimiters.append(delimiter) catch return Error.NestingDepthReached;
    }

    inline fn scopeDelimiterContext(self: Context) usize {
        return self.scopeDelimiters.len;
    }

    /// Search from the back (end) until the delimiter is found, all the iterated over delimiters get
    /// ignored.
    inline fn popScopeDelimiter(self: *Context, delimiter: ScopeDelimiter) void {
        while (self.scopeDelimiters.pop()) |poppedDelimiter| {
            if (poppedDelimiter == delimiter) break;
        }
    }

    /// Skips tokens until encountering one of the specified token kinds. The matching token will NOT be consumed.
    ///
    /// Parameters:
    ///   - If `untilEndOfLine` is true, only tokens in the current line are processed.
    ///
    /// Scope handling:
    ///   - The function respects scope boundaries - if the current scope ends before finding a matching token,
    ///     the search terminates.
    ///   - Opening and closing scope delimiters encountered during scanning are properly tracked to maintain
    ///     correct scope nesting.
    ///
    /// Returns whether or not current scope is exited.
    fn skipTokensUntil(
        self: *Context,
        comptime kinds: []const TokenKindTag,
        comptime untilEndOfLine: bool,
    ) error{NestingDepthReached}!bool {
        var currentLine = (self.it.peek(0) orelse return false).position.line;
        const currentScope = self.scopeDelimiterContext();
        if (try self.handleScopeDelimiterRecovery(self.it.currentAssumeSafe().kind, currentScope)) {
            self.consume();
            return true;
        }
        while (true) {
            const token = self.it.peek(1) orelse return false;
            if (token.kind == .EOF) {
                return false;
            }
            if (untilEndOfLine) {
                // skipping the line is only applicable in the same scope.
                if (token.position.line != currentLine and self.scopeDelimiterContext() == currentScope) {
                    return false;
                }
            } else {
                if (token.position.line >= currentLine + 2 and self.scopeDelimiterContext() == 0) {
                    return false;
                }
            }

            if (try self.handleScopeDelimiterRecovery(token.kind, currentScope)) {
                self.consume();
                return true;
            }

            // consider recovery tokens only if still in the same scope.
            if (self.scopeDelimiterContext() == currentScope) {
                inline for (kinds) |kind| {
                    if (token.kind == kind) {
                        return false;
                    }
                }
            }
            if (!untilEndOfLine) {
                currentLine = token.position.line;
            }
            self.consume();
        }
    }

    /// recover from an UnexpectedToken error (if the err is an UnexpectedToken) using the following
    /// strategy:
    /// * If inside a scope: iterate until then next entry point tokens or if it goes out of the current scope.
    /// * If outside a scope: find the next entrypoint.
    inline fn recover(
        self: *Context,
        err: anytype,
        comptime tokens: []const TokenKindTag,
        comptime untilEndOfLine: bool,
    ) !void {
        if (err != Error.UnexpectedToken) {
            return err;
        }

        self.it.i -= 1; // revert the token consumption.
        if (self.scopeDelimiterContext() > 0) {
            // NB: Inside a scope, go until you find next entry token or falling outside of the
            // current scope.
            _ = try self.skipTokensUntil(tokens, untilEndOfLine);
        } else {
            _ = try self.skipTokensUntil(EntryKeywords, untilEndOfLine);
        }
    }

    /// similar to recover but returns whether or not the current scope is exited.
    /// This is helpful for nested structures such as parsing values, objects, options, etc.
    inline fn recoverExitsScope(
        self: *Context,
        err: Error,
        comptime tokens: []const TokenKindTag,
        comptime untilEndOfLine: bool,
    ) FatalError!bool {
        return switch (err) {
            error.UnexpectedToken => self.recoverSyntaxError(tokens, untilEndOfLine),
            else => |e| e,
        };
    }

    /// similar to recover but returns whether or not the current scope is exited.
    /// This is helpful for nested structures such as parsing values, objects, options, etc.
    // TODO: name is not great, we should rename this so it conveys the intent.
    inline fn recoverSyntaxError(
        self: *Context,
        comptime tokens: []const TokenKindTag,
        comptime untilEndOfLine: bool,
    ) error{NestingDepthReached}!bool {
        self.it.i -= 1; // revert the token consumption.
        // NB: Inside a scope, go until you find next entry token or falling outside of the
        // current scope.
        if (self.scopeDelimiterContext() > 0)
            return self.skipTokensUntil(tokens, untilEndOfLine)
        else
            return self.skipTokensUntil(EntryKeywords, untilEndOfLine);
    }

    /// similar to handleScopeDelimiter but specifically for comptime and enter tokens.
    inline fn handleEnterScopeDelimiter(self: *Context, comptime kind: TokenKindTag) error{NestingDepthReached}!void {
        switch (kind) {
            .LeftCurlyBrace => try self.pushScopeDelimiter(.CurlyBrace),
            .LeftBracket => try self.pushScopeDelimiter(.Bracket),
            .LeftParan => try self.pushScopeDelimiter(.Paran),
            else => @compileError("used '" ++ @tagName(kind) ++ "' as an enter delimiter token"),
        }
    }

    /// similar to handleScopeDelimiter but specifically for comptime and exit tokens. The benefit, aside from comptime
    /// is that it does not need to return any error.
    inline fn handleExitScopeDelimiter(self: *Context, comptime kind: TokenKindTag) void {
        switch (kind) {
            .RightCurlyBrace => self.popScopeDelimiter(.CurlyBrace),
            .RightBracket => self.popScopeDelimiter(.Bracket),
            .RightParan => self.popScopeDelimiter(.Paran),
            else => @compileError("used '" ++ @tagName(kind) ++ "' as an exit delimiter token"),
        }
    }

    /// handleScopeDelimiter handles pushing and popping scope delimiters for the token.
    inline fn handleScopeDelimiter(self: *Context, kind: TokenKindTag) error{NestingDepthReached}!void {
        switch (kind) {
            .LeftCurlyBrace => try self.pushScopeDelimiter(.CurlyBrace),
            .RightCurlyBrace => self.popScopeDelimiter(.CurlyBrace),
            .LeftBracket => try self.pushScopeDelimiter(.Bracket),
            .RightBracket => self.popScopeDelimiter(.Bracket),
            .LeftParan => try self.pushScopeDelimiter(.Paran),
            .RightParan => self.popScopeDelimiter(.Paran),
            else => {},
        }
    }

    /// update the scope context if needed. Increasing the nesting if an opening token is given
    /// or decreasing if a closnig token is given. Similar to handleScopeDelimiter but specialized for recovery.
    /// Returns whether or not current scope is exited.
    inline fn handleScopeDelimiterRecovery(
        self: *Context,
        kind: TokenKindTag,
        scope: usize,
    ) error{NestingDepthReached}!bool {
        try self.handleScopeDelimiter(kind);
        return self.scopeDelimiterContext() < scope;
    }

    inline fn skipTokensUntilRootScope(self: *Context) Error!void {
        while (self.scopeDelimiterContext() > 0) {
            if (try self.handleScopeDelimiterRecovery((self.it.next() orelse return).kind, 0)) {
                return;
            }
        }
    }
};

const ParseError = scanner.TokenizeError;

pub const Result = struct {
    allocator: std.heap.ArenaAllocator,
    document: ast.Document,
    errors: []const SyntaxError,

    pub fn deinit(self: *Result) void {
        self.allocator.deinit();
    }

    pub fn ok(self: Result) bool {
        return self.errors.len == 0;
    }
};

pub fn parse(allocator: Allocator, content: []const u8) ParseError!Result {
    var resultAllocator = std.heap.ArenaAllocator.init(allocator);
    errdefer resultAllocator.deinit();

    var scanResult = try scanner.tokenize(allocator, content);
    defer scanResult.deinit();

    var ctx = Context.init(resultAllocator.allocator(), scanResult.tokens);
    for (scanResult.errors) |scanError| {
        ctx.addError(SyntaxError{
            .message = scanError.message,
            .literal = scanError.literal,
            .location = .{ .Position = scanError.position },
        });
    }
    try ctx.parse();

    return .{
        .allocator = resultAllocator,
        .errors = try ctx.buildErrors(),
        .document = .{
            .pact = ctx.pact,
            .imports = ctx.imports.items,
            .options = ctx.options.items,
            .constants = ctx.constants.items,
            .enums = ctx.enums.items,
            .messages = ctx.messages.items,
            .optionDefinitions = ctx.optionDefinitions.items,
            .interfaces = ctx.interfaces.items,
            .documentation = ctx.documentation,
        },
    };
}

test "token-iterator" {
    const t = std.testing;
    const tokens = [_]scanner.Token{
        .{
            .kind = .Pact,
            .position = ast.Position.empty(),
            .literal = "",
        },
        .{
            .kind = .Dot,
            .position = ast.Position.empty(),
            .literal = "",
        },
        .{
            .kind = .Colon,
            .position = ast.Position.empty(),
            .literal = "",
        },
    };

    var it = TokenIterator.init(tokens[0..]);

    // test peek at current position.
    try t.expectEqual(null, it.peek(0));
    try t.expectEqual(tokens[0], it.peek(1).?);
    try t.expectEqual(tokens[1], it.peek(2).?);
    try t.expectEqual(tokens[2], it.peek(3).?);
    try t.expectEqual(null, it.peek(4));

    var index: usize = 0;
    while (it.next()) |value| {
        try t.expectEqual(tokens[index], value);
        index += 1;
    }

    try t.expectEqual(null, it.peek(1));
}
