// TODO: * Use group ID to learn if a decl is inside a paran group.
//       * Avoid infinite loop while recovery, you can store the position or range of the last recovered token.

const std = @import("std");
const tokenizer = @import("tokenizer.zig");
const ast = @import("ast.zig");

const StackArray = @import("stack_array.zig").StackArray;
const StackFallbackArray = @import("stack_array.zig").StackFallbackArray;

const Allocator = std.mem.Allocator;

const Error = error{ UnexpectedToken, UnexpectedEOF, NestingDepthReached } || Allocator.Error;

const AnnotationModifiers = struct {
    extra: bool = false,
    private: bool = false,
    profiles: []const ast.Identifier = &.{},

    const default: AnnotationModifiers = .{};
};

/// Accumulated and staged set of documentation lines.
const StagedDocumentation = struct {
    const Store = StackFallbackArray([]const u8, 32);

    /// documentation content boundaries, each slice represents one line of documentation.
    boundaries: Store,
    content_size: usize,
    start: usize,
    encountered_package_error: bool = false,

    fn init(allocator: std.mem.Allocator) StagedDocumentation {
        return .{
            .boundaries = .init(allocator),
            .content_size = 0,
            .start = 0,
        };
    }

    fn empty(self: *const StagedDocumentation) bool {
        return self.boundaries.len() == 0;
    }

    fn reset(self: *StagedDocumentation) void {
        self.boundaries.clear();
        self.content_size = 0;
    }
};

pub const PragmaError = struct {
    pub const Location = union(enum) {
        position: usize,
        range: ast.Range,
    };

    pub const Code = enum {
        NestingDepthReached,
        UnexpectedToken,
        UnexpectedEOF,
        RedundantAnnotationHash,
        ExtraAnnotationWithoutSigil,
        UnusedDocumentation,
        UnexpectedPackageDocumentation,
        EnumVariantNumericalError,
        FieldTagError,
        FuncTagError,
        UnsupportedPragmaKeyword,
        SyntaxError,
    };

    code: Code,
    message: []const u8,
    location: ?Location,

    fn nestingDepthReached(position: usize) PragmaError {
        return .{
            .code = .NestingDepthReached,
            .message = "maximum nesting level of 10 reached",
            .location = Location{ .position = position },
        };
    }

    fn unexpectedToken(token: *const tokenizer.Token) PragmaError {
        if (token.kind == .EOF) {
            return .unexpectedEOF();
        }

        return .{
            .code = .UnexpectedToken,
            .message = "unexpected token",
            .location = Location{ .range = token.range },
        };
    }

    fn redundantAnnotationHash(position: usize) PragmaError {
        return .{
            .code = .RedundantAnnotationHash,
            .message = "redundant use of annotation symbol # in annotation block",
            .location = Location{ .position = position },
        };
    }

    fn extraAnnotationWithoutSigil(token: *const tokenizer.Token) PragmaError {
        return .{
            .code = .ExtraAnnotationWithoutSigil,
            .message = "use of extra annotation (attribute) without extra modifier, did you mean to use x# ?",
            .location = Location{ .range = token.range },
        };
    }

    fn unusedDocumentation(position: usize) PragmaError {
        return .{
            .code = .UnusedDocumentation,
            .message = "unused documentation, use plain comments instead",
            .location = Location{ .position = position },
        };
    }

    fn unexpectedPackageDocumentation(position: usize) PragmaError {
        return .{
            .code = .UnexpectedPackageDocumentation,
            .message = "unexpected package documentation",
            .location = .{ .position = position },
        };
    }

    fn unexpectedEOF() PragmaError {
        return .{
            .code = .UnexpectedEOF,
            .message = "unexpected end of file",
            .location = Location{ .position = 0 },
        };
    }

    fn enumVariantNumericalError(token: *const tokenizer.Token) PragmaError {
        return .{
            .code = .EnumVariantNumericalError,
            .message = "enum value must be a positive integer from 0 to 2^32-1",
            .location = Location{ .range = token.range },
        };
    }

    fn fieldTagNumericalError(token: *const tokenizer.Token) PragmaError {
        return .{
            .code = .FieldTagError,
            .message = "field tag value must be a positive integer from 1 to 2^32-1",
            .location = Location{ .range = token.range },
        };
    }

    fn funcTagNumericalError(token: *const tokenizer.Token) PragmaError {
        return .{
            .code = .FuncTagError,
            .message = "func tag value must be a positive integer from 1 to 2^32-1",
            .location = Location{ .range = token.range },
        };
    }

    fn unsupportedPragmaKeyword(token: *const tokenizer.Token) PragmaError {
        return .{
            .code = .UnsupportedPragmaKeyword,
            .message = "Unexpected pragma function, did you mean to use @ref()?",
            .location = Location{ .range = token.range },
        };
    }

    fn expectToken(token: *const tokenizer.Token, comptime expected: []const u8) PragmaError {
        if (token.kind == .EOF) {
            return .unexpectedEOF();
        }

        return .{
            .code = .UnexpectedToken,
            .message = "expected " ++ expected,
            .location = Location{ .range = token.range },
        };
    }
};

