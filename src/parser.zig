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

    message: []const u8,
    location: ?Location,

    fn nestingDepthReached(position: usize) PragmaError {
        return .{
            .message = "maximum nesting level of 10 reached",
            .location = Location{ .position = position },
        };
    }

    fn unexpectedToken(token: *const tokenizer.Token) PragmaError {
        if (token.kind == .EOF) {
            return .unexpectedEOF();
        }

        return .{
            .message = "unexpected token",
            .location = Location{ .range = token.range },
        };
    }

    fn redundantAnnotationHash(position: usize) PragmaError {
        return .{
            .message = "redundant use of annotation symbol # in annotation block",
            .location = Location{ .position = position },
        };
    }

    fn extraAnnotationWithoutSigil(token: *const tokenizer.Token) PragmaError {
        return .{
            .message = "use of extra annotation (attribute) without extra modifier, did you mean to use x# ?",
            .location = Location{ .range = token.range },
        };
    }

    fn unusedDocumentation(position: usize) PragmaError {
        return .{
            .message = "unused documentation, use plain comments instead",
            .location = Location{ .position = position },
        };
    }

    fn unexpectedDocumentationPackage(position: usize) PragmaError {
        return .{
            .message = "unexpected package documentation",
            .location = .{ .position = position },
        };
    }

    fn unexpectedEOF() PragmaError {
        return .{
            .message = "unexpected end of file",
            .location = Location{ .position = 0 },
        };
    }

    fn enumVariantNumericalError(token: *const tokenizer.Token) PragmaError {
        return .{
            .message = "enum value must be a positive integer from 0 to 2^32-1",
            .location = Location{ .range = token.range },
        };
    }

    fn fieldTagNumericalError(token: *const tokenizer.Token) PragmaError {
        return .{
            .message = "field tag value must be a positive integer from 1 to 2^32-1",
            .location = Location{ .range = token.range },
        };
    }

    fn funcTagNumericalError(token: *const tokenizer.Token) PragmaError {
        return .{
            .message = "func tag value must be a positive integer from 1 to 2^32-1",
            .location = Location{ .range = token.range },
        };
    }

    fn expectToken(token: *const tokenizer.Token, comptime expected: []const u8) PragmaError {
        if (token.kind == .EOF) {
            return .unexpectedEOF();
        }

        return .{
            .message = "expected " ++ expected,
            .location = Location{ .range = token.range },
        };
    }
};

