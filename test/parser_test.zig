const std = @import("std");
const t = std.testing;

const pragma = @import("pragma");
const ast = pragma.ast;
const astcoder = pragma.astcoder;
const parser = pragma.parser;

const Allocator = std.mem.Allocator;

const String = []const u8;
const StringArray = []const String;

const TestCase = struct {
    name: []const u8,
    source: []const u8,
    expected: []const u8,
};

fn formatError(writer: *std.Io.Writer, err: parser.PragmaError, line_map: pragma.LineMap) !void {
    if (err.location) |loc| {
        switch (loc) {
            .position => |pos| {
                const line_info: pragma.LineMap.Position = try line_map.resolveOffset(pos);
                try writer.print("{d}:{d}[{d}] {s}", .{ line_info.line, line_info.column, pos, err.message });
            },
            .range => |range| {
                const start: pragma.LineMap.Position = try line_map.resolveOffset(range.start);
                const end: pragma.LineMap.Position = try line_map.resolveOffset(range.end);
                if (end.line != start.line) {
                    try writer.print("{d}:{d}-{d}:{d}[{d}-{d}] {s} @literal={s}", .{
                        start.line + 1,
                        start.column + 1,
                        end.line + 1,
                        end.column + 1,
                        range.start,
                        range.end,
                        err.message,
                        line_map.source[range.start..range.end],
                    });
                } else {
                    try writer.print("{d}:{d}-{d}[{d}-{d}] {s} @literal={s}", .{
                        start.line + 1,
                        start.column + 1,
                        end.column + 1,
                        range.start,
                        range.end,
                        err.message,
                        line_map.source[range.start..range.end],
                    });
                }
            },
        }
    } else try writer.print("{s}", .{
        err.message,
    });
}

fn captureBlock(source: []const u8, startIndex: usize) !struct { newPos: usize, content: []const u8 } {
    const blockDelimiter = "```";

    var begin = startIndex + (std.mem.indexOf(
        u8,
        source[startIndex..],
        blockDelimiter,
    ) orelse return error.BadBlock);
    // eat the entire line.
    begin += std.mem.indexOf(u8, source[begin..], "\n") orelse return error.BadBlock;
    const end = begin + (std.mem.indexOf(u8, source[begin..], blockDelimiter) orelse return error.BadBlock);

    return .{
        .content = std.mem.trim(u8, source[begin..end], "\n\t\r "),
        .newPos = end + blockDelimiter.len,
    };
}

fn readTestCases(allocator: Allocator, source: String) ![]TestCase {
    var list = try std.ArrayList(TestCase).initCapacity(allocator, 25);

    var cursor: usize = 0;
    while (true) {
        const namePos = cursor + (std.mem.indexOf(u8, source[cursor..], "#") orelse break);
        cursor = namePos + (std.mem.indexOf(u8, source[namePos..], "\n") orelse @panic("invalid test name"));
        const name = std.mem.trim(u8, source[namePos + 2 .. cursor], "\n\t\r ");

        const codeBlock = try captureBlock(source, cursor);
        cursor = codeBlock.newPos;

        const expectationBlock = try captureBlock(source, cursor);
        cursor = expectationBlock.newPos;

        try list.append(allocator, .{
            .name = name,
            .source = codeBlock.content,
            .expected = expectationBlock.content,
        });
    }

    return list.items;
}

const TestOptions = struct {
    coder_options: astcoder.Options,
    write_document_on_error: bool,
};

