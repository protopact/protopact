const std = @import("std");
const pragma = @import("pragma");
const tokenizer = pragma.tokenizer;

test "tokenize" {
    const allocator = std.testing.allocator;

    const ErrorExpectation = struct {
        message: []const u8,
        literal: []const u8,
    };

    const NoError = &[_]ErrorExpectation{};

    const TestCase = struct {
        source: []const u8,
        expectation: []const u8,
        errors: []const ErrorExpectation,
    };
    const tests = &[_]TestCase{
        // Identifier and Simple Statements
        .{
            .source = "name = 1.23",
            .expectation = "<Identifier:name><Equal><Float:1.23><EOF>",
            .errors = NoError,
        },
        .{
            .source = "pact meshapi.gateway.v1alpha1",
            .expectation = "<Pact><Identifier:meshapi><Dot><Identifier:gateway><Dot><Identifier:v1alpha1><EOF>",
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
            .expectation = "<Comment: this is a comment><EOF>",
            .errors = NoError,
        },
        .{
            .source = "/// this is a documentation",
            .expectation = "<Documentation: this is a documentation:+0><EOF>",
            .errors = NoError,
        },
        .{
            .source = "////! this is a comment",
            .expectation = "<Comment:! this is a comment><EOF>",
            .errors = NoError,
        },
        .{
            .source =
            \\/** single line documentation*/
            ,
            .expectation = "<Documentation: single line documentation:+0><EOF>",
            .errors = NoError,
        },
        .{
            .source =
            \\/* single line comment*/
            ,
            .expectation = "<Comment: single line comment><EOF>",
            .errors = NoError,
        },
        .{
            .source =
            \\/** this is a multi-line documentation
            \\    here is another line with * but no /
            \\ *  and here is a line that starts with a star.
            \\ */
            ,
            .expectation = "<Documentation: this is a multi-line documentation:+3><EOF>",
            .errors = NoError,
        },
        .{
            .source =
            \\/* this is a multi-line comment
            \\   here is another line with * but no /
            \\ * and here is a line that starts with a star.
            \\ ***/
            ,
            .expectation = "<Comment: this is a multi-line comment:+3><EOF>",
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
            .errors = &[_]ErrorExpectation{.{ .literal = "-", .message = "unexpected character" }},
        },
        .{
            .source = "9999999999999999999999999999",
            .expectation = "<Integer:0><EOF>",
            .errors = &[_]ErrorExpectation{.{
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
            .errors = &[_]ErrorExpectation{.{ .literal = "'some string", .message = "unterminated string" }},
        },
        .{
            .source =
            \\"unterminated string
            \\12
            ,
            .expectation = "<String:unterminated string><Integer:12><EOF>",
            .errors = &[_]ErrorExpectation{.{ .literal = "\"unterminated string", .message = "unterminated string" }},
        },

        // Unicode
        .{
            .source = "name = '∑a=b⦿'",
            .expectation = "<Identifier:name><Equal><String:∑a=b⦿><EOF>",
            .errors = NoError,
        },
        .{
            .source = "// this is a comment with unicode ∑⦿",
            .expectation = "<Comment: this is a comment with unicode ∑⦿><EOF>",
            .errors = NoError,
        },
        .{
            .source =
            \\/* some comment
            \\ * line
            \\ #required
            ,
            .expectation = "<EOF>",
            .errors = &[_]ErrorExpectation{.{
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
            \\ /* unicode ∑*⦿ */
            ,
            .expectation = "<Comment: unicode ∑*⦿ ><EOF>",
            .errors = NoError,
        },
        .{
            .source = "name∑ = 1",
            .expectation = "<Identifier:name><Equal><Integer:1><EOF>",
            .errors = &[_]ErrorExpectation{.{ .literal = "∑", .message = "unexpected character" }},
        },
        .{
            .source = "1.∑3",
            .expectation = "<Integer:1><Dot><Integer:3><EOF>",
            .errors = &[_]ErrorExpectation{.{ .literal = "∑", .message = "unexpected character" }},
        },
        .{
            .source = "-∑",
            .expectation = "<EOF>",
            .errors = &[_]ErrorExpectation{.{ .literal = "∑", .message = "unexpected character" }},
        },
        .{
            .source = "#required",
            .expectation = "<Hash><Identifier:required><EOF>",
            .errors = NoError,
        },

        // Bad Pact
        .{
            .source =
            \\pact meshapi.gateway.
            \\
            \\message User {
            \\}
            ,
            .expectation = "<Pact><Identifier:meshapi><Dot><Identifier:gateway><Dot>" ++
                "<Message><Identifier:User><LeftCurlyBrace><RightCurlyBrace><EOF>",
            .errors = NoError,
        },

        // Multiple Errors
        .{
            .source =
            \\import "some/package
            \\pact mesh∑.api.v1
            \\import 'some/package"
            \\#max = 111111111111111111111111111111 #required
            ,
            .expectation = "<Import><String:some/package><Pact><Identifier:mesh><Dot>" ++
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
        try result.debug(testAllocator.allocator(), &writer);

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
            "Unexpected error[#{d}]:\n Message: {s}\n Position: {any}\n Literal: '{s}'\n",
            .{
                index + 1,
                unexpectedErr.message,
                unexpectedErr.position,
                unexpectedErr.literal orelse "n/a",
            },
        );
    }
    return error.UnexpectedError;
}

fn formatTokenWithPosition(ally: std.mem.Allocator, writer: *std.Io.Writer, tokens: []const tokenizer.Token) !void {
    var lineBuffer: [512]u8 = undefined;
    for (tokens) |item| {
        var lineWriter = std.Io.Writer.fixed(&lineBuffer);
        try item.debug(ally, &lineWriter);
        var lineContent = lineWriter.buffered();
        try writer.print("{s}|{d},{d}>", .{
            lineContent[0 .. lineContent.len - 1],
            item.position.line,
            item.position.column,
        });
    }
}

test "positions" {
    const allocator = std.testing.allocator;

    const TestCase = struct {
        source: []const u8,
        expectation: []const u8,
    };
    const tests = &[_]TestCase{
        .{
            .source = "name = 'pactum'",
            .expectation = "<Identifier:name|1,1><Equal|1,6><String:pactum|1,8><EOF|1,16>",
        },
        .{
            .source =
            \\pact some.package
            \\/** some single-line documentation */
            ,
            .expectation = "<Pact|1,1><Identifier:some|1,6><Dot|1,10><Identifier:package|1,11>" ++
                "<Documentation: some single-line documentation :+0|2,1><EOF|2,38>",
        },
        .{
            .source =
            \\pact some.package
            \\/** some multi-line documentation
            \\  * another line
            \\  */
            ,
            .expectation = "<Pact|1,1><Identifier:some|1,6><Dot|1,10><Identifier:package|1,11>" ++
                "<Documentation: some multi-line documentation:+2|2,1><EOF|4,5>",
        },
        .{
            .source = "name = 'I love Unicode ⬣ !' 1.24",
            .expectation = "<Identifier:name|1,1><Equal|1,6><String:I love Unicode ⬣ !|1,8>" ++
                "<Float:1.24|1,29><EOF|1,33>",
        },
        .{
            .source = "name = 'a ⬣ b' /* comment ⬣ */ x = 1",
            .expectation = "<Identifier:name|1,1><Equal|1,6><String:a ⬣ b|1,8>" ++
                "<Comment: comment ⬣ |1,16><Identifier:x|1,32><Equal|1,34><Integer:1|1,36><EOF|1,37>",
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
        try formatTokenWithPosition(testAllocator.allocator(), &writer, result.tokens);
        try std.testing.expectEqualStrings(
            tt.expectation,
            writer.buffered(),
        );
    }
}