/// Result of a parse operation with some partial or complete data.
/// If the parse operation is successful or partial but with a successful recovery, scopeExited is false.
/// If recovery leads to escaping the parent scope, then scopeExited is true and means the caller's scope is
/// exited.
fn ParseResult(T: type) type {
    return struct {
        /// data is the
        data: T,
        scope_exited: bool,

        const Self = @This();

        fn initOk(value: T) Self {
            return .{ .data = value, .scope_exited = false };
        }

        fn initScopeExited(value: T) Self {
            return .{ .data = value, .scope_exited = true };
        }

        fn initValue(value: T, scopeExited: bool) Self {
            return .{ .data = value, .scope_exited = scopeExited };
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
        };
    }

    fn parse(self: *Context) ParseError!void {
        self.it.fillTokenBufferIfNeeded();
        // Read and set package documentation.
        try self.consumePackageDocumentation();

        while (self.it.next()) |token| {
            (switch (token.kind) {
                .Import => self.processImport(),
                .ExtraHash, .Hash, .PrivateHash => option: {
                    // NB: Special case where we need to consume the first token itself.
                    self.it.goBack();
                    break :option self.processAnnotation();
                },
                .Const => self.processConst(),
                // .Enum => self.processEnum(),
                // .Struct => self.processMessage(),
                // .Annotation => self.processOptionDefinition(),
                // .Protocol => self.processInterface(),
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
        try self.processGroup(processImportBody);
    }

    fn processImportBody(self: *Context) Error!void {
        const start = self.currentRangeAssumeSafe().start;
        const bare = self.consumeOptionalTokenBool(.Hash);
        var alias: []const u8 = "";

        if (self.consumeOptionalToken(.Identifier)) |alias_token| {
            alias = try self.copyString(alias_token.literal);
        }

        const path_token = self.consumeRequiredToken(.String, "path string") catch |err| {
            return self.recover(err, &.{ .String, .Hash, .Identifier });
        };
        try self.imports.append(self.allocator, .{
            .bare = bare,
            .alias = alias,
            .path = try path_token.kind.String.toOwnedAndEscaped(self.allocator),
            .range = .{ .start = start, .end = path_token.range.end },
        });
    }

    fn processConst(self: *Context) Error!void {
        try self.processGroup(processConstBody);
    }

    inline fn addConst(
        self: *Context,
        name: tokenizer.Token,
        value: ast.RangedLiteral,
        documentation: ?ast.Documentation,
        start: usize,
        annotations: []ast.AnnotationNode,
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
        const ConstRecoveryPoints: []const TokenKindTag = &.{ .Documentation, .Identifier };
        const documentation = try self.consumeStagedDocumentation();
        const start = self.currentRangeAssumeSafe().start;
        const name_token = self.consumeRequiredToken(.Identifier, "const name") catch |err| {
            return self.recover(err, ConstRecoveryPoints);
        };
        // TODO: already can prepare the const and avoid the addConst function calls.
        _ = self.consumeRequiredToken(.Equal, "=") catch |err| {
            return self.recover(err, ConstRecoveryPoints);
        };

        const value = if (self.parseValue()) |v| blk: {
            if (v.scope_exited) {
                try self.addConst(name_token, v.data, documentation, start, &.{});
                return;
            }
            break :blk v.data;
        } else |err| return self.recover(err, ConstRecoveryPoints);

        const annotations: []ast.AnnotationNode = if (self.nextTokenIs(.LeftCurlyBrace)) blk: {
            if (self.parseAnnotationBlock()) |v| {
                break :blk v.data;
            } else |err| {
                try self.addConst(name_token, value, documentation, start, &.{});
                return self.recover(err, ConstRecoveryPoints);
            }
        } else &.{};

        try self.addConst(name_token, value, documentation, start, annotations);
    }

    // fn processEnum(self: *Context) Error!void {
    //     try self.processGroup(processEnumBody);
    // }
    //
    // fn processEnumBody(self: *Context) Error!void {
    //     const EnumEntryRecoveryPoints: []const TokenKindTag = &.{ .Documentation, .Identifier };
    //     const documentation = try self.parseDocumentationGroupForCurrentPosition();
    //     const nameToken = self.consumeRequiredToken(.Identifier, "enum name") catch |err| {
    //         return self.recover(err, EnumEntryRecoveryPoints, false);
    //     };
    //     _ = self.consumeRequiredToken(.LeftCurlyBrace, "{") catch |err| {
    //         return self.recover(err, EnumEntryRecoveryPoints, false);
    //     };
    //
    //     var options = StackFallbackArray(ast.OptionAssignmentNode, 20).init(self.transient_allocator);
    //     var variants = StackFallbackArray(ast.EnumVariant, 20).init(self.transient_allocator);
    //     while (true) {
    //         const token = try self.peekNextOrError();
    //         switch (token.kind) {
    //             .Comment => self.consume(),
    //             .Hash, .ExtraHash, .PrivateHash => if (self.parseOption(false, null)) |v| {
    //                 try options.append(v.data);
    //                 if (v.scope_exited) break;
    //             } else |err| if (try self.recoverExitsScope(err, EnumBodyRecoveryPoints))
    //                 break,
    //             .Identifier => if (self.parseEnumVariant()) |v| {
    //                 try variants.append(v.data);
    //                 if (v.scope_exited) break;
    //             } else |err| if (try self.recoverExitsScope(err, EnumBodyRecoveryPoints))
    //                 break,
    //             .Documentation => try self.captureDocumentationGroup(),
    //             .RightCurlyBrace => {
    //                 self.consume();
    //                 self.popScopeDelimiter(.CurlyBrace);
    //                 break;
    //             },
    //             .Comma => self.consume(),
    //             else => {
    //                 self.addError(PragmaError.unexpectedToken(&token));
    //                 if (try self.skipTokensUntil(EnumBodyRecoveryPoints, false))
    //                     break;
    //             },
    //         }
    //         _ = self.consumeOptionalTokenBool(.Comma);
    //     }
    //
    //     try self.enums.append(self.allocator, ast.Enum{
    //         .name = ast.Identifier{
    //             .value = try self.copyString(nameToken.literal),
    //             .range = nameToken.range(),
    //         },
    //         .variants = try variants.toOwnedSlice(self.allocator),
    //         .documentation = documentation,
    //         .annotations = try options.toOwnedSlice(self.allocator),
    //         .range = .{ .start = nameToken.position, .endOffset = self.it.currentAssumeSafe().endOffset() },
    //     });
    // }

    // inline fn buildEnumVariant(
    //     self: *Context,
    //     nameToken: tokenizer.Token,
    //     value: ?u32,
    //     documentation: ?ast.Documentation,
    //     options: []const ast.OptionAssignmentNode,
    // ) Allocator.Error!ast.EnumVariant {
    //     return .{
    //         .name = ast.Identifier{
    //             .value = try self.copyString(nameToken.literal),
    //             .range = nameToken.range(),
    //         },
    //         .value = value,
    //         .documentation = documentation,
    //         .annotations = options,
    //         .range = .{
    //             .start = nameToken.position,
    //             .endOffset = self.it.currentAssumeSafe().endOffset(),
    //         },
    //     };
    // }

    // fn parseEnumVariant(self: *Context) Error!ParseResult(ast.EnumVariant) {
    //     const documentation = try self.consumeStagedDocumentationFor(self.it.currentAssumeSafe().position);
    //     const nameToken = try self.consumeRequiredToken(.Identifier, "enum value");
    //     var value: ?u32 = null;
    //
    //     if (self.consumeOptionalTokenBool(.Equal)) {
    //         // explicit assignment.
    //         if (self.consumeRequiredToken(.Integer, "enum variant numerical value")) |valueToken| {
    //             if (std.math.cast(u32, valueToken.kind.Integer)) |tag| {
    //                 value = tag;
    //             } else self.addError(PragmaError.enumVariantNumericalError(&valueToken));
    //         } else |err| if (try self.recoverExitsScope(err, &.{ .RawHash, .Hash, .PrivateHash, .Comma })) {
    //             return .initScopeExited(
    //                 try self.buildEnumVariant(nameToken, null, documentation, &.{}),
    //             );
    //         }
    //     }
    //
    //     return if (self.parseItemOptions(.Comma)) |v| .initValue(
    //         try self.buildEnumVariant(nameToken, value, documentation, v.data),
    //         v.scope_exited,
    //     ) else |err| .initValue(
    //         try self.buildEnumVariant(nameToken, value, documentation, &.{}),
    //         try self.recoverExitsScope(err, EnumBodyRecoveryPoints),
    //     );
    // }

    // fn processMessage(self: *Context) Error!void {
    //     try self.processGroup(processMessageBody);
    // }

    // fn processMessageBody(self: *Context) Error!void {
    //     const MessageEntryRecoveryPoints: []const TokenKindTag = &.{ .Documentation, .Identifier };
    //     const documentation = try self.parseDocumentationGroupForCurrentPosition();
    //     const nameToken = self.consumeRequiredToken(.Identifier, "message name") catch |err| {
    //         return self.recover(err, MessageEntryRecoveryPoints, true);
    //     };
    //     _ = self.consumeRequiredToken(.LeftCurlyBrace, "{") catch |err| {
    //         return self.recover(err, MessageEntryRecoveryPoints, false);
    //     };
    //
    //     var options = StackFallbackArray(ast.OptionAssignmentNode, 20).init(self.transient_allocator);
    //     var fields = StackFallbackArray(ast.Field, 40).init(self.transient_allocator);
    //     var embeddedMessages = StackFallbackArray(ast.Selector, 10).init(self.transient_allocator);
    //     var oneOfGroups = StackFallbackArray(ast.OneOf, 10).init(self.transient_allocator);
    //
    //     while (true) {
    //         const token = try self.peekNextOrError();
    //         switch (token.kind) {
    //             .Comment, .Comma => self.consume(),
    //             .Documentation => try self.captureDocumentationGroup(),
    //             .Hash, .ExtraHash, .PrivateHash => if (self.parseOption(false, null)) |v| {
    //                 try options.append(v.data);
    //                 if (v.scope_exited) break;
    //             } else |err| if (try self.recoverExitsScope(err, MessageBodyRecoveryPoints))
    //                 break,
    //             .Identifier => if (self.parseField(null)) |v| {
    //                 try fields.append(v.data);
    //                 if (v.scope_exited) break;
    //             } else |err| if (try self.recoverExitsScope(err, &.{.Comma}))
    //                 break,
    //             .Embed => {
    //                 self.consume();
    //                 if (self.parseSelector()) |selector| {
    //                     // TODO: Might need to keep the field index just so that the position is clear.
    //                     try embeddedMessages.append(selector);
    //                 } else |err| if (try self.recoverExitsScope(err, MessageBodyRecoveryPoints)) break;
    //             },
    //             .OneOf => {
    //                 const start = token.position;
    //                 self.consume();
    //                 const oneOfNameToken = self.consumeRequiredToken(.Identifier, "oneof group name") catch |err|
    //                     if (try self.recoverExitsScope(err, MessageBodyRecoveryPoints)) break else continue;
    //                 if (self.processOneOfBody(@intCast(oneOfGroups.len()), &fields)) |v| {
    //                     try oneOfGroups.append(ast.OneOf{
    //                         .name = ast.Identifier{
    //                             .value = try self.copyString(oneOfNameToken.literal),
    //                             .range = nameToken.range(),
    //                         },
    //                         .annotations = v.data.options,
    //                         .range = ast.Range{
    //                             .start = start,
    //                             .endOffset = self.it.currentAssumeSafe().endOffset(),
    //                         },
    //                     });
    //                 } else |err| if (try self.recoverExitsScope(err, MessageBodyRecoveryPoints)) break;
    //             },
    //             .RightCurlyBrace => {
    //                 self.consume();
    //                 self.popScopeDelimiter(.CurlyBrace);
    //                 break;
    //             },
    //             else => {
    //                 self.addError(PragmaError.unexpectedToken(&token));
    //                 if (try self.skipTokensUntil(MessageBodyRecoveryPoints)) {
    //                     break;
    //                 }
    //             },
    //         }
    //         _ = self.consumeOptionalTokenBool(.Comma);
    //     }
    //
    //     try self.structs.append(self.allocator, ast.Struct{
    //         .name = ast.Identifier{
    //             .value = try self.copyString(nameToken.literal),
    //             .range = nameToken.range(),
    //         },
    //         .embedded_structs = try embeddedMessages.toOwnedSlice(self.allocator),
    //         .documentation = documentation,
    //         .fields = try fields.toOwnedSlice(self.allocator),
    //         .annotations = try options.toOwnedSlice(self.allocator),
    //         .oneof_groups = try oneOfGroups.toOwnedSlice(self.allocator),
    //         .range = .{ .start = nameToken.position, .endOffset = self.it.currentAssumeSafe().endOffset() },
    //     });
    // }

    // inline fn buildField(
    //     self: *Context,
    //     nameToken: tokenizer.Token,
    //     documentation: ?ast.Documentation,
    //     options: []ast.OptionAssignmentNode,
    //     nullable: bool,
    //     tag: ?u16,
    //     dataType: ast.Field.RangedDataType,
    //     oneOfGroupIndex: ?u16,
    // ) Allocator.Error!ast.Field {
    //     return ast.Field{
    //         .name = .{
    //             .value = try self.copyString(nameToken.literal),
    //             .range = nameToken.range(),
    //         },
    //         .documentation = documentation,
    //         .annotations = options,
    //         .nullable = nullable,
    //         .range = ast.Range{
    //             .start = nameToken.position,
    //             .endOffset = self.it.currentAssumeSafe().endOffset(),
    //         },
    //         .tag = tag,
    //         .data_type = dataType,
    //         .oneof_group_index = oneOfGroupIndex,
    //     };
    // }

    // fn parseField(self: *Context, oneOfGroupIndex: ?u16) Error!ParseResult(ast.Field) {
    //     const documentation = try self.consumeStagedDocumentationFor(self.it.currentAssumeSafe().position);
    //     const nameToken = try self.consumeRequiredToken(.Identifier, "field name");
    //     _ = try self.consumeRequiredToken(.Colon, ":");
    //     const nullable = self.consumeOptionalTokenBool(.QuestionMark);
    //
    //     const dataType = try self.parseFieldDataType();
    //     if (dataType.scope_exited) {
    //         return .initScopeExited(
    //             try self.buildField(nameToken, documentation, &.{}, nullable, null, dataType.data, oneOfGroupIndex),
    //         );
    //     }
    //     var tag: ?u16 = null;
    //     if (self.consumeOptionalTokenBool(.Equal)) {
    //         if (self.consumeRequiredToken(.Integer, "field tag number")) |tagToken| {
    //             if (std.math.cast(u16, tagToken.kind.Integer)) |tagValue| {
    //                 if (tagValue == 0) {
    //                     self.addError(PragmaError.fieldTagNumericalError(&tagToken));
    //                 }
    //                 tag = tagValue;
    //             } else self.addError(PragmaError.fieldTagNumericalError(&tagToken));
    //         } else |err| if (try self.recoverExitsScope(err, &.{ .Hash, .RawHash, .PrivateHash, .Comma })) {
    //             return .initScopeExited(
    //                 try self.buildField(nameToken, documentation, &.{}, nullable, tag, dataType.data, oneOfGroupIndex),
    //             );
    //         }
    //     }
    //
    //     return if (self.parseItemOptions(.Comma)) |v| .initValue(
    //         try self.buildField(nameToken, documentation, v.data, nullable, tag, dataType.data, oneOfGroupIndex),
    //         v.scope_exited,
    //     ) else |err| .initValue(
    //         try self.buildField(nameToken, documentation, &.{}, nullable, tag, dataType.data, oneOfGroupIndex),
    //         try self.recoverExitsScope(err, MessageBodyRecoveryPoints),
    //     );
    // }
    //
    // fn parseFieldDataType(self: *Context) Error!ParseResult(ast.Field.RangedDataType) {
    //     const nextToken = try self.peekNextOrError();
    //     switch (nextToken.kind) {
    //         .Identifier => {
    //             const typeSelector = try self.parseSelector();
    //             return .initOk(ast.Field.RangedDataType{
    //                 .value = .{ .String = typeSelector },
    //                 .range = typeSelector.range,
    //             });
    //         },
    //         .OneOf => {
    //             const start = nextToken.position;
    //             self.consume();
    //             const oneOfBody = try self.parseOneOfBodyType();
    //             return .initValue(ast.Field.RangedDataType{
    //                 .value = .{ .OneOf = oneOfBody.data },
    //                 .range = ast.Range{
    //                     .start = start,
    //                     .endOffset = self.it.currentAssumeSafe().endOffset(),
    //                 },
    //             }, oneOfBody.scope_exited);
    //         },
    //         .List => {
    //             const start = nextToken.position;
    //             self.consume();
    //             _ = try self.consumeRequiredToken(.LessThan, "<");
    //             const typeSelector = try self.parseSelector();
    //             const lastToken = try self.consumeRequiredToken(.GreaterThan, ">");
    //             return .initOk(ast.Field.RangedDataType{
    //                 .value = .{ .List = typeSelector },
    //                 .range = ast.Range{ .start = start, .endOffset = lastToken.endOffset() },
    //             });
    //         },
    //         .Map => {
    //             const start = nextToken.position;
    //             self.consume();
    //             _ = try self.consumeRequiredToken(.LessThan, "<");
    //             const keyTypeSelector = try self.parseSelector();
    //             _ = try self.consumeRequiredToken(.Comma, ",");
    //             const valueTypeSelector = try self.parseSelector();
    //             const lastToken = try self.consumeRequiredToken(.GreaterThan, ">");
    //             return .initOk(ast.Field.RangedDataType{
    //                 .value = .{ .Map = .{ .key = keyTypeSelector, .value = valueTypeSelector } },
    //                 .range = ast.Range{ .start = start, .endOffset = lastToken.endOffset() },
    //             });
    //         },
    //         else => {
    //             self.addError(PragmaError.expectToken(&nextToken, "field type"));
    //             self.consume();
    //             return Error.UnexpectedToken;
    //         },
    //     }
    // }
    //
    // fn processOneOfBody(
    //     self: *Context,
    //     oneOfGroupIndex: ?u16,
    //     fields: *StackFallbackArray(ast.Field, 40),
    // ) Error!ParseResult(struct { options: []const ast.OptionAssignmentNode }) {
    //     const OneOfBodyRecoveryPoints: []const TokenKindTag = &.{
    //         .Hash,
    //         .PrivateHash,
    //         .RawHash,
    //         .Comma,
    //         .Identifier,
    //     };
    //     _ = try self.consumeRequiredToken(.LeftCurlyBrace, "{");
    //     var options = StackFallbackArray(ast.OptionAssignmentNode, 20).init(self.transient_allocator);
    //     const currentScope = self.scopeDelimiterContext();
    //
    //     const scopeExited = blk: {
    //         while (true) {
    //             const nextToken = self.it.peek(1) orelse break :blk false;
    //             switch (nextToken.kind) {
    //                 .Identifier => if (self.parseField(oneOfGroupIndex)) |v| {
    //                     // append the field
    //                     try fields.append(v.data);
    //                     if (v.scope_exited) break :blk true;
    //                 } else |err| if (try self.recoverExitsScope(err, &.{.Comma}))
    //                     break :blk true,
    //                 .Hash, .ExtraHash, .PrivateHash => if (self.parseOption(false, null)) |v| {
    //                     try options.append(v.data);
    //                     if (v.scope_exited) break :blk true;
    //                 } else |err| if (try self.recoverExitsScope(err, OneOfBodyRecoveryPoints))
    //                     break :blk true,
    //                 .RightCurlyBrace => {
    //                     self.consume();
    //                     self.popScopeDelimiter(.CurlyBrace);
    //                     break :blk false;
    //                 },
    //                 .Comma => self.consume(),
    //                 else => {
    //                     self.addError(PragmaError.unexpectedToken(&nextToken));
    //                     if (try self.skipTokensUntil(OneOfBodyRecoveryPoints))
    //                         break :blk true;
    //                 },
    //             }
    //             _ = self.consumeOptionalTokenBool(.Comma);
    //         }
    //     };
    //
    //     return .initValue(
    //         .{ .options = try options.toOwnedSlice(self.allocator) },
    //         scopeExited and self.scopeDelimiterContext() + 1 != currentScope,
    //     );
    // }
    //
    // /// parses oneof body that is a field type, not a grouping.
    // fn parseOneOfBodyType(
    //     self: *Context,
    // ) Error!ParseResult(ast.Field.OneOfTypeInfo) {
    //     var fields = StackFallbackArray(ast.Field, 40).init(self.transient_allocator);
    //     return if (self.processOneOfBody(null, &fields)) |result| .initValue(.{
    //         .fields = try fields.toOwnedSlice(self.allocator),
    //         .options = result.data.options,
    //     }, result.scope_exited) else |err| err;
    // }
    //
    // fn parseItemOptions(
    //     self: *Context,
    //     comptime terminationToken: TokenKindTag,
    // ) Error!ParseResult([]ast.OptionAssignmentNode) {
    //     const RecoveryPoints: []const TokenKindTag = &.{ terminationToken, .RawHash, .Hash, .PrivateHash };
    //
    //     if (self.nextTokenIs(.LeftCurlyBrace)) {
    //         return self.parseAnnotationBlock();
    //     }
    //
    //     var values = StackFallbackArray(ast.OptionAssignmentNode, 10).init(self.transient_allocator);
    //     const scopeExited = blk: {
    //         while (true) {
    //             const token = self.it.peek(1) orelse break :blk false;
    //             if (token.kind == .RightCurlyBrace or token.kind == terminationToken) {
    //                 break :blk false;
    //             }
    //             if (self.parseOption(false, null)) |v| {
    //                 try values.append(v.data);
    //                 if (v.scope_exited) break :blk true;
    //             } else |err| if (try self.recoverExitsScope(err, RecoveryPoints))
    //                 break :blk true
    //             else if (!self.nextTokenIsOneOf(RecoveryPoints)) break :blk false;
    //             // NB: If next token is not an option token, exit out of option parsing loop.
    //         }
    //     };
    //
    //     return .initValue(try values.toOwnedSlice(self.allocator), scopeExited);
    // }

    // fn processOptionDefinition(self: *Context) Error!void {
    //     const start = self.it.currentAssumeSafe().position;
    //     _ = try self.consumeRequiredToken(.For, "for");
    //
    //     var targetSet = ast.AnnotationTargetSet.init(.{});
    //     targetSet.insert(try self.parseOptionTarget());
    //     while (true) {
    //         const nextToken = try self.peekNextOrError();
    //         if (nextToken.kind == .LeftCurlyBrace) {
    //             self.consume();
    //             break;
    //         }
    //         _ = try self.consumeRequiredToken(.Comma, ",");
    //         targetSet.insert(try self.parseOptionTarget());
    //     }
    //
    //     var fields = StackFallbackArray(ast.Field, 40).init(self.transient_allocator);
    //
    //     while (true) {
    //         const nextToken = try self.peekNextOrError();
    //         switch (nextToken.kind) {
    //             .Comment, .Comma => self.consume(),
    //             .RightCurlyBrace => {
    //                 self.consume();
    //                 break;
    //             },
    //             else => if (self.parseField(null)) |v| {
    //                 try fields.append(v.data);
    //                 if (v.scope_exited) break;
    //             } else |err| if (try self.recoverExitsScope(err, &.{.Comma}))
    //                 break,
    //         }
    //     }
    //
    //     try self.annotation_definitions.append(self.allocator, ast.AnnotationDefinition{
    //         .targets = targetSet,
    //         .fields = try fields.toOwnedSlice(self.allocator),
    //         .range = .{
    //             .start = start,
    //             .endOffset = self.it.currentAssumeSafe().endOffset(),
    //         },
    //     });
    // }
    //
    // inline fn parseOptionTarget(self: *Context) Error!ast.AnnotationTarget {
    //     const targetToken = self.it.next() orelse {
    //         self.addError(PragmaError.unexpectedEOF());
    //         return Error.UnexpectedEOF;
    //     };
    //     switch (targetToken.kind) {
    //         .TargetPackage => return ast.AnnotationTarget.Package,
    //         .TargetOneOf => return ast.AnnotationTarget.OneOf,
    //         .TargetEnum => return ast.AnnotationTarget.Enum,
    //         .TargetConst => return ast.AnnotationTarget.Constant,
    //         .TargetEnumVariant => return ast.AnnotationTarget.EnumVariant,
    //         .TargetStruct => return ast.AnnotationTarget.Struct,
    //         .TargetField => return ast.AnnotationTarget.Field,
    //         .TargetProtocol => return ast.AnnotationTarget.Protocol,
    //         .TargetFunc => return ast.AnnotationTarget.Func,
    //         else => {
    //             self.addError(PragmaError.expectToken(&targetToken, "option target"));
    //             return Error.UnexpectedToken;
    //         },
    //     }
    // }

    // fn processInterface(self: *Context) Error!void {
    //     try self.processGroup(processInterfaceBody);
    // }
    //
    // fn processInterfaceBody(self: *Context) Error!void {
    //     const InterfaceRecoveryPoints: []const TokenKindTag = &.{ .Interface, .Documentation };
    //     const documentation = try self.parseDocumentationGroupForCurrentPosition();
    //     const nameToken = self.consumeRequiredToken(.Identifier, "interface name") catch |err|
    //         return self.recover(err, InterfaceRecoveryPoints, true);
    //
    //     _ = self.consumeRequiredToken(.LeftCurlyBrace, "") catch |err|
    //         return self.recover(err, InterfaceRecoveryPoints, false);
    //
    //     var funcs = StackFallbackArray(ast.Func, 40).init(self.transient_allocator);
    //     var options = StackFallbackArray(ast.OptionAssignmentNode, 20).init(self.transient_allocator);
    //
    //     while (true) {
    //         const token = try self.peekNextOrError();
    //         switch (token.kind) {
    //             .Semicolon, .Comma, .Comment => self.consume(),
    //             .Hash, .PrivateHash, .ExtraHash => if (self.parseOption(false, null)) |v| {
    //                 try options.append(v.data);
    //                 if (v.scope_exited) break;
    //             } else |err| if (try self.recoverExitsScope(err, InterfaceBodyRecoveryPoints))
    //                 break,
    //             .Documentation => try self.captureDocumentationGroup(),
    //             .Identifier => if (self.parseFunc()) |v| {
    //                 try funcs.append(v.data);
    //                 if (v.scope_exited) break;
    //             } else |err| if (try self.recoverExitsScope(err, &.{.Semicolon}))
    //                 break,
    //             .RightCurlyBrace => {
    //                 self.consume();
    //                 self.popScopeDelimiter(.CurlyBrace);
    //                 break;
    //             },
    //             else => {
    //                 self.addError(PragmaError.unexpectedToken(&token));
    //                 if (try self.skipTokensUntil(InterfaceBodyRecoveryPoints)) {
    //                     break;
    //                 }
    //             },
    //         }
    //     }
    //
    //     try self.protocols.append(self.allocator, ast.Protocol{
    //         .name = ast.Identifier{
    //             .value = try self.copyString(nameToken.literal),
    //             .range = nameToken.range(),
    //         },
    //         .funcs = try funcs.toOwnedSlice(self.allocator),
    //         .documentation = documentation,
    //         .annotations = try options.toOwnedSlice(self.allocator),
    //         .range = ast.Range{
    //             .start = nameToken.position,
    //             .endOffset = self.it.currentAssumeSafe().endOffset(),
    //         },
    //     });
    // }

    // inline fn buildFunc(
    //     self: *Context,
    //     nameToken: tokenizer.Token,
    //     options: []ast.OptionAssignmentNode,
    //     input: ?ast.FuncArg,
    //     output: ?ast.FuncArg,
    //     documentation: ?ast.Documentation,
    //     tag: ?u16,
    // ) Allocator.Error!ast.Func {
    //     return ast.Func{
    //         .name = ast.Identifier{
    //             .value = try self.copyString(nameToken.literal),
    //             .range = nameToken.range(),
    //         },
    //         .annotations = options,
    //         .input = input,
    //         .output = output,
    //         .documentation = documentation,
    //         .tag = tag,
    //         .range = .{
    //             .start = nameToken.position,
    //             .endOffset = self.it.currentAssumeSafe().endOffset(),
    //         },
    //     };
    // }
    //
    // fn parseFunc(self: *Context) Error!ParseResult(ast.Func) {
    //     const documentation = try self.consumeStagedDocumentationFor(self.it.currentAssumeSafe().position);
    //     const nameToken = try self.consumeRequiredToken(.Identifier, "func name");
    //     _ = try self.consumeRequiredToken(.LeftParan, "(");
    //     var input: ?ast.FuncArg = null;
    //     var output: ?ast.FuncArg = null;
    //
    //     // Input
    //     if (!self.consumeOptionalExitScopeTokenBool(.RightParan)) {
    //         input = try self.parseFuncArg();
    //         _ = try self.consumeRequiredToken(.RightParan, ")");
    //     }
    //
    //     // Output
    //     if (self.consumeOptionalTokenBool(.Return)) {
    //         if (try self.consumeOptionalEnterScopeTokenBool(.LeftParan)) {
    //             if (self.nextTokenIs(.Identifier)) {
    //                 output = try self.parseFuncArg();
    //             }
    //             _ = try self.consumeRequiredToken(.RightParan, ")");
    //         } else {
    //             output = try self.parseFuncArg();
    //         }
    //     }
    //
    //     // Optional Tag
    //     var tag: ?u16 = null;
    //     if (self.consumeOptionalTokenBool(.Equal)) {
    //         const tagToken = try self.consumeRequiredToken(.Integer, "func tag");
    //         if (std.math.cast(u16, tagToken.kind.Integer)) |tagValue| {
    //             if (tagValue == 0) {
    //                 self.addError(PragmaError.funcTagNumericalError(&tagToken));
    //             }
    //             tag = tagValue;
    //         } else self.addError(PragmaError.funcTagNumericalError(&tagToken));
    //     }
    //
    //     return if (self.parseItemOptions(.Semicolon)) |v| .initValue(
    //         try self.buildFunc(nameToken, v.data, input, output, documentation, tag),
    //         v.scope_exited,
    //     ) else |err| .initValue(
    //         try self.buildFunc(nameToken, &.{}, input, output, documentation, tag),
    //         try self.recoverExitsScope(err, InterfaceBodyRecoveryPoints),
    //     );
    // }
    //
    // fn parseFuncArg(self: *Context) Error!ast.FuncArg {
    //     const streaming = self.consumeOptionalTokenBool(.Stream);
    //     const name = try self.parseSelector();
    //     return ast.FuncArg{
    //         .name = name,
    //         .streaming = streaming,
    //     };
    // }

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
            .ExtraHash => {
                self.consume();
                return .{ .extra = true };
            },
            .PrivateHash => {
                self.consume();
                return .{ .private = true };
            },
            else => if (needs_hash_prefix) {
                self.addError(PragmaError.expectToken(&token, "option setting modifier or end of statement"));
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

        // Parse the key.
        const key_token = try self.peekNextOrError();
        const keypath = switch (key_token.kind) {
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
                self.addError(PragmaError.expectToken(&key_token, "option identifier or key"));
                self.consume();
                return Error.UnexpectedToken;
            },
        };
        // Parse the value, which can be a curly braces for blocks, a literal or nothing at all to indicate a flag.
        if (self.it.peek(1)) |value_token| switch (value_token.kind) {
            .LeftCurlyBrace => {
                const current_scope = self.scopeDelimiterContext();
                return if (self.parseAnnotationBlock()) |v| .initValue(
                    ast.AnnotationNode{
                        .flags = .{ .private = modifiers.private, .extra = modifiers.extra },
                        .key_path = keypath,
                        .value = .{ .group = v.data },
                        .range = .{
                            .start = start,
                            .end = self.currentRangeAssumeSafe().end,
                        },
                        .profiles = modifiers.profiles,
                    },
                    v.scope_exited and (self.scopeDelimiterContext() + 1 != current_scope),
                ) else |err| err;
            },
            .Equal => {
                self.consume();
                const current_scope = self.scopeDelimiterContext();
                return if (self.parseValue()) |v| .initValue(
                    ast.AnnotationNode{
                        .flags = .{ .extra = modifiers.extra, .private = modifiers.private },
                        .key_path = keypath,
                        .value = .{ .leaf = v.data },
                        .range = .{
                            .start = start,
                            .end = v.data.range.end,
                        },
                        .profiles = modifiers.profiles,
                    },
                    v.scope_exited and (self.scopeDelimiterContext() != current_scope),
                ) else |err| err;
            },
            else => {},
        };

        const range = ast.Range{ .start = start, .end = keypath.range.end };
        return .initOk(ast.AnnotationNode{
            .flags = .{ .extra = modifiers.extra, .private = modifiers.private },
            .key_path = keypath,
            .value = .{
                .leaf = .{
                    .literal = .{ .boolean = true },
                    .range = range,
                },
            },
            .range = range,
            .profiles = modifiers.profiles,
        });
    }

    fn parseAnnotationBlock(self: *Context) Error!ParseResult([]ast.AnnotationNode) {
        const AnnotationBlockRecoveryPoints: []const TokenKindTag = &.{
            .Comma,
            .Identifier,
            .String,
            .Hash,
            .ExtraHash,
            .PrivateHash,
        };
        var values = StackFallbackArray(ast.AnnotationNode, 16).init(self.transient_allocator);
        _ = try self.consumeRequiredToken(.LeftCurlyBrace, "{");
        const current_scope = self.scopeDelimiterContext();
        const scope_exited = blk: {
            while (true) {
                const token = self.it.peek(1) orelse break :blk false;
                switch (token.kind) {
                    .RightCurlyBrace => {
                        self.consume();
                        self.popScopeDelimiter(.CurlyBrace);
                        break :blk false;
                    },
                    else => if (self.parseAnnotation(true, null)) |v| {
                        try values.append(v.data);
                        if (v.scope_exited) break :blk true;
                    } else |err| {
                        if (try self.recoverExitsScope(err, AnnotationBlockRecoveryPoints))
                            break :blk true;
                    },
                }

                _ = self.consumeOptionalTokenBool(.Comma);
            }
        };
        return .initValue(
            try values.toOwnedSlice(self.allocator),
            scope_exited and (self.scopeDelimiterContext() + 1 != current_scope),
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

        const scope_exited = blk: {
            while (true) {
                const next = self.it.peek(1) orelse break :blk false;
                switch (next.kind) {
                    .RightBracket => {
                        self.popScopeDelimiter(.Bracket);
                        self.consume();
                        break :blk false;
                    },
                    .Comma => self.consume(),
                    else => if (self.parseValue()) |v| {
                        try values.append(v.data);
                        if (v.scope_exited) {
                            break :blk true;
                        }
                    } else |err| if (try self.recoverExitsScope(err, ArrayRecoveryPoints)) {
                        break :blk true;
                    },
                }

                _ = self.consumeOptionalTokenBool(.Comma);
            }
        };

        return .initValue(.{
            .literal = ast.LiteralValue{ .array = try values.toOwnedSlice(self.allocator) },
            .range = .{ .start = start, .end = self.it.currentAssumeSafe().range.end },
        }, scope_exited and (self.scopeDelimiterContext() + 1 != current_scope));
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

        const scope_exited = blk: {
            while (true) {
                const next = self.it.next() orelse break :blk true;
                switch (next.kind) {
                    .RightCurlyBrace => {
                        self.popScopeDelimiter(.CurlyBrace);
                        break :blk false;
                    },
                    .Comma => {},
                    .String => {
                        _ = self.consumeRequiredToken(.Colon, ":") catch |err| {
                            if (try self.recoverExitsScope(err, ObjectRecoveryPoints))
                                break :blk true;
                        };
                        if (self.parseValue()) |v| {
                            try values.append(ast.Pair{
                                .key = .{ .string =  try next.kind.String.toOwnedAndEscaped(self.allocator) },
                                .value = v.data,
                            });
                            if (v.scope_exited)
                                break :blk true;
                        } else |err| if (try self.recoverExitsScope(err, ObjectRecoveryPoints))
                            break :blk true;
                    },
                    else => {
                        self.addError(PragmaError.expectToken(&next, "key string literal"));
                        break :blk try self.skipTokensUntil(ObjectRecoveryPoints);
                    },
                }
            }
        };

        return .initValue(.{
            .literal = ast.LiteralValue{ .object = try values.toOwnedSlice(self.allocator) },
            .range = .{ .start = start, .end = self.currentRangeAssumeSafe().end },
        }, scope_exited and (self.scopeDelimiterContext() + 1 != current_scope));
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
            else => {
                self.addError(PragmaError.expectToken(&token, "value"));
                return Error.UnexpectedToken;
            },
        };
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
            const is_documentation = switch (token.kind) { .Documentation => true, else => false };
            if (!is_documentation or !token.kind.Documentation.flags.package) {
                break;
            }

            const content = token.kind.Documentation.content;
            try self.staged_documentation.boundaries.append(content);
            self.staged_documentation.content_size += content.len;
        }

        self.documentation = try self.consumeStagedDocumentation();
    }

    /// parse and stage documentation lines.
    fn stageDocumentationGroup(self: *Context) Allocator.Error!void {
        // TODO: Do we need to clear the previous staged documentation?
        while (self.it.peek(1)) |token| {
            if (token.kind != .Documentation)
                break;

            self.consume();

            if (token.kind.Documentation.flags.package) {
                if (self.staged_documentation.encountered_package_error)
                    self.addError(.unexpectedDocumentationPackage(token.range.start));
                
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
        if (self.staged_documentation.empty())
            return null;
        const content_size = self.staged_documentation.content_size + self.staged_documentation.boundaries.len() - 1;
        var content_buffer = try std.ArrayList(u8).initCapacity(self.allocator, content_size);
        var it = self.staged_documentation.boundaries.iterator();
        content_buffer.appendSliceAssumeCapacity(it.next() orelse unreachable);
        while (it.next()) |boundary| {
            content_buffer.appendAssumeCapacity('\n');
            content_buffer.appendSliceAssumeCapacity(boundary);
        }
        return ast.Documentation{ .content = content_buffer.items };
    }

    fn addError(self: *Context, err: PragmaError) void {
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
    ///   - The function respects scope boundaries - if the current scope ends before finding a matching token,
    ///     the search terminates.
    ///   - Opening and closing scope delimiters encountered during scanning are properly tracked to maintain
    ///     correct scope nesting.
    ///
    /// Returns whether or not current scope is exited.
    fn skipTokensUntil(
        self: *Context,
        comptime kinds: []const TokenKindTag,
    ) error{NestingDepthReached}!bool {
        const current_scope = self.scopeDelimiterContext();
        if (try self.handleScopeDelimiterRecovery(self.it.currentAssumeSafe().kind, current_scope)) {
            self.consume();
            return true;
        }
        while (true) {
            const token = self.it.peek(1) orelse {
                self.scope_delimiters.clear();
                return current_scope > 0;
            };
            if (token.kind == .EOF) {
                self.scope_delimiters.clear();
                self.consume();
                return current_scope > 0;
            }

            if (try self.handleScopeDelimiterRecovery(token.kind, current_scope)) {
                self.consume();
                return true;
            }

            // consider recovery tokens only if still in the same scope.
            if (self.scopeDelimiterContext() == current_scope) {
                inline for (kinds) |kind| {
                    if (token.kind == kind) {
                        return false;
                    }
                }
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
    ) !void {
        if (err != Error.UnexpectedToken) {
            return err;
        }

        self.it.goBack(); // revert the token consumption.
        if (self.scopeDelimiterContext() > 0) {
            // NB: Inside a scope, go until you find next entry token or falling outside of the
            // current scope.
            _ = try self.skipTokensUntil(tokens);
        } else {
            _ = try self.skipTokensUntil(EntryKeywords);
        }
    }

    /// similar to recover but returns whether or not the current scope is exited.
    /// This is helpful for nested structures such as parsing values, objects, options, etc.
    inline fn recoverExitsScope(
        self: *Context,
        err: Error,
        comptime tokens: []const TokenKindTag,
    ) Error!bool {
        if (err != Error.UnexpectedToken) {
            return err;
        }

        self.it.goBack(); // revert the token consumption.
        // NB: Inside a scope, go until you find next entry token or falling outside of the
        // current scope.
        return if (self.scopeDelimiterContext() > 0)
            self.skipTokensUntil(tokens)
        else
            self.skipTokensUntil(EntryKeywords);
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
        },
    };
}