fn runTests(comptime sourceFileName: []const u8, test_options: TestOptions) !void {
    var allocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer allocator.deinit();

    var includedTests = std.StringHashMap(void).init(allocator.allocator());
    if (std.testing.environ.getPosix("TEST_FILTER")) |filter| {
        var it = std.mem.splitScalar(u8, filter, ',');
        while (it.next()) |name| {
            try includedTests.put(name, {});
            std.debug.print("-- Include Test '{s}'\n", .{name});
        }
    }

    const testCases = try readTestCases(allocator.allocator(), @embedFile(sourceFileName));

    var opts = test_options;
    opts.coder_options.line_map = .empty;
    defer opts.coder_options.line_map.?.deinit(t.allocator);

    for (testCases) |tt| {
        if (includedTests.count() > 0) {
            if (!includedTests.contains(tt.name)) {
                continue;
            }
            std.debug.print("-- Running Test '{s}'\n", .{tt.name});
        }
        var test_case_allocator = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer test_case_allocator.deinit();

        try opts.coder_options.line_map.?.update(t.allocator, tt.source);
        const result = try parser.parse(test_case_allocator.allocator(), tt.source, .{});

        var output = std.Io.Writer.Allocating.init(allocator.allocator());
        defer output.deinit();

        if (result.ok() or opts.write_document_on_error) {
            try pragma.astcoder.YamlMarshaller.writeDocument(&output.writer, result.document, opts.coder_options);
        }

        if (!result.ok()) {
            try output.writer.writeByte('\n');
        }

        for (result.errors) |err| {
            if (output.written().len > 0) {
                try output.writer.writeByte('\n');
            }
            try formatError(&output.writer, err, opts.coder_options.line_map.?);
        }

        try output.writer.flush();

        const received = std.mem.trim(u8, output.toArrayList().items, "\n\t\r ");
        if (!std.mem.eql(u8, tt.expected, received)) {
            std.debug.print(
                "Test '{s}' failed\n==== Expected ====\n{s}\n\n==== Received ====\n{s}\n\n",
                .{ tt.name, tt.expected, received },
            );
            return error.TestEqualFailed;
        }
    }
}

test "import" {
    try runTests("./data/parser/import.md", .{
        .coder_options = astcoder.Options{
            .include_import = true,
            .include_range = true,
            .exclude_zero_values = true,
        },
        .write_document_on_error = false,
    });
}

test "annotations" {
    try runTests("./data/parser/annotations.md", .{
        .coder_options = astcoder.Options{
            .include_annotations = true,
            .include_range = true,
            .exclude_zero_values = true,
        },
        .write_document_on_error = true,
    });
}

test "constants" {
    try runTests("./data/parser/constants.md", .{
        .coder_options = astcoder.Options{
            .include_annotations = true,
            .include_constants = true,
            .include_range = true,
            .include_documentation = true,
            .exclude_zero_values = true,
        },
        .write_document_on_error = true,
    });
}

test "enums" {
    try runTests("./data/parser/enums.md", .{
        .coder_options = astcoder.Options{
            .include_annotations = true,
            .include_enums = true,
            .include_range = true,
            .include_documentation = true,
            .exclude_zero_values = true,
        },
        .write_document_on_error = true,
    });
}

test "structs" {
    try runTests("./data/parser/structs.md", .{
        .coder_options = astcoder.Options{
            .include_annotations = true,
            .include_structs = true,
            .include_range = true,
            .include_documentation = true,
            .exclude_zero_values = true,
        },
        .write_document_on_error = true,
    });
}

// test "option definitions" {
//     try runTests("./data/parser/option_definitions.md", .{
//         .marshaler = astcoder.YamlMarshaller{
//             .includeOptionAssignments = true,
//             .includeOptionDefinitions = true,
//             .includeRange = true,
//         },
//         .writeDocumentOnError = true,
//     });
// }

test "protocols" {
    try runTests("./data/parser/protocols.md", .{
        .coder_options = astcoder.Options{
            .exclude_zero_values = true,
            .include_range = true,
            .include_protocols = true,
            .include_documentation = true,
            .include_annotations = true,
        },
        .write_document_on_error = true,
    });
}

// test "documentation" {
//     try runTests("./data/parser/documentation.md", .{
//         .marshaler = astcoder.YamlMarshaller{
//             .excludeZeroValues = true,
//             .includeConstants = true,
//             .includeEnums = true,
//             .includeMessages = true,
//             .includeInterfaces = true,
//             .includeDocumentation = true,
//         },
//         .writeDocumentOnError = false,
//     });
// }

// test "errors" {
//     try runTests("./data/parser/errors.md", .{
//         .marshaler = astcoder.YamlMarshaller{
//             .excludeZeroValues = true,
//             .includePact = true,
//             .includeImport = true,
//             .includeOptionAssignments = true,
//             .includeConstants = true,
//             .includeEnums = true,
//             .includeMessages = true,
//             .includeOptionDefinitions = true,
//             .includeInterfaces = true,
//             .includeDocumentation = true,
//         },
//         .writeDocumentOnError = true,
//     });
// }