/// Result of a parse operation with some partial or complete data.
/// If the parse operation is successful or partial but with a successful recovery, needs_recovery is false.
/// If recovery leads to escaping the parent scope, then needs_recovery is set to true
/// and means the caller's scope is possibly exited.
fn ParseResult(T: type) type {
    return struct {
        /// data is the completely or partially parsed data.
        data: T,
        needs_recovery: bool,

        const Self = @This();

        fn initOk(value: T) Self {
            return .{ .data = value, .needs_recovery = false };
        }

        fn init(value: T, needs_recovery: bool) Self {
            return .{ .data = value, .needs_recovery = needs_recovery };
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
    const ErrorList = StackArray(PragmaError, 10);
    const ScopeDelimiterList = StackArray(ScopeDelimiter, 10);

    const TokenKindTag = std.meta.Tag(tokenizer.TokenKind);

    allocator: Allocator,
    transient_allocator: std.mem.Allocator,
    it: tokenizer.Iterator,
    errors: ErrorList = .init(),
    scope_delimiters: ScopeDelimiterList = .init(),
    staged_documentation: StagedDocumentation,

    imports: std.ArrayList(ast.Import) = .empty,
    annotations: std.ArrayList(ast.AnnotationNode) = .empty,
    constants: std.ArrayList(ast.Constant) = .empty,
    enums: std.ArrayList(ast.Enum) = .empty,
    structs: std.ArrayList(ast.Struct) = .empty,
    annotation_definitions: std.ArrayList(ast.AnnotationDefinition) = .empty,
    protocols: std.ArrayList(ast.Protocol) = .empty,
    documentation: ?ast.Documentation = null,

    field_types: StackFallbackArray(ast.Field.RangedType, 32),

    const AnnotationStartTokens = [_]TokenKindTag{
        .Hash,
        .ExtraHash,
        .PrivateHash,
        .PrivateExtraHash,
        .ExtraMode,
        .PrivateMode,
        .PrivateExtraMode,
    };

    const EntryKeywords = &([_]TokenKindTag{
        .Import,
        .Const,
        .Enum,
        .Struct,
        .Annotation,
        .Protocol,
        .Documentation,
    } ++ AnnotationStartTokens);

    const ScopeDelimiterTokens: []const TokenKindTag = &.{
        .LeftCurlyBrace,
        .LeftBracket,
        .LeftParan,
        .RightCurlyBrace,
        .RightBracket,
        .RightParan,
    };

    const EnumBodyRecoveryPoints = &([_]TokenKindTag{
        .Identifier,
        .Documentation,
        .Comma,
    } ++ AnnotationStartTokens);

    const MessageBodyRecoveryPoints = &([_]TokenKindTag{
        .Identifier,
        .Embed,
        .Documentation,
        .OneOf,
        .Comma,
    } ++ AnnotationStartTokens);

    const InterfaceBodyRecoveryPoints = &([_]TokenKindTag{
        .Identifier,
        .Documentation,
        .Comma,
        .Semicolon,
    } ++ AnnotationStartTokens);

    fn init(allocator: Allocator, transient_allocator: Allocator, token_iterator: tokenizer.Iterator) Context {
        return .{
            .allocator = allocator,
            .transient_allocator = transient_allocator,
            .it = token_iterator,
            .staged_documentation = .init(transient_allocator),
            .field_types = .init(transient_allocator),
        };
    }

    fn parse(self: *Context) ParseError!void {
        self.it.fillTokenBufferIfNeeded();
        // Read and set package documentation.
        try self.consumePackageDocumentation();

        while (self.it.next()) |token| {
            (switch (token.kind) {
                .Import => self.processImport(),
                .ExtraHash, .Hash, .PrivateHash, .ExtraMode, .PrivateExtraMode, .PrivateMode => annotation: {
                    // NB: Special case where we need to consume the first token itself.
                    self.it.goBack();
                    break :annotation self.processAnnotation();
                },
                .Const => self.processConst(),
                .Enum => self.processEnum(),
                .Struct => self.processStruct(),
                .Annotation => self.processAnnotationDefinition(),
                .Protocol => self.processProtocol(),
                .Documentation => documentation: {
                    // NB: Special case where we need to consume the first token itself.
                    self.it.goBack();
                    break :documentation self.stageDocumentationGroup();
                },
                .EOF => break,
                else => blk: {
                    self.addError(PragmaError.unexpectedToken(&token));
                    _ = self.skipTokensUntil(EntryKeywords) catch |err| break :blk err;
                },
            }) catch |err| switch (err) {
                Allocator.Error.OutOfMemory => return Allocator.Error.OutOfMemory,
                Error.NestingDepthReached => {
                    self.addError(PragmaError.nestingDepthReached(self.currentRangeAssumeSafe().start));
                    return;
                },
                Error.UnexpectedToken => {
                    self.it.goBack();
                    _ = self.skipTokensUntil(EntryKeywords) catch {
                        self.addError(PragmaError.nestingDepthReached(self.currentRangeAssumeSafe().start));
                        return;
                    };
                },
                Error.UnexpectedEOF => return,
            };
        }
    }

    fn processImport(self: *Context) Error!void {
        const recovery_points: []const TokenKindTag = &.{ .String, .Hash, .Identifier };
        try self.processGroupNew(recovery_points, processImportBody);
    }

    fn processImportBody(self: *Context) Error!void {
        var start: ?usize = null;
        const bare = self.consumeOptionalTokenBool(.Hash);
        var alias: ?ast.Identifier = null;

        if (bare) {
            start = self.currentRangeAssumeSafe().start;
        }

        if (self.consumeOptionalToken(.Identifier)) |alias_token| {
            alias = .{ .value = try self.copyString(alias_token.literal), .range = alias_token.range };
            start = start orelse alias_token.range.start;
        }

        const path_token = try self.consumeRequiredToken(.String, "path string");
        try self.imports.append(self.allocator, .{
            .bare = bare,
            .alias = alias,
            .path = .{
                .value = try path_token.kind.String.toOwnedAndEscaped(self.allocator),
                .range = path_token.range,
            },
            .range = .{ .start = start orelse path_token.range.start, .end = path_token.range.end },
        });
    }

    fn processConst(self: *Context) Error!void {
        const recovery_points: []const TokenKindTag = &.{ .Documentation, .Identifier };
        try self.processGroupNew(recovery_points, processConstBody);
    }

    inline fn addConst(
        self: *Context,
        name: tokenizer.Token,
        value: ast.RangedLiteral,
        documentation: ?ast.Documentation,
        start: usize,
        annotations: ast.AnnotationGroup,
    ) Allocator.Error!void {
        try self.constants.append(self.allocator, ast.Constant{
            .name = .{ .value = try self.copyString(name.literal), .range = name.range },
            .value = value,
            .documentation = documentation,
            .annotations = annotations,
            .range = .{ .start = start, .end = self.currentRangeAssumeSafe().end },
        });
    }

    fn processConstBody(self: *Context) Error!void {
        const documentation = try self.consumeStagedDocumentation();
        const name_token = try self.consumeRequiredToken(.Identifier, "const name");
        _ = try self.consumeRequiredToken(.Equal, "=");

        const value = try self.parseValue();
        if (value.needs_recovery) {
            try self.addConst(name_token, value.data, documentation, name_token.range.start, .empty);
            return;
        }

        if (!self.nextTokenIs(.LeftCurlyBrace)) {
            try self.addConst(name_token, value.data, documentation, name_token.range.start, .empty);
            return;
        }
        if (self.parseAnnotationBlock()) |v| {
            const block: ast.AnnotationGroup = .{ .values = v.data, .block = true };
            try self.addConst(name_token, value.data, documentation, name_token.range.start, block);
            if (v.needs_recovery) {
                return error.UnexpectedToken;
            }
        } else |err| {
            try self.addConst(name_token, value.data, documentation, name_token.range.start, .empty);
            return err;
        }
    }

    fn processEnum(self: *Context) Error!void {
        const recovery_points: []const TokenKindTag = &.{ .Documentation, .Identifier };
        try self.processGroupNew(recovery_points, processEnumBody);
    }

    fn processEnumBody(self: *Context) Error!void {
        const recovery_points: []const TokenKindTag = &.{ .Documentation, .Identifier };
        const documentation = try self.consumeStagedDocumentation();
        const name_token = try self.consumeRequiredToken(.Identifier, "enum name");
        _ = try self.consumeRequiredToken(.LeftCurlyBrace, "{");
        const current_scope = self.scopeDelimiterContext();

        var annotations = StackFallbackArray(ast.AnnotationNode, 32).init(self.transient_allocator);
        var variants = StackFallbackArray(ast.EnumVariant, 32).init(self.transient_allocator);

        while (true) {
            const token = self.peekNextOrError() catch break;
            switch (token.kind) {
                .Hash, .ExtraHash, .PrivateHash, .ExtraMode, .PrivateMode, .PrivateExtraMode => {
                    if (self.parseAnnotation(false, null)) |v| {
                        try annotations.append(v.data);
                        if (v.needs_recovery and try self.skipTokensUntilScope(recovery_points, current_scope)) {
                            break;
                        }
                    } else |err| if (try self.recoverExitsScope(err, recovery_points, current_scope)) {
                        break;
                    }
                },
                .Identifier => if (self.parseEnumVariant()) |v| {
                    try variants.append(v.data);
                    if (v.needs_recovery and try self.skipTokensUntilScope(recovery_points, current_scope)) {
                        break;
                    }
                } else |err| if (try self.recoverExitsScope(err, recovery_points, current_scope)) {
                    break;
                },
                .Documentation => try self.stageDocumentationGroup(),
                .RightCurlyBrace => {
                    self.consume();
                    self.popScopeDelimiter(.CurlyBrace);
                    break;
                },
                .Comma => self.consume(),
                else => {
                    self.addError(PragmaError.unexpectedToken(&token));
                    if (try self.skipTokensUntilScope(recovery_points, current_scope)) {
                        break;
                    }
                },
            }
        }
        
        try self.enums.append(self.allocator, ast.Enum{
            .name = ast.Identifier{
                .value = try self.copyString(name_token.literal),
                .range = name_token.range,
            },
            .variants = try variants.toOwnedSlice(self.allocator),
            .documentation = documentation,
            .annotations = try annotations.toOwnedSlice(self.allocator),
            .range = .{ .start = name_token.range.start, .end = self.currentRangeAssumeSafe().end },
        });
    }

    inline fn buildEnumVariant(
        self: *Context,
        name_token: tokenizer.Token,
        value: ?u32,
        documentation: ?ast.Documentation,
        annotations: ast.AnnotationGroup,
    ) Allocator.Error!ast.EnumVariant {
        return .{
            .name = ast.Identifier{
                .value = try self.copyString(name_token.literal),
                .range = name_token.range,
            },
            .value = value,
            .documentation = documentation,
            .annotations = annotations,
            .range = .{
                .start = name_token.range.start,
                .end = self.currentRangeAssumeSafe().end,
            },
        };
    }

    fn parseEnumVariant(self: *Context) Error!ParseResult(ast.EnumVariant) {
        const recovery_points: []const TokenKindTag = &.{
            .Hash, .ExtraHash, .PrivateHash, .ExtraMode, .PrivateMode, .PrivateExtraMode, .Comma
        };
        const documentation = try self.consumeStagedDocumentation();
        const name_token = try self.consumeRequiredToken(.Identifier, "enum value");
        const current_scope = self.scopeDelimiterContext();
        var value: ?u32 = null;

        if (self.consumeOptionalTokenBool(.Equal)) {
            // explicit assignment.
            if (self.consumeRequiredToken(.Integer, "enum variant numerical value")) |value_token| {
                if (std.math.cast(u32, value_token.kind.Integer)) |tag| {
                    value = tag;
                } else self.addError(PragmaError.enumVariantNumericalError(&value_token));
            } else |err| return .init(
                try self.buildEnumVariant(name_token, null, documentation, .empty),
                try self.recoverExitsScope(err, recovery_points, current_scope),
            );
        }

        return if (self.parseItemAnnotations(.Comma)) |v| .init(
            try self.buildEnumVariant(name_token, value, documentation, v.data),
            v.needs_recovery,
        ) else |err| .init(
            try self.buildEnumVariant(name_token, value, documentation, .empty),
            try self.recoverExitsScope(err, recovery_points, current_scope),
        );
    }

    fn processStruct(self: *Context) Error!void {
        const recovery_points: []const TokenKindTag = &.{ .Documentation, .Identifier };
        try self.processGroupNew(recovery_points, processStructBody);
    }

    fn processStructBody(self: *Context) Error!void {
        const recovery_points: []const TokenKindTag = &.{ .Documentation, .Identifier, .Comma, .OneOf };
        const documentation = try self.consumeStagedDocumentation();
        const name_token = try self.consumeRequiredToken(.Identifier, "struct name");
        _ = try self.consumeRequiredToken(.LeftCurlyBrace, "{");
        const current_scope = self.scopeDelimiterContext();

        var annotations = StackFallbackArray(ast.AnnotationNode, 16).init(self.transient_allocator);
        var members = StackFallbackArray(ast.Struct.Member, 48).init(self.transient_allocator);
        var oneof_groups = StackFallbackArray(ast.OneOf, 8).init(self.transient_allocator);

        while (true) {
            const token = self.peekNextOrError() catch break;
            switch (token.kind) {
                .Comma => self.consume(),
                .Documentation => try self.stageDocumentationGroup(),
                .Hash, .ExtraHash, .PrivateHash, .PrivateMode, .ExtraMode, .PrivateExtraMode => {
                    if (self.parseAnnotation(false, null)) |v| {
                        try annotations.append(v.data);
                        if (v.needs_recovery and try self.skipTokensUntilScope(recovery_points, current_scope)) {
                            break;
                        }
                    } else |err| if (try self.recoverExitsScope(err, recovery_points, current_scope)) {
                        break;
                    }
                },
                .Identifier => if (self.parseField(null)) |v| {
                    try members.append(.{ .field = v.data });
                    if (v.needs_recovery and try self.skipTokensUntilScope(recovery_points, current_scope)) {
                        break;
                    }
                } else |err| if (try self.recoverExitsScope(err, &.{.Comma}, current_scope)) {
                    break;
                },
                .Embed => {
                    self.consume();
                    if (self.parseKeyPath()) |key_path| {
                        try members.append(.{ .embed = key_path });
                    } else |err| if (try self.recoverExitsScope(err, recovery_points, current_scope)) {
                        break;
                    }
                },
                .OneOf => {
                    const start = token.range.start;
                    self.consume();
                    const oneof_name_token = self.consumeRequiredToken(.Identifier, "oneof group name") catch |err|
                        if (try self.recoverExitsScope(err, recovery_points, current_scope))
                            break else continue;
                    const S = struct {
                        fn addField(ctx: *@TypeOf(members), field: ast.Field) Error!void {
                            try ctx.append(.{ .field = field });
                        }
                    };
                    if (self.processOneOfBody(@intCast(oneof_groups.len()), &members, S.addField)) |v| {
                        try oneof_groups.append(ast.OneOf{
                            .name = ast.Identifier{
                                .value = try self.copyString(oneof_name_token.literal),
                                .range = name_token.range,
                            },
                            .annotations = v.data.annotations,
                            .range = ast.Range{
                                .start = start,
                                .end = self.currentRangeAssumeSafe().end,
                            },
                        });
                    } else |err| if (try self.recoverExitsScope(err, recovery_points, current_scope)) {
                        break;
                    }
                },
                .RightCurlyBrace => {
                    self.consume();
                    self.popScopeDelimiter(.CurlyBrace);
                    break;
                },
                else => {
                    self.addError(PragmaError.unexpectedToken(&token));
                    if (try self.skipTokensUntilScope(recovery_points, current_scope)) {
                        break;
                    }
                },
            }
        }

        try self.structs.append(self.allocator, ast.Struct{
            .name = ast.Identifier{
                .value = try self.copyString(name_token.literal),
                .range = name_token.range,
            },
            .documentation = documentation,
            .members = try members.toOwnedSlice(self.allocator),
            .annotations = try annotations.toOwnedSlice(self.allocator),
            .oneof_groups = try oneof_groups.toOwnedSlice(self.allocator),
            .range = .{ .start = name_token.range.start, .end = self.currentRangeAssumeSafe().end },
        });
    }

    inline fn buildField(
        self: *Context,
        name_token: tokenizer.Token,
        documentation: ?ast.Documentation,
        annotations: ast.AnnotationGroup,
        tag: ?u16,
        data_type: ast.Field.RangedType,
        oneof_group_index: ?u16,
    ) Allocator.Error!ast.Field {
        return ast.Field{
            .name = .{
                .value = try self.copyString(name_token.literal),
                .range = name_token.range,
            },
            .documentation = documentation,
            .annotations = annotations,
            .range = ast.Range{
                .start = name_token.range.start,
                .end = self.currentRangeAssumeSafe().end,
            },
            .tag = tag,
            .data_type = data_type,
            .oneof_group_index = oneof_group_index,
        };
    }

    fn parseField(self: *Context, oneof_group_index: ?u16) Error!ParseResult(ast.Field) {
        const recovery_points: []const TokenKindTag = &(comptime [_]TokenKindTag{ .Comma } ++ AnnotationStartTokens);
        const doc = try self.consumeStagedDocumentation();
        const name_token = try self.consumeRequiredToken(.Identifier, "field name");
        _ = try self.consumeRequiredToken(.Colon, ":");
        const current_scope = self.scopeDelimiterContext();

        const data_type = try self.parseFieldType();
        if (data_type.needs_recovery) {
            return .init(
                try self.buildField(name_token, doc, .empty, null, data_type.data, oneof_group_index),
                true,
            );
        }
        var tag: ?u16 = null;
        if (self.consumeOptionalTokenBool(.Equal)) {
            if (self.consumeRequiredToken(.Integer, "field tag number")) |tag_token| {
                if (std.math.cast(u16, tag_token.kind.Integer)) |tag_value| {
                    if (tag_value == 0) {
                        self.addError(PragmaError.fieldTagNumericalError(&tag_token));
                    }
                    tag = tag_value;
                } else self.addError(PragmaError.fieldTagNumericalError(&tag_token));
            } else |err| return .init(
                try self.buildField(name_token, doc, .empty, tag, data_type.data, oneof_group_index),
                try self.recoverExitsScope(err, recovery_points, current_scope),
            );
        }

        return if (self.parseItemAnnotations(.Comma)) |v| .init(
            try self.buildField(name_token, doc, v.data, tag, data_type.data, oneof_group_index),
            v.needs_recovery,
        ) else |err| .init(
            try self.buildField(name_token, doc, .empty, tag, data_type.data, oneof_group_index),
            try self.recoverExitsScope(err, recovery_points, current_scope),
        );
    }

    fn parseFieldType(self: *Context) Error!ParseResult(ast.Field.RangedType) {
        const nullable = self.consumeOptionalTokenBool(.QuestionMark);
        const next_token = try self.peekNextOrError();
        switch (next_token.kind) {
            .Identifier => {
                const type_key_path = try self.parseKeyPath();
                return .init(ast.Field.RangedType{
                    .value = .{ .nullable = nullable, .kind = .{ .name = .{ .ref = type_key_path } } },
                    .range = type_key_path.range,
                }, false);
            },
            .OneOf => {
                const start = next_token.range.start;
                self.consume();
                const oneof_body = try self.parseOneOfBodyType();
                return .init(ast.Field.RangedType{
                    .value = .{ .nullable = nullable, .kind = .{ .oneof = oneof_body.data } },
                    .range = ast.Range{
                        .start = start,
                        .end = self.currentRangeAssumeSafe().end,
                    },
                }, oneof_body.needs_recovery);
            },
            .List => {
                const start = next_token.range.start;
                self.consume();
                _ = try self.consumeRequiredToken(.LessThan, "<");
                const value: ast.Field.TypePtr = blk: {
                    if (self.it.peek(1)) |inner_type_token| if (inner_type_token.kind == .Identifier) {
                        break :blk .{ .ref = try self.parseKeyPath() };
                    };
                    const current_scope = self.scopeDelimiterContext();
                    const inner_type = try self.parseFieldType();
                    const id = self.field_types.len();
                    try self.field_types.append(inner_type.data);
                    const result = ast.Field.TypePtr{ .ptr = id };
                    if (inner_type.needs_recovery) {
                        return .init(ast.Field.RangedType{
                            .value = .{ .nullable = nullable, .kind = .{ .list = result } },
                            .range = ast.Range{ .start = start, .end = self.currentRangeAssumeSafe().end },
                        }, current_scope != self.scopeDelimiterContext());
                    }
                    break :blk result;
                };
                const last_token = try self.consumeRequiredToken(.GreaterThan, ">");
                return .init(ast.Field.RangedType{
                    .value = .{ .nullable = nullable, .kind = .{ .list = value } },
                    .range = ast.Range{ .start = start, .end = last_token.range.end },
                }, false);
            },
            .Map => {
                const start = next_token.range.start;
                self.consume();
                _ = try self.consumeRequiredToken(.LessThan, "<");
                const key_type = try self.parseKeyPath();
                _ = try self.consumeRequiredToken(.Comma, ",");
                const value_type: ast.Field.TypePtr = blk: {
                    if (self.it.peek(1)) |inner_type_token| if (inner_type_token.kind == .Identifier) {
                        break :blk .{ .ref = try self.parseKeyPath() };
                    };
                    const id = self.field_types.len();
                    const current_scope = self.scopeDelimiterContext();
                    const result = try self.parseFieldType();
                    try self.field_types.append(result.data);
                    if (result.needs_recovery) {
                        return .init(ast.Field.RangedType{
                            .value = .{
                                .nullable = nullable,
                                .kind = .{ .map = .{ .key = key_type, .value = .{ .ptr = id } } },
                            },
                            .range = ast.Range{ .start = start, .end = self.currentRangeAssumeSafe().end },
                        }, current_scope == self.scopeDelimiterContext());
                    }
                    break :blk .{ .ptr = id };
                };
                const last_token = try self.consumeRequiredToken(.GreaterThan, ">");
                return .initOk(ast.Field.RangedType{
                    .value = .{
                        .nullable = nullable,
                        .kind = .{ .map = .{ .key = key_type, .value = value_type } },
                    },
                    .range = ast.Range{ .start = start, .end = last_token.range.end },
                });
            },
            else => {
                self.addError(PragmaError.expectToken(&next_token, "field type"));
                self.consume();
                return Error.UnexpectedToken;
            },
        }
    }

    fn processOneOfBody(
        self: *Context,
        oneof_group_index: ?u16,
        context: anytype,
        comptime cb: fn(@TypeOf(context), ast.Field) Error!void,
    ) Error!ParseResult(struct { annotations: []const ast.AnnotationNode }) {
        const recovery_points: []const TokenKindTag = &(.{ .Comma, .Identifier } ++ AnnotationStartTokens);
        _ = try self.consumeRequiredToken(.LeftCurlyBrace, "{");
        var annotations = StackFallbackArray(ast.AnnotationNode, 16).init(self.transient_allocator);
        const current_scope = self.scopeDelimiterContext();

        const parent_might_need_recovery = blk: {
            while (true) {
                const next_token = self.it.peek(1) orelse break :blk false;
                switch (next_token.kind) {
                    .Identifier => if (self.parseField(oneof_group_index)) |v| {
                        // append the field
                        try cb(context, v.data);
                        if (v.needs_recovery and try self.skipTokensUntilScope(recovery_points, current_scope)) {
                            break :blk true;
                        }
                    } else |err| if (try self.recoverExitsScope(err, &.{.Comma}, current_scope)) {
                        break :blk true;
                    },
                    .Hash, .ExtraHash, .PrivateHash, .ExtraMode, .PrivateMode, .PrivateExtraMode => {
                        if (self.parseAnnotation(false, null)) |v| {
                            try annotations.append(v.data);
                            if (v.needs_recovery and try self.skipTokensUntilScope(recovery_points, current_scope)) {
                                break :blk true;
                            }
                        } else |err| if (try self.recoverExitsScope(err, recovery_points, current_scope)) {
                            break :blk true;
                        }
                    },
                    .RightCurlyBrace => {
                        self.consume();
                        self.popScopeDelimiter(.CurlyBrace);
                        break :blk false;
                    },
                    .Comma => self.consume(),
                    else => {
                        self.addError(PragmaError.unexpectedToken(&next_token));
                        if (try self.skipTokensUntil(recovery_points)) {
                            break :blk true;
                        }
                    },
                }
            }
        };

        return .init(
            .{ .annotations = try annotations.toOwnedSlice(self.allocator) },
            parent_might_need_recovery and self.scopeDelimiterContext() + 1 != current_scope,
        );
    }

    /// parses oneof body that is a field type, not a grouping.
    fn parseOneOfBodyType(
        self: *Context,
    ) Error!ParseResult(ast.Field.OneOfTypeInfo) {
        var fields: StackFallbackArray(ast.Field, 40) = .init(self.transient_allocator);
        const S = struct {
            fn append(arr: *@TypeOf(fields), field: ast.Field) Error!void {
                try arr.append(field);
            }
        };
        const result = try self.processOneOfBody(null, &fields, S.append);
        return .init(
            .{
                .fields = try fields.toOwnedSlice(self.allocator),
                .annotations = result.data.annotations,
            },
            result.needs_recovery,
        );
    }

    /// Parse annotations belonging to an item (fields, functions, etc.).
    fn parseItemAnnotations(
        self: *Context,
        comptime termination_token: TokenKindTag,
    ) Error!ParseResult(ast.AnnotationGroup) {
        const recovery_points: []const TokenKindTag = &.{
            termination_token, .Hash, .ExtraHash, .PrivateHash, .ExtraMode, .PrivateMode, .PrivateExtraMode,
        };
        const current_scope = self.scopeDelimiterContext();

        if (self.nextTokenIs(.LeftCurlyBrace)) {
            if (self.parseAnnotationBlock()) |v| {
                return .init(ast.AnnotationGroup{ .block = true, .values = v.data }, v.needs_recovery);
            } else |err| return err;
        }

        var values = StackFallbackArray(ast.AnnotationNode, 16).init(self.transient_allocator);
        const parent_might_need_recovery = blk: {
            while (true) {
                const token = self.it.peek(1) orelse break :blk false;
                if (token.kind == .RightCurlyBrace or token.kind == termination_token) {
                    break :blk false;
                }
                if (self.parseAnnotation(false, null)) |v| {
                    try values.append(v.data);
                    if (v.needs_recovery) {
                        break :blk true;
                    }
                } else |err| if (try self.recoverExitsScope(err, recovery_points, current_scope)) {
                    break :blk true;
                } else if (!self.nextTokenIsOneOf(recovery_points)) break :blk false;
                // NB: If next token is not an option token, exit out of option parsing loop.
            }
        };

        return .init(.{
            .block = false,
            .values = try values.toOwnedSlice(self.allocator),
        }, parent_might_need_recovery and (self.scopeDelimiterContext() != current_scope));
    }

    fn processAnnotationDefinition(self: *Context) Error!void {
        const start = self.currentRangeAssumeSafe().start;
        _ = try self.consumeRequiredToken(.For, "for");

        var target_set = ast.AnnotationTargetSet.init(.{});
        target_set.insert(try self.parseAnnotationTarget());
        while (true) {
            const next_token = try self.peekNextOrError();
            if (next_token.kind == .LeftCurlyBrace) {
                self.consume();
                break;
            }
            _ = try self.consumeRequiredToken(.Comma, ",");
            target_set.insert(try self.parseAnnotationTarget());
        }

        const current_scope = self.scopeDelimiterContext();

        var fields = StackFallbackArray(ast.Field, 40).init(self.transient_allocator);

        while (true) {
            const next_token = self.peekNextOrError() catch break;
            switch (next_token.kind) {
                .Comma => self.consume(),
                .RightCurlyBrace => {
                    self.consume();
                    break;
                },
                else => if (self.parseField(null)) |v| {
                    try fields.append(v.data);
                    if (v.needs_recovery) {
                        break;
                    }
                } else |err| if (try self.recoverExitsScope(err, &.{.Comma}, current_scope)) {
                    break;
                }
            }
        }

        try self.annotation_definitions.append(self.allocator, ast.AnnotationDefinition{
            .targets = target_set,
            .fields = try fields.toOwnedSlice(self.allocator),
            .range = .{
                .start = start,
                .end = self.currentRangeAssumeSafe().end,
            },
        });
    }

    inline fn parseAnnotationTarget(self: *Context) Error!ast.AnnotationTarget {
        const target_token = self.it.next() orelse {
            self.addError(PragmaError.unexpectedEOF());
            return Error.UnexpectedEOF;
        };
        switch (target_token.kind) {
            .TargetPackage => return ast.AnnotationTarget.Package,
            .TargetOneOf => return ast.AnnotationTarget.OneOf,
            .TargetEnum => return ast.AnnotationTarget.Enum,
            .TargetConst => return ast.AnnotationTarget.Constant,
            .TargetEnumVariant => return ast.AnnotationTarget.EnumVariant,
            .TargetStruct => return ast.AnnotationTarget.Struct,
            .TargetField => return ast.AnnotationTarget.Field,
            .TargetProtocol => return ast.AnnotationTarget.Protocol,
            .TargetFunc => return ast.AnnotationTarget.Func,
            else => {
                self.addError(PragmaError.expectToken(&target_token, "annotation target"));
                return Error.UnexpectedToken;
            },
        }
    }

    fn processProtocol(self: *Context) Error!void {
        const recovery_points: []const TokenKindTag = &.{ .Identifier, .Documentation };
        try self.processGroupNew(recovery_points, processProtocolBody);
    }

    fn processProtocolBody(self: *Context) Error!void {
        const recovery_points: []const TokenKindTag = &.{ .Identifier, .Documentation };
        const doc = try self.consumeStagedDocumentation();
        const name_token = try self.consumeRequiredToken(.Identifier, "protocol name");

        _ = try self.consumeRequiredToken(.LeftCurlyBrace, "");
        const current_scope = self.scopeDelimiterContext();

        var funcs = StackFallbackArray(ast.Func, 40).init(self.transient_allocator);
        var annotations = StackFallbackArray(ast.AnnotationNode, 16).init(self.transient_allocator);

        while (true) {
            const token = self.peekNextOrError() catch break;
            switch (token.kind) {
                .Semicolon, .Comma => self.consume(),
                .Hash, .PrivateHash, .ExtraHash, .ExtraMode, .PrivateMode, .PrivateExtraMode => {
                    if (self.parseAnnotation(false, null)) |v| {
                        try annotations.append(v.data);
                        if (v.needs_recovery) {
                            break;
                        }
                    } else |err| if (try self.recoverExitsScope(err, recovery_points, current_scope)) {
                        break;
                    }
                },
                .Documentation => try self.stageDocumentationGroup(),
                .Identifier => if (self.parseFunc()) |v| {
                    try funcs.append(v.data);
                    if (v.needs_recovery) {
                        break;
                    }
                } else |err| if (try self.recoverExitsScope(err, &.{.Semicolon}, current_scope)) {
                    break;
                },
                .RightCurlyBrace => {
                    self.consume();
                    self.popScopeDelimiter(.CurlyBrace);
                    break;
                },
                else => {
                    self.addError(PragmaError.unexpectedToken(&token));
                    if (try self.skipTokensUntilScope(InterfaceBodyRecoveryPoints, current_scope)) {
                        break;
                    }
                },
            }
        }

        try self.protocols.append(self.allocator, ast.Protocol{
            .name = ast.Identifier{
                .value = try self.copyString(name_token.literal),
                .range = name_token.range,
            },
            .funcs = try funcs.toOwnedSlice(self.allocator),
            .documentation = doc,
            .annotations = try annotations.toOwnedSlice(self.allocator),
            .range = ast.Range{
                .start = name_token.range.start,
                .end = self.currentRangeAssumeSafe().end,
            },
        });
    }

    inline fn buildFunc(
        self: *Context,
        name_token: tokenizer.Token,
        annotations: ast.AnnotationGroup,
        input: ?ast.FuncArg,
        output: ?ast.FuncArg,
        doc: ?ast.Documentation,
        tag: ?u16,
    ) Allocator.Error!ast.Func {
        return ast.Func{
            .name = ast.Identifier{
                .value = try self.copyString(name_token.literal),
                .range = name_token.range,
            },
            .annotations = annotations,
            .input = input,
            .output = output,
            .documentation = doc,
            .tag = tag,
            .range = .{
                .start = name_token.range.start,
                .end = self.currentRangeAssumeSafe().end,
            },
        };
    }

    fn parseFunc(self: *Context) Error!ParseResult(ast.Func) {
        const doc = try self.consumeStagedDocumentation();
        const name_token = try self.consumeRequiredToken(.Identifier, "func name");
        _ = try self.consumeRequiredToken(.LeftParan, "(");
        var input: ?ast.FuncArg = null;
        var output: ?ast.FuncArg = null;
        const current_scope = self.scopeDelimiterContext();

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
        var tag: ?u16 = null;
        if (self.consumeOptionalTokenBool(.Equal)) {
            const tagToken = try self.consumeRequiredToken(.Integer, "func tag");
            if (std.math.cast(u16, tagToken.kind.Integer)) |tagValue| {
                if (tagValue == 0) {
                    self.addError(PragmaError.funcTagNumericalError(&tagToken));
                }
                tag = tagValue;
            } else self.addError(PragmaError.funcTagNumericalError(&tagToken));
        }

        return if (self.parseItemAnnotations(.Semicolon)) |v| .init(
            try self.buildFunc(name_token, v.data, input, output, doc, tag),
            v.needs_recovery,
        ) else |err| .init(
            try self.buildFunc(name_token, .empty, input, output, doc, tag),
            try self.recoverExitsScope(err, InterfaceBodyRecoveryPoints, current_scope),
        );
    }

    fn parseFuncArg(self: *Context) Error!ast.FuncArg {
        const streaming = self.consumeOptionalTokenBool(.Stream);
        const name = try self.parseKeyPath();
        return ast.FuncArg{
            .name = name,
            .streaming = streaming,
        };
    }

    inline fn processGroupNew(
        self: *Context,
        comptime recovery_tokens: []const TokenKindTag,
        comptime handler: fn (self: *Context) Error!void,
    ) Error!void {
        // NB: If there is no left paran '(', then it's not a group, just run the handler.
        if (!(try self.consumeOptionalEnterScopeTokenBool(.LeftParan))) {
            return handler(self);
        }

        // If there is any staged documentation, it is invalid and should be ignored.
        if (!self.staged_documentation.empty()) {
            self.addError(PragmaError.unusedDocumentation(self.staged_documentation.start));
            self.staged_documentation.reset();
        }

        while (true) {
            const next = try self.peekNextOrError();
            switch (next.kind) {
                .RightParan => {
                    self.popScopeDelimiter(.Paran);
                    self.consume();
                    break;
                },
                .Documentation => try self.stageDocumentationGroup(),
                else => {
                    handler(self) catch |err| switch (err) {
                        Error.UnexpectedToken => {
                            switch (self.scopeDelimiterContext()) {
                                // outside of the paran scope; stop iterating.
                                0 => break,
                                // in the paran scope; skip the current line.
                                1 => {
                                    self.it.goBack();
                                    if (try self.skipTokensUntilScope(recovery_tokens, 1)) {
                                        break;
                                    }
                                },
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
            }
        }
    }

    // TODO: remove me.
    inline fn processGroup(self: *Context, comptime handler: fn (self: *Context) Error!void) Error!void {
        // NB: If there is no left paran '(', then it's not a group, just run the handler.
        if (!(try self.consumeOptionalEnterScopeTokenBool(.LeftParan))) {
            return handler(self);
        }

        // If there is any staged documentation, it is invalid and should be ignored.
        if (!self.staged_documentation.empty()) {
            self.addError(PragmaError.unusedDocumentation(self.staged_documentation.start));
            self.staged_documentation.reset();
        }

        while (true) {
            const next = self.it.peek(1) orelse
                return if (self.scopeDelimiterContext() == 0) {} else Error.UnexpectedEOF;
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
                            1 => if (try self.skipTokensUntil(&.{})) break,
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
        }
    }

    fn processAnnotation(self: *Context) Error!void {
        const modifiers = try self.parseAnnotationModifiers(true);

        // NB: there is no need to check whether scope is exited or not because regardless
        // it returns to the root scope. If there is partial data, it should get added.
        if (self.nextTokenIs(.LeftCurlyBrace)) {
            // block mode.
            const start = self.currentRangeAssumeSafe().start;
            const annotation_block = try self.parseAnnotationBlock();
            const root = ast.AnnotationNode{
                .flags = .{ .extra = modifiers.extra, .private = modifiers.private },
                .key_path = ast.KeyPath.init("", .zero),
                .profiles = modifiers.profiles,
                .range = ast.Range{ .start = start, .end = self.currentRangeAssumeSafe().end },
                .value = .{ .group = annotation_block.data },
            };
            try self.annotations.append(self.allocator, root);
        } else {
            const annotation = try self.parseAnnotation(false, modifiers);
            try self.annotations.append(self.allocator, annotation.data);
        }
    }

    fn parseProfiles(self: *Context) Error![]const ast.Identifier {
        try self.pushScopeDelimiter(.Bracket);
        var profiles: StackFallbackArray(ast.Identifier, 16) = .init(self.transient_allocator);
        while (true) {
            const token = self.it.next() orelse return error.UnexpectedEOF;
            switch (token.kind) {
                .Identifier => {
                    try profiles.append(ast.Identifier{
                        .value = try self.copyString(token.literal),
                        .range = token.range,
                    });
                },
                .Comma => {},
                .RightBracket => {
                    self.popScopeDelimiter(.Bracket);
                    _ = try self.consumeRequiredToken(.Hash, "#");
                    break;
                },
                else => {
                    self.addError(.expectToken(&token, "], comma or profile name"));
                    return error.UnexpectedToken;
                },
            }
        }
        return try profiles.toOwnedSlice(self.allocator);
    }

    fn parseAnnotationModifiers(self: *Context, comptime needs_hash_prefix: bool) Error!AnnotationModifiers {
        const token = self.it.peek(1) orelse {
            if (needs_hash_prefix) {
                self.addError(PragmaError.unexpectedEOF());
                return Error.UnexpectedEOF;
            }

            return .default;
        };

        switch (token.kind) {
            .Hash => {
                self.consume();
                if (!needs_hash_prefix) {
                    self.addError(PragmaError.redundantAnnotationHash(token.range.start));
                }
                return .default;
            },
            .PrivateMode => {
                self.consume();
                const profiles = try self.parseProfiles();
                return .{ .private = true, .profiles = profiles };
            },
            .ExtraHash => {
                self.consume();
                return .{ .extra = true };
            },
            .ExtraMode => {
                self.consume();
                const profiles = try self.parseProfiles();
                return .{ .extra = true, .profiles = profiles };
            },
            .PrivateHash => {
                self.consume();
                return .{ .private = true };
            },
            .PrivateExtraMode => {
                self.consume();
                const profiles = try self.parseProfiles();
                return .{ .extra = true, .private = true, .profiles = profiles };
            },
            else => if (needs_hash_prefix) {
                self.addError(PragmaError.expectToken(&token, "annotation modifier or end of statement"));
                self.consume();
                return Error.UnexpectedToken;
            } else return .default,
        }
    }

    fn parseAnnotation(
        self: *Context,
        comptime inside_block: bool,
        captured_modifiers: ?AnnotationModifiers,
    ) Error!ParseResult(ast.AnnotationNode) {
        const modifiers = captured_modifiers orelse try self.parseAnnotationModifiers(!inside_block);
        const start = self.currentRangeAssumeSafe().start;
        const bare = self.consumeOptionalTokenBool(.Dot);

        // Parse the key.
        const key_token = try self.peekNextOrError();
        const key_path = switch (key_token.kind) {
            .String => blk: {
                if (!modifiers.extra) {
                    self.addError(PragmaError.extraAnnotationWithoutSigil(&key_token));
                }
                self.consume();
                break :blk ast.KeyPath.init(
                    try key_token.kind.String.toOwnedAndEscaped(self.allocator),
                    key_token.range,
                );
            },
            .Identifier => try self.parseKeyPath(),
            else => {
                self.addError(PragmaError.expectToken(&key_token, "annotation key path or string"));
                self.consume();
                return Error.UnexpectedToken;
            },
        };
        // Parse the value, which can be a curly braces for blocks, a literal or nothing at all to indicate a flag.
        if (self.it.peek(1)) |value_token| switch (value_token.kind) {
            .LeftCurlyBrace => {
                const current_scope = self.scopeDelimiterContext();
                return if (self.parseAnnotationBlock()) |v| .init(
                    ast.AnnotationNode{
                        .flags = .{ .private = modifiers.private, .extra = modifiers.extra, .bare = bare },
                        .key_path = key_path,
                        .value = .{ .group = v.data },
                        .range = .{
                            .start = start,
                            .end = self.currentRangeAssumeSafe().end,
                        },
                        .profiles = modifiers.profiles,
                    },
                    v.needs_recovery and (self.scopeDelimiterContext() != current_scope),
                ) else |err| err;
            },
            .Equal => {
                self.consume();
                const current_scope = self.scopeDelimiterContext();
                return if (self.parseValue()) |v| .init(
                    ast.AnnotationNode{
                        .flags = .{ .extra = modifiers.extra, .private = modifiers.private, .bare = bare },
                        .key_path = key_path,
                        .value = .{ .leaf = v.data },
                        .range = .{
                            .start = key_path.range.start,
                            .end = v.data.range.end,
                        },
                        .profiles = modifiers.profiles,
                    },
                    v.needs_recovery and (self.scopeDelimiterContext() != current_scope),
                ) else |err| err;
            },
            else => {},
        };

        return .initOk(ast.AnnotationNode{
            .flags = .{ .extra = modifiers.extra, .private = modifiers.private, .bare = bare },
            .key_path = key_path,
            .value = .{
                .leaf = .{
                    .literal = .{ .boolean = true },
                    .range = key_path.range,
                },
            },
            .range = key_path.range,
            .profiles = modifiers.profiles,
        });
    }

    fn parseAnnotationBlock(self: *Context) Error!ParseResult([]ast.AnnotationNode) {
        const recovery_points: []const TokenKindTag = &.{
            .Comma,
            .Identifier,
            .String,
            .Hash,
            .ExtraHash,
            .PrivateHash,
            .ExtraMode,
            .PrivateMode,
            .PrivateExtraMode,
        };
        var values = StackFallbackArray(ast.AnnotationNode, 16).init(self.transient_allocator);
        _ = try self.consumeRequiredToken(.LeftCurlyBrace, "{");
        const current_scope = self.scopeDelimiterContext();
        const parent_might_need_recovery = blk: {
            while (true) {
                const token = self.it.peek(1) orelse break :blk false;
                switch (token.kind) {
                    .RightCurlyBrace => {
                        self.consume();
                        self.popScopeDelimiter(.CurlyBrace);
                        break :blk false;
                    },
                    .Comma => self.consume(),
                    else => if (self.parseAnnotation(true, null)) |v| {
                        try values.append(v.data);
                        if (v.needs_recovery) {
                            break :blk true;
                        }
                    } else |err| if (try self.recoverExitsScope(err, recovery_points, current_scope)) {
                        break :blk true;
                    },
                }
            }
        };
        return .init(
            try values.toOwnedSlice(self.allocator),
            parent_might_need_recovery and (self.scopeDelimiterContext() + 1 != current_scope),
        );
    }

    /// parses an array of ranged values.
    ///
    /// NOTE: It assumes the the left bracket is already consumed.
    fn parseValueArray(self: *Context) Error!ParseResult(ast.RangedLiteral) {
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
        var values = StackFallbackArray(ast.RangedLiteral, 16).init(self.transient_allocator);
        const start = self.currentRangeAssumeSafe().start;
        const current_scope = self.scopeDelimiterContext();

        const parent_might_need_recovery = blk: {
            while (true) {
                const next = self.it.peek(1) orelse break :blk true;
                switch (next.kind) {
                    .RightBracket => {
                        self.popScopeDelimiter(.Bracket);
                        self.consume();
                        break :blk false;
                    },
                    .Comma => self.consume(),
                    else => if (self.parseValue()) |v| {
                        try values.append(v.data);
                        if (v.needs_recovery) {
                            break :blk true;
                        }
                    } else |err| if (try self.recoverExitsScope(err, ArrayRecoveryPoints, current_scope)) {
                        break :blk true;
                    },
                }
            }
        };

        return .init(.{
            .literal = ast.LiteralValue{ .array = try values.toOwnedSlice(self.allocator) },
            .range = .{ .start = start, .end = self.it.currentAssumeSafe().range.end },
        }, parent_might_need_recovery and (self.scopeDelimiterContext() + 1 != current_scope));
    }

    /// parses a map of ranged values.
    ///
    /// NOTE: It assumes the the left curly brace is already consumed.
    fn parseValueObject(self: *Context) Error!ParseResult(ast.RangedLiteral) {
        const ObjectRecoveryPoints: []const TokenKindTag = &.{ .String, .Identifier, .Comma };
        try self.pushScopeDelimiter(.CurlyBrace);
        var values = StackFallbackArray(ast.Pair, 32).init(self.transient_allocator);
        const start = self.currentRangeAssumeSafe().start;
        const current_scope = self.scopeDelimiterContext();

        const parent_might_need_recovery = blk: {
            while (true) {
                const next = self.it.next() orelse break :blk true;
                switch (next.kind) {
                    .RightCurlyBrace => {
                        self.popScopeDelimiter(.CurlyBrace);
                        break :blk false;
                    },
                    .Comma => {},
                    .At => {
                        const key = try self.parseRef();
                        _ = self.consumeRequiredToken(.Colon, ":") catch |err| {
                            if (try self.recoverExitsScope(err, ObjectRecoveryPoints, current_scope))
                                break :blk true;
                        };
                        if (self.parseValue()) |v| {
                            try values.append(ast.Pair{
                                .key = .{ .ref = key },
                                .value = v.data,
                            });
                            if (v.needs_recovery) {
                                break :blk true;
                            }
                        } else |err| if (try self.recoverExitsScope(err, ObjectRecoveryPoints, current_scope)) {
                            break :blk true;
                        }
                    },
                    .String => {
                        _ = self.consumeRequiredToken(.Colon, ":") catch |err| {
                            if (try self.recoverExitsScope(err, ObjectRecoveryPoints, current_scope))
                                break :blk true;
                        };
                        if (self.parseValue()) |v| {
                            try values.append(ast.Pair{
                                .key = .{ .string = try next.kind.String.toOwnedAndEscaped(self.allocator) },
                                .value = v.data,
                            });
                            if (v.needs_recovery) {
                                break :blk true;
                            }
                        } else |err| if (try self.recoverExitsScope(err, ObjectRecoveryPoints, current_scope)) {
                            break :blk true;
                        }
                    },
                    else => {
                        self.addError(PragmaError.expectToken(&next, "key string literal"));
                        break :blk try self.skipTokensUntilScope(ObjectRecoveryPoints, current_scope);
                    },
                }
            }
        };

        return .init(.{
            .literal = ast.LiteralValue{ .object = try values.toOwnedSlice(self.allocator) },
            .range = .{ .start = start, .end = self.currentRangeAssumeSafe().end },
        }, parent_might_need_recovery and (self.scopeDelimiterContext() + 1 != current_scope));
    }

    fn parseValue(self: *Context) Error!ParseResult(ast.RangedLiteral) {
        const token = self.it.next() orelse return Error.UnexpectedEOF;
        return switch (token.kind) {
            .String => .initOk(.{
                .range = token.range,
                .literal = ast.LiteralValue{ .string = try token.kind.String.toOwnedAndEscaped(self.allocator) },
            }),
            .Integer => .initOk(.{
                .range = token.range,
                .literal = ast.LiteralValue{ .number = token.kind.Integer },
            }),
            .Float => .initOk(.{
                .range = token.range,
                .literal = ast.LiteralValue{ .float = token.kind.Float },
            }),
            .True => .initOk(.{
                .range = token.range,
                .literal = ast.LiteralValue{ .boolean = true },
            }),
            .False => .initOk(.{
                .range = token.range,
                .literal = ast.LiteralValue{ .boolean = false },
            }),
            .LeftBracket => self.parseValueArray(),
            .LeftCurlyBrace => self.parseValueObject(),
            .At => {
                const start = self.currentRangeAssumeSafe().start;
                const key_path = try self.parseRef();
                return .initOk(.{
                    .literal = .{ .ref = key_path },
                    .range = .{ .start = start, .end = self.currentRangeAssumeSafe().end },
                });
            },
            else => {
                self.addError(PragmaError.expectToken(&token, "value"));
                return Error.UnexpectedToken;
            },
        };
    }

    fn parseRef(self: *Context) Error!ast.KeyPath {
        const ref_token = try self.consumeRequiredToken(.Identifier, "pragma function name");
        if (!std.mem.eql(u8, ref_token.literal, "ref")) {
            self.addError(PragmaError.unsupportedPragmaKeyword(&ref_token));
            return Error.UnexpectedToken;
        }
        _ = try self.consumeRequiredToken(.LeftParan, "(");
        const key_path = try self.parseKeyPath();
        _ = try self.consumeRequiredToken(.RightParan, ")");
        return key_path;
    }

    fn parseKeyPath(self: *Context) Error!ast.KeyPath {
        var dot_count: u16 = 0;
        var content_size: usize = 0;
        var token_count: u16 = 0;

        const Segment = struct {
            content: []const u8,
            start: usize,
        };

        var segments = StackArray(Segment, 16).init();

        while (self.it.next()) |token| {
            const expect_identifier = token_count % 2 == 0;
            switch (token.kind) {
                .Identifier => {
                    if (expect_identifier) {
                        token_count += 1;
                        content_size += token.literal.len;
                        segments.append(.{
                            .content = token.literal,
                            .start = token.range.start,
                        }) catch return Error.NestingDepthReached;
                    } else {
                        self.it.goBack();
                        break;
                    }
                },
                .Dot => {
                    if (!expect_identifier) {
                        token_count += 1;
                        content_size += 1;
                        dot_count += 1;
                    } else {
                        self.addError(PragmaError.unexpectedToken(&token));
                        return Error.UnexpectedToken;
                    }
                },
                else => if (expect_identifier) {
                    self.addError(PragmaError.expectToken(&token, "keypath segment"));
                    return Error.UnexpectedToken;
                } else {
                    self.it.goBack();
                    break;
                },
            }
        }
        if (token_count % 2 == 0) {
            // NB: Consume at least one token but go backwards if the unexpected token
            // comes after some other expected token.
            if (token_count > 0) {
                self.it.goBack();
            }
            if (self.it.peek(0)) |token| {
                self.addError(PragmaError.unexpectedToken(&token));
            } else {
                self.addError(PragmaError.unexpectedEOF());
            }
            return Error.UnexpectedToken;
        }

        if (dot_count == 0) {
            const segment = segments.buffer[0];
            return ast.KeyPath.init(try self.copyString(segment.content), .{
                .start = segment.start,
                .end = segment.start + segment.content.len,
            });
        }

        var builder = try ast.KeyPath.builder(self.allocator, content_size, dot_count + 1);
        var first_one = true;
        for (segments.slice()) |segment| {
            if (!first_one) {
                builder.appendSeparator() catch @panic("poor calculation of token count");
            } else first_one = false;
            builder.appendSegment(segment.content, segment.start) catch @panic("poor calculation of segment count");
        }

        const last_one = segments.buffer[segments.len - 1];
        return builder.build(.{
            .start = segments.buffer[0].start,
            .end = last_one.start + last_one.content.len,
        });
    }

    /// read contiguous package documentations and add them to the document.
    fn consumePackageDocumentation(self: *Context) Allocator.Error!void {
        while (self.it.peek(1)) |token| {
            switch (token.kind) {
                .Documentation => |doc| {
                    if (!doc.flags.package) {
                        break;
                    }
                    self.consume();
                    const content = doc.content;
                    try self.staged_documentation.boundaries.append(content);
                    self.staged_documentation.content_size += content.len;
                },
                else => break,
            }
        }

        self.documentation = try self.consumeStagedDocumentation();
    }

    /// parse and stage documentation lines.
    fn stageDocumentationGroup(self: *Context) Allocator.Error!void {
        while (self.it.peek(1)) |token| {
            if (token.kind != .Documentation)
                break;

            self.consume();

            if (token.kind.Documentation.flags.package) {
                if (!self.staged_documentation.encountered_package_error) {
                    self.addError(.unexpectedPackageDocumentation(token.range.start));
                    self.staged_documentation.encountered_package_error = true;
                }
                
                continue;
            }

            const content = token.kind.Documentation.content;
            if (self.staged_documentation.boundaries.stack_len == 0) {
                self.staged_documentation.start = token.range.start;
            }
            try self.staged_documentation.boundaries.append(content);
            self.staged_documentation.content_size += content.len;
        }
    }

    fn consumeStagedDocumentation(self: *Context) Allocator.Error!?ast.Documentation {
        if (self.staged_documentation.empty()) {
            return null;
        }
        defer self.staged_documentation.reset();
        const content_size = self.staged_documentation.content_size + self.staged_documentation.boundaries.len();
        var content_buffer = try std.ArrayList(u8).initCapacity(self.allocator, content_size);
        var it = self.staged_documentation.boundaries.iterator();
        while (it.next()) |boundary| {
            content_buffer.appendSliceAssumeCapacity(boundary);
            content_buffer.appendAssumeCapacity('\n');
        }
        return ast.Documentation{ .content = content_buffer.items };
    }

    fn addError(self: *Context, err: PragmaError) void {
        if (err.code == .UnexpectedEOF
            and self.errors.len > 0 and self.errors.buffer[self.errors.len-1].code == .UnexpectedEOF) {
            return;
        }
        if (self.errors.len == self.errors.capacity()) {
            return;
        }
        self.errors.appendAssumeCapacity(err);
    }

    /// allocates precisely the amount necessary to store errors.
    fn buildErrors(self: Context) std.mem.Allocator.Error![]const PragmaError {
        const errors = try self.allocator.alloc(PragmaError, self.errors.len + self.it.errors.len);
        for (self.it.errors.slice(), 0..) |token_error, i| {
            errors[i] = PragmaError{
                .code = .SyntaxError,
                .message = token_error.message,
                .location = .{ .range = token_error.range },
            };
        }
        @memcpy(errors[self.it.errors.len..], self.errors.slice());
        return errors;
    }

    inline fn consumeRequiredToken(
        self: *Context,
        comptime tag: TokenKindTag,
        comptime expectedToken: ?[]const u8,
    ) !tokenizer.Token {
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
                self.addError(PragmaError.expectToken(&token, name));
            } else {
                self.addError(PragmaError.unexpectedToken(&token));
            }
            if (token.kind == .EOF) return Error.UnexpectedEOF;
            return Error.UnexpectedToken;
        } else {
            self.addError(PragmaError.unexpectedEOF());
            return Error.UnexpectedEOF;
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

    inline fn nextTokenIsOneOf(self: *const Context, comptime tags: []const TokenKindTag) bool {
        if (self.it.peek(1)) |token| {
            const nextTokenTag = std.meta.activeTag(token.kind);
            inline for (tags) |tag| {
                if (tag == nextTokenTag) {
                    return true;
                }
            }
        }
        return false;
    }

    inline fn consumeOptionalToken(self: *Context, tag: TokenKindTag) ?tokenizer.Token {
        // ensure that no scope delimiter token gets used with this function.
        comptime if (std.mem.indexOfScalar(TokenKindTag, ScopeDelimiterTokens, tag)) |_| {
            @compileError(
                "do not use scope delimiter tokens such as " ++ @tagName(tag) ++
                    " with this fn, instead use consumeOptionalScopeTokenBool",
            );
        };

        if (self.it.peek(1)) |token| {
            if (std.meta.activeTag(token.kind) == tag) {
                self.it.consumeTokenAssumeSafe();
                return token;
            }
        }
        return null;
    }

    inline fn consume(self: *Context) void {
        self.it.consumeTokenAssumeSafe();
    }

    inline fn peekNextOrError(self: *Context) error{UnexpectedEOF}!tokenizer.Token {
        return self.it.peek(1) orelse {
            self.addError(PragmaError.unexpectedEOF());
            return error.UnexpectedEOF;
        };
    }

    inline fn copyString(self: *Context, ref: []const u8) Allocator.Error![]const u8 {
        return try self.allocator.dupe(u8, ref);
    }

    inline fn currentRangeAssumeSafe(self: *const Context) ast.Range {
        return self.it.currentAssumeSafe().range;
    }

    inline fn pushScopeDelimiter(self: *Context, delimiter: ScopeDelimiter) error{NestingDepthReached}!void {
        self.scope_delimiters.append(delimiter) catch return error.NestingDepthReached;
    }

    inline fn scopeDelimiterContext(self: *const Context) usize {
        return self.scope_delimiters.len;
    }

    /// Search from the back (end) until the delimiter is found, all the iterated over delimiters get
    /// ignored.
    inline fn popScopeDelimiter(self: *Context, delimiter: ScopeDelimiter) void {
        while (self.scope_delimiters.pop()) |popped_delimiter| {
            if (popped_delimiter == delimiter) break;
        }
    }

    /// Skips tokens until encountering one of the specified token kinds. The matching token will NOT be consumed.
    ///
    /// Scope handling:
    ///   - The function respects scope boundaries - if the given scope ends before finding a matching token,
    ///     the search terminates.
    ///   - Opening and closing scope delimiters encountered during scanning are properly tracked to maintain
    ///     correct scope nesting.
    ///
    /// Returns whether or not given scope is exited.
    fn skipTokensUntilScope(
        self: *Context,
        comptime kinds: []const TokenKindTag,
        scope: usize,
    ) error{NestingDepthReached}!bool {
        // If the scope is already exited, return early.
        if (self.scopeDelimiterContext() < scope) {
            return true;
        }
        while (true) {
            const token = self.it.peek(1) orelse {
                self.scope_delimiters.clear();
                return true;
            };
            if (token.kind == .EOF) {
                self.scope_delimiters.clear();
                self.consume();
                return true;
            }

            if (try self.handleScopeDelimiterRecovery(token.kind, scope)) {
                self.consume();
                return true;
            }

            // consider recovery tokens only if still in the same scope.
            if (self.scopeDelimiterContext() == scope) {
                inline for (kinds) |kind| {
                    if (token.kind == kind) {
                        return false;
                    }
                }
            }
            self.consume();
        }
    }

    /// Skips tokens until encountering one of the specified token kinds. The matching token will NOT be consumed.
    ///
    /// Scope handling:
    ///   - The function respects scope boundaries - if the current scope ends before finding a matching token,
    ///     the search terminates.
    ///   - Opening and closing scope delimiters encountered during scanning are properly tracked to maintain
    ///     correct scope nesting.
    ///
    /// Returns whether or not current scope is exited.
    /// TODO: maybe delete this function.
    fn skipTokensUntil(
        self: *Context,
        comptime kinds: []const TokenKindTag,
    ) error{NestingDepthReached}!bool {
        return try self.skipTokensUntilScope(kinds, self.scopeDelimiterContext());
    }

    /// recover from an UnexpectedToken error (if the err is an UnexpectedToken) using the following
    /// strategy:
    /// * If inside a scope: iterate until then next entry point tokens or if it goes out of the current scope.
    /// * If outside a scope: find the next entrypoint.
    inline fn recover(
        self: *Context,
        err: anytype,
        comptime tokens: []const TokenKindTag,
        scope: usize,
    ) !void {
        _ = try self.recoverExitsScope(err, tokens, scope);
    }

    /// similar to recover but returns whether or not the current scope is exited.
    /// This is helpful for nested structures such as parsing values, objects, annotations, etc.
    inline fn recoverExitsScope(
        self: *Context,
        err: Error,
        comptime tokens: []const TokenKindTag,
        scope: usize,
    ) Error!bool {
        if (err == Error.UnexpectedEOF) {
            return true;
        }
        if (err != Error.UnexpectedToken) {
            return err;
        }

        self.it.goBack(); // revert the token consumption.
        // NB: Inside a scope, go until you find next entry token or falling outside of the
        // current scope.
        if (self.scopeDelimiterContext() > 0) {
            return self.skipTokensUntilScope(tokens, scope);
        } else {
            // If we are already in the root scope, skip until some entry keyword.
            // Unless the starting `scope` is also root, we should consider the scope exited.
            return try self.skipTokensUntilScope(EntryKeywords, 0);
        }
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

const ParseError = tokenizer.TokenizeError || Allocator.Error;

pub const Result = struct {
    allocator: std.heap.ArenaAllocator,
    document: ast.Document,
    errors: []const PragmaError,

    pub fn deinit(self: *Result) void {
        self.allocator.deinit();
    }

    pub fn ok(self: Result) bool {
        return self.errors.len == 0;
    }
};

pub const Options = struct {
    transient_allocator: ?std.mem.Allocator = null,
};

pub fn parse(allocator: Allocator, content: []const u8, opts: Options) ParseError!Result {
    var result_allocator = std.heap.ArenaAllocator.init(allocator);
    errdefer result_allocator.deinit();

    var transient_allocator = std.heap.ArenaAllocator.init(opts.transient_allocator orelse allocator);
    defer transient_allocator.deinit();

    var ctx = Context.init(
        result_allocator.allocator(),
        transient_allocator.allocator(),
        try tokenizer.tokenize(content),
    );
    try ctx.parse();

    return .{
        .allocator = result_allocator,
        .errors = try ctx.buildErrors(),
        .document = .{
            .imports = ctx.imports.items,
            .annotations = ctx.annotations.items,
            .constants = ctx.constants.items,
            .enums = ctx.enums.items,
            .structs = ctx.structs.items,
            .annotation_definitions = ctx.annotation_definitions.items,
            .protocols = ctx.protocols.items,
            .documentation = ctx.documentation,
            .field_types = try ctx.field_types.toOwnedSlice(ctx.allocator),
        },
    };
}
