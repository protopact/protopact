const std = @import("std");
const t = std.testing;

const pactum = @import("pactum");
const ast = pactum.ast;
const astcoder = pactum.astcoder;
const parser = pactum.parser;

const Allocator = std.mem.Allocator;

const String = []const u8;
const StringArray = []const String;

const TestCase = struct {
    name: []const u8,
    source: []const u8,
    expected: []const u8,
};

fn formatError(writer: anytype, err: parser.SyntaxError) !void {
    if (err.location) |loc| {
        switch (loc) {
            .Position => try std.fmt.format(writer, "{d}:{d}[{d}] {s} @literal={?s}", .{
                loc.Position.line,
                loc.Position.column,
                loc.Position.offset,
                err.message,
                err.literal,
            }),
            .Range => try std.fmt.format(writer, "{d}:{d}[{d}-{d}] {s} @literal={?s}", .{
                loc.Range.start.line,
                loc.Range.start.column,
                loc.Range.start.offset,
                loc.Range.endOffset,
                err.message,
                err.literal,
            }),
        }
    } else try std.fmt.format(writer, "{s} @literal={?s}", .{
        err.message,
        err.literal,
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
    var list = std.ArrayList(TestCase).init(allocator);

    var cursor: usize = 0;
    while (true) {
        const namePos = cursor + (std.mem.indexOf(u8, source[cursor..], "#") orelse break);
        cursor = namePos + (std.mem.indexOf(u8, source[namePos..], "\n") orelse @panic("invalid test name"));
        const name = std.mem.trim(u8, source[namePos + 2 .. cursor], "\n\t\r ");

        const codeBlock = try captureBlock(source, cursor);
        cursor = codeBlock.newPos;

        const expectationBlock = try captureBlock(source, cursor);
        cursor = expectationBlock.newPos;

        try list.append(.{
            .name = name,
            .source = codeBlock.content,
            .expected = expectationBlock.content,
        });
    }

    return list.items;
}

const TestOptions = struct {
    marshaler: astcoder.YamlMarshaller,
    writeDocumentOnError: bool,
};

fn runTests(comptime sourceFileName: []const u8, opts: TestOptions) !void {
    var allocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer allocator.deinit();

    var includedTests = std.StringHashMap(void).init(allocator.allocator());
    if (std.posix.getenv("TEST_FILTER")) |filter| {
        var it = std.mem.splitScalar(u8, filter, ',');
        while (it.next()) |name| {
            try includedTests.put(name, {});
            std.debug.print("-- Include Test '{s}'\n", .{name});
        }
    }

    const testCases = try readTestCases(allocator.allocator(), @embedFile(sourceFileName));

    for (testCases) |tt| {
        if (includedTests.count() > 0) {
            if (!includedTests.contains(tt.name)) {
                continue;
            }
            std.debug.print("-- Running Test '{s}'\n", .{tt.name});
        }
        var testCaseAllocator = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer testCaseAllocator.deinit();

        const result = try parser.parse(testCaseAllocator.allocator(), tt.source);

        var output = std.ArrayList(u8).init(testCaseAllocator.allocator());

        if (result.ok() or opts.writeDocumentOnError) {
            try opts.marshaler.writeDocument(output.writer(), result.document);
        }

        for (result.errors) |err| {
            if (output.items.len > 0) {
                try output.writer().writeByte('\n');
            }
            try formatError(output.writer(), err);
        }

        const received = std.mem.trim(u8, output.items, "\n\t\r ");
        if (!std.mem.eql(u8, tt.expected, received)) {
            std.debug.print(
                "Test '{s}' failed\n==== Expected ====\n{s}\n\n==== Received ====\n{s}\n\n",
                .{ tt.name, tt.expected, received },
            );
            return error.TestEqualFailed;
        }
    }
}

test "pact" {
    try runTests("./data/parser/pact.md", .{
        .marshaler = astcoder.YamlMarshaller{
            .expandSelectors = true,
            .includePact = true,
            .includeRange = true,
        },
        .writeDocumentOnError = false,
    });
}

test "import" {
    try runTests("./data/parser/import.md", .{
        .marshaler = astcoder.YamlMarshaller{
            .includeImport = true,
            .includeRange = true,
        },
        .writeDocumentOnError = false,
    });
}

test "options" {
    try runTests("./data/parser/options.md", .{
        .marshaler = astcoder.YamlMarshaller{
            .includeOptionAssignments = true,
            .includeRange = true,
        },
        .writeDocumentOnError = true,
    });
}

test "constants" {
    try runTests("./data/parser/constants.md", .{
        .marshaler = astcoder.YamlMarshaller{
            .includeOptionAssignments = true,
            .includeConstants = true,
            .includeRange = true,
            .includeDocumentation = true,
        },
        .writeDocumentOnError = true,
    });
}

test "enums" {
    try runTests("./data/parser/enums.md", .{
        .marshaler = astcoder.YamlMarshaller{
            .includeOptionAssignments = true,
            .includeEnums = true,
            .includeRange = true,
            .includeDocumentation = true,
        },
        .writeDocumentOnError = true,
    });
}

test "messages" {
    try runTests("./data/parser/messages.md", .{
        .marshaler = astcoder.YamlMarshaller{
            .includeOptionAssignments = true,
            .includeMessages = true,
            .includeRange = true,
            .includeDocumentation = true,
        },
        .writeDocumentOnError = true,
    });
}

test "option definitions" {
    try runTests("./data/parser/option_definitions.md", .{
        .marshaler = astcoder.YamlMarshaller{
            .includeOptionAssignments = true,
            .includeOptionDefinitions = true,
            .includeRange = true,
        },
        .writeDocumentOnError = true,
    });
}

test "interfaces" {
    try runTests("./data/parser/interfaces.md", .{
        .marshaler = astcoder.YamlMarshaller{
            .includeOptionAssignments = true,
            .includeRange = true,
            .includeInterfaces = true,
            .includeDocumentation = true,
        },
        .writeDocumentOnError = true,
    });
}

test "documentation" {
    try runTests("./data/parser/documentation.md", .{
        .marshaler = astcoder.YamlMarshaller{
            .excludeZeroValues = true,
            .includeConstants = true,
            .includeEnums = true,
            .includeMessages = true,
            .includeInterfaces = true,
            .includeDocumentation = true,
        },
        .writeDocumentOnError = false,
    });
}

test "errors" {
    try runTests("./data/parser/errors.md", .{
        .marshaler = astcoder.YamlMarshaller{
            .excludeZeroValues = true,
            .includePact = true,
            .includeImport = true,
            .includeOptionAssignments = true,
            .includeConstants = true,
            .includeEnums = true,
            .includeMessages = true,
            .includeOptionDefinitions = true,
            .includeInterfaces = true,
            .includeDocumentation = true,
        },
        .writeDocumentOnError = true,
    });
}
