const std = @import("std");
const pragma = @import("pragma");
const tokenizer = pragma.tokenizer;

test "tokenize" {
    const allocator = std.testing.allocator;

    const ErrorExpectation = struct {
        message: []const u8,
        literal: []const u8,
    };

    const NoError: []const ErrorExpectation = &.{};

    const TestCase = struct {
        source: []const u8,
        expectation: []const u8,
        errors: []const ErrorExpectation,
    };
    const tests: []const TestCase = &.{
        // Identifier and Simple Statements
        .{
            .source = "name = 1.23",
            .expectation = "<Identifier:name><Equal><Float:1.23><EOF>",
            .errors = NoError,
        },
        .{
            .source = "`option` = 1.23",
            .expectation = "<Identifier:option><Equal><Float:1.23><EOF>",
            .errors = NoError,
        },

        // Comments and Documentation
        .{
            .source = "// this is a comment",
            .expectation = "<EOF>",
            .errors = NoError,
        },
        .{
            .source = "/// this is a documentation",
            .expectation = "<Documentation:this is a documentation><EOF>",
            .errors = NoError,
        },
        .{
            .source = "////! this is a comment",
            .expectation = "<EOF>",
            .errors = NoError,
        },
        .{
            .source =
            \\/** single line comment with two stars*/
            \\//! Package Documentation
            ,
            .expectation = "<Documentation:Package Documentation:package><EOF>",
            .errors = NoError,
        },
        .{
            .source =
            \\/* single line comment*/
            ,
            .expectation = "<EOF>",
            .errors = NoError,
        },
        .{
            .source =
            \\/* this is a multi-line comment
            \\   here is another line with * but no /
            \\ * and here is a line that starts with a star.
            \\ ***/
            ,
            .expectation = "<EOF>",
            .errors = NoError,
        },

        // Numbers
        .{
            .source = "1.23",
            .expectation = "<Float:1.23><EOF>",
            .errors = NoError,
        },
        .{
            .source = "x = 1",
            .expectation = "<Identifier:x><Equal><Integer:1><EOF>",
            .errors = NoError,
        },
        .{
            .source = "-1.3",
            .expectation = "<Float:-1.3><EOF>",
            .errors = NoError,
        },
        .{
            .source = "102392",
            .expectation = "<Integer:102392><EOF>",
            .errors = NoError,
        },
        .{
            .source = "-102391",
            .expectation = "<Integer:-102391><EOF>",
            .errors = NoError,
        },
        .{
            .source = "-1.",
            .expectation = "<Integer:-1><Dot><EOF>",
            .errors = NoError,
        },
        .{
            .source = "--102391",
            .expectation = "<Integer:102391><EOF>",
            .errors = &.{ .{ .literal = "-", .message = "unexpected character" } },
        },
        .{
            .source = "9999999999999999999999999999",
            .expectation = "<Integer:0><EOF>",
            .errors = &.{.{
                .literal = "9999999999999999999999999999",
                .message = "invalid integer number",
            }},
        },

        // Strings
        .{
            .source = "import typev2 'spendinglog/types/v2'",
            .expectation = "<Import><Identifier:typev2><String:spendinglog/types/v2><EOF>",
            .errors = NoError,
        },
        .{
            .source = "name = 'I\\'ve got skips!'",
            .expectation = "<Identifier:name><Equal><String:I've got skips!><EOF>",
            .errors = NoError,
        },
        .{
            .source = "name = \"I\\\"ve got\\ skips!\"",
            .expectation = "<Identifier:name><Equal><String:I\"ve got\\ skips!><EOF>",
            .errors = NoError,
        },
        .{
            .source = "name = 'some string",
            .expectation = "<Identifier:name><Equal><String:some string><EOF>",
            .errors = &.{.{ .literal = "'some string", .message = "unterminated string" }},
        },
        .{
            .source =
            \\"unterminated string
            \\12
            ,
            .expectation = "<String:unterminated string><Integer:12><EOF>",
            .errors = &.{.{ .literal = "\"unterminated string", .message = "unterminated string" }},
        },

        // Unicode
        .{
            .source = "name = '∑a=b⦿'",
            .expectation = "<Identifier:name><Equal><String:∑a=b⦿><EOF>",
            .errors = NoError,
        },
        .{
            .source = "// this is a comment with unicode ∑⦿",
            .expectation = "<EOF>",
            .errors = NoError,
        },
        .{
            .source =
            \\/* some comment
            \\ * line
            \\ #required
            ,
            .expectation = "<EOF>",
            .errors = &.{.{
                .literal =
                \\/* some comment
                \\ * line
                \\ #required
                ,
                .message = "unterminated multi-line comment/documentation",
            }},
        },
        .{
            .source =
            \\ /// unicode ∑*⦿ 
            ,
            .expectation = "<Documentation:unicode ∑*⦿ ><EOF>",
            .errors = NoError,
        },
        .{
            .source = "name∑ = 1",
            .expectation = "<Identifier:name><Equal><Integer:1><EOF>",
            .errors = &.{.{ .literal = "∑", .message = "unexpected character" }},
        },
        .{
            .source = "1.∑3",
            .expectation = "<Integer:1><Dot><Integer:3><EOF>",
            .errors = &.{.{ .literal = "∑", .message = "unexpected character" }},
        },
        .{
            .source = "-∑",
            .expectation = "<EOF>",
            .errors = &.{.{ .literal = "∑", .message = "unexpected character" }},
        },
        .{
            .source = "#required",
            .expectation = "<Hash><Identifier:required><EOF>",
            .errors = NoError,
        },
        .{
            .source = "p#required",
            .expectation = "<PrivateHash><Identifier:required><EOF>",
            .errors = NoError,
        },
        .{
            .source = "px#required",
            .expectation = "<PrivateExtraHash><Identifier:required><EOF>",
            .errors = NoError,
        },
        .{
            .source = "xp#required",
            .expectation = "<Identifier:xp><Hash><Identifier:required><EOF>",
            .errors = NoError,
        },
        .{
            .source = "p[mode1,mode2]#required",
            .expectation = "<PrivateMode><Identifier:mode1><Comma><Identifier:mode2><RightBracket><Hash><Identifier:required><EOF>",
            .errors = NoError,
        },
        .{
            .source = "px[mode1]#required",
            .expectation = "<PrivateExtraMode><Identifier:mode1><RightBracket><Hash><Identifier:required><EOF>",
            .errors = NoError,
        },
        .{
            .source = "const a = { @ref(some.field) = @ref(`Enum`) }",
            .expectation = "<Const><Identifier:a><Equal><LeftCurlyBrace><At><Identifier:ref><LeftParan>" ++ 
                "<Identifier:some><Dot><Identifier:field><RightParan><Equal><At><Identifier:ref><LeftParan>" ++ 
                "<Identifier:Enum><RightParan><RightCurlyBrace><EOF>",
            .errors = NoError,
        },
        .{
            .source = "annotation for Package, Struct",
            .expectation = "<Annotation><For><TargetPackage><Comma><TargetStruct><EOF>",
            .errors = NoError,
        },

        // Incomplete keypath
        .{
            .source =
            \\#meshapi.gateway.
            \\
            \\struct User {
            \\}
            ,
            .expectation = "<Hash><Identifier:meshapi><Dot><Identifier:gateway><Dot>" ++
                "<Struct><Identifier:User><LeftCurlyBrace><RightCurlyBrace><EOF>",
            .errors = NoError,
        },

        // Multiple Errors
        .{
            .source =
            \\import "some/package
            \\#mesh∑.api.v1
            \\import 'some/package"
            \\#max = 111111111111111111111111111111 #required
            ,
            .expectation = "<Import><String:some/package><Hash><Identifier:mesh><Dot>" ++
                "<Identifier:api><Dot><Identifier:v1><Import><String:some/package\"><Hash>" ++
                "<Identifier:max><Equal><Integer:0><Hash><Identifier:required><EOF>",
            .errors = &[_]ErrorExpectation{
                .{ .literal = "\"some/package", .message = "unterminated string" },
                .{ .literal = "∑", .message = "unexpected character" },
                .{ .literal = "'some/package\"", .message = "unterminated string" },
                .{ .literal = "111111111111111111111111111111", .message = "invalid integer number" },
            },
        },
    };

    var buffer: [512]u8 = undefined;

    for (tests) |tt| {
        var writer = std.Io.Writer.fixed(&buffer);

        var result = try tokenizer.tokenizeAlloc(allocator, tt.source);
        defer result.deinit();

        for (tt.errors, 0..) |expectedErr, index| {
            if (result.errors.len <= index) {
                std.debug.print(
                    "Expected error [#{d}] '{s}' but received no error at this position\n",
                    .{ index + 1, expectedErr.message },
                );
                return error.TestErrorWasNotReturned;
            } else {
                try std.testing.expectEqualStrings(expectedErr.message, result.errors[index].message);
                try std.testing.expectEqualStrings(expectedErr.literal, result.errors[index].literal orelse "");
            }
        }

        if (result.errors.len > tt.errors.len) {
            try expectNoScanError(result.errors[tt.errors.len..]);
        }

        var testAllocator = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer testAllocator.deinit();
        try result.format(&writer);

        try std.testing.expectEqualStrings(
            tt.expectation,
            writer.buffered(),
        );
    }
}

fn expectNoScanError(errors: []const tokenizer.Error) !void {
    if (errors.len == 0) {
        return;
    }

    for (errors, 0..) |unexpectedErr, index| {
        std.debug.print(
            "Unexpected error[#{d}]:\n Message: {s}\n Range: {}-{}\n Literal: '{s}'\n",
            .{
                index + 1,
                unexpectedErr.message,
                unexpectedErr.range.start,
                unexpectedErr.range.end,
                unexpectedErr.literal orelse "n/a",
            },
        );
    }
    return error.UnexpectedError;
}

fn formatTokenWithPosition(writer: *std.Io.Writer, tokens: []const tokenizer.Token) !void {
    var line_buffer: [512]u8 = undefined;
    for (tokens) |item| {
        var line_writer = std.Io.Writer.fixed(&line_buffer);
        try item.format(&line_writer);
        var line_content = line_writer.buffered();
        try writer.print("{s}|{d}-{d}>", .{
            line_content[0 .. line_content.len - 1],
            item.range.start,
            item.range.end,
        });
    }
}

test "range" {
    const allocator = std.testing.allocator;

    const TestCase = struct {
        source: []const u8,
        expectation: []const u8,
    };
    const tests: []const TestCase = &.{
        .{
            .source = "name = 'pragma'",
            .expectation = "<Identifier:name|0-4><Equal|5-6><String:pragma|7-15><EOF|15-15>",
        },
        .{
            .source =
            \\#some.package
            \\/// some single-line documentation
            ,
            .expectation = "<Hash|0-1><Identifier:some|1-5><Dot|5-6><Identifier:package|6-13>" ++
                "<Documentation:some single-line documentation|14-48><EOF|48-48>",
        },
        .{
            .source =
            \\px[internal]#github.org = "something"
            \\/// trim leading space
            \\///some documentation
            ,
            .expectation = "<PrivateExtraMode|0-3><Identifier:internal|3-11><RightBracket|11-12>" ++
                "<Hash|12-13><Identifier:github|13-19><Dot|19-20><Identifier:org|20-23><Equal|24-25>" ++
                "<String:something|26-37><Documentation:trim leading space|38-60>" ++
                "<Documentation:some documentation|61-82><EOF|82-82>",
        },
        .{
            .source = "name = 'I love Unicode ⬣ !' 1.24",
            .expectation = "<Identifier:name|0-4><Equal|5-6><String:I love Unicode ⬣ !|7-29>" ++
                "<Float:1.24|30-34><EOF|34-34>",
        },
        .{
            .source = "name = 'a ⬣ b' /* comment ⬣ */ x = 1",
            .expectation = "<Identifier:name|0-4><Equal|5-6><String:a ⬣ b|7-16><Identifier:x|35-36><Equal|37-38>" ++
                "<Integer:1|39-40><EOF|40-40>",
        },
    };

    var buffer: [512]u8 = undefined;

    for (tests) |tt| {
        var writer = std.Io.Writer.fixed(&buffer);

        var testAllocator = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer testAllocator.deinit();

        var result = try tokenizer.tokenizeAlloc(allocator, tt.source);
        defer result.deinit();
        try expectNoScanError(result.errors);
        try formatTokenWithPosition(&writer, result.tokens);
        try std.testing.expectEqualStrings(
            tt.expectation,
            writer.buffered(),
        );
    }
}
