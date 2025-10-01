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

fn trimAllWhitespace(input: []const u8) []const u8 {
    var start: usize = 0;
    var end: usize = input.len - 1;
    for (input, 0..) |value, i| {
        switch (value) {
            ' ', '\t', '\n', '\r' => continue,
            else => {
                start = i;
                break;
            },
        }
    }
    while (end >= start) {
        switch (input[end]) {
            ' ', '\t', '\n', '\r' => end -= 1,
            else => break,
        }
    }
    return input[start .. end + 1];
}

fn readTestCases(allocator: Allocator, source: String) ![]TestCase {
    const endOfSource = "\n\n\n--";
    var list = std.ArrayList(TestCase).init(allocator);

    var cursor: usize = 0;
    while (true) {
        var position = cursor + (std.mem.indexOf(u8, source[cursor..], "==") orelse break);
        const eol = position + (std.mem.indexOf(u8, source[position..], "\n") orelse @panic("invalid test name"));
        const name = trimAllWhitespace(source[position + 2 .. eol]);

        cursor = eol;
        position = cursor + (std.mem.indexOf(u8, source[cursor..], endOfSource) orelse
            @panic("could not read test source code"));
        const code = trimAllWhitespace(source[cursor..position]);

        cursor = position + endOfSource.len;
        if (std.mem.indexOf(u8, source[cursor..], "\n\n==")) |pos| {
            const expectation = trimAllWhitespace(source[cursor .. cursor + pos]);
            try list.append(.{ .source = code, .name = name, .expected = expectation });
            cursor += pos;
        } else {
            const expectation = trimAllWhitespace(source[cursor..]);
            try list.append(.{ .source = code, .name = name, .expected = expectation });
            break;
        }
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

        const received = trimAllWhitespace(output.items);
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
    try runTests("./data/parser/pact.txt", .{
        .marshaler = astcoder.YamlMarshaller{
            .expandSelectors = true,
            .excludeZeroValues = false,
            .includePact = true,
            .includeImport = false,
            .includeOptionAssignments = false,
            .includeConstants = false,
            .includeEnums = false,
            .includeMessages = false,
            .includeOptionDefinitions = false,
            .includeInterfaces = false,
            .includeRange = true,
            .includeDocumentation = false,
        },
        .writeDocumentOnError = false,
    });
}

test "import" {
    try runTests("./data/parser/import.txt", .{
        .marshaler = astcoder.YamlMarshaller{
            .expandSelectors = false,
            .excludeZeroValues = false,
            .includePact = false,
            .includeImport = true,
            .includeOptionAssignments = false,
            .includeConstants = false,
            .includeEnums = false,
            .includeMessages = false,
            .includeOptionDefinitions = false,
            .includeInterfaces = false,
            .includeRange = true,
            .includeDocumentation = false,
        },
        .writeDocumentOnError = false,
    });
}

test "options" {
    try runTests("./data/parser/options.txt", .{
        .marshaler = astcoder.YamlMarshaller{
            .expandSelectors = false,
            .excludeZeroValues = false,
            .includePact = false,
            .includeImport = false,
            .includeOptionAssignments = true,
            .includeConstants = false,
            .includeEnums = false,
            .includeMessages = false,
            .includeOptionDefinitions = false,
            .includeInterfaces = false,
            .includeRange = true,
            .includeDocumentation = false,
        },
        .writeDocumentOnError = true,
    });
}

test "const" {
    try runTests("./data/parser/constants.txt", .{
        .marshaler = astcoder.YamlMarshaller{
            .expandSelectors = false,
            .excludeZeroValues = false,
            .includePact = false,
            .includeImport = false,
            .includeOptionAssignments = true,
            .includeConstants = true,
            .includeEnums = false,
            .includeMessages = false,
            .includeOptionDefinitions = false,
            .includeInterfaces = false,
            .includeRange = true,
            .includeDocumentation = true,
        },
        .writeDocumentOnError = true,
    });
}

test "enum" {
    try runTests("./data/parser/enums.txt", .{
        .marshaler = astcoder.YamlMarshaller{
            .expandSelectors = false,
            .excludeZeroValues = false,
            .includePact = false,
            .includeImport = false,
            .includeOptionAssignments = true,
            .includeConstants = false,
            .includeEnums = true,
            .includeMessages = false,
            .includeOptionDefinitions = false,
            .includeInterfaces = false,
            .includeRange = true,
            .includeDocumentation = true,
        },
        .writeDocumentOnError = true,
    });
}

test "messages" {
    try runTests("./data/parser/messages.txt", .{
        .marshaler = astcoder.YamlMarshaller{
            .expandSelectors = false,
            .excludeZeroValues = false,
            .includePact = false,
            .includeImport = false,
            .includeOptionAssignments = true,
            .includeConstants = false,
            .includeEnums = false,
            .includeMessages = true,
            .includeOptionDefinitions = false,
            .includeInterfaces = false,
            .includeRange = true,
            .includeDocumentation = true,
        },
        .writeDocumentOnError = true,
    });
}

test "option definitions" {
    try runTests("./data/parser/option_definitions.txt", .{
        .marshaler = astcoder.YamlMarshaller{
            .expandSelectors = false,
            .excludeZeroValues = false,
            .includePact = false,
            .includeImport = false,
            .includeOptionAssignments = true,
            .includeConstants = false,
            .includeEnums = false,
            .includeMessages = false,
            .includeOptionDefinitions = true,
            .includeInterfaces = false,
            .includeRange = true,
            .includeDocumentation = false,
        },
        .writeDocumentOnError = true,
    });
}

test "interface definitions" {
    try runTests("./data/parser/interfaces.txt", .{
        .marshaler = astcoder.YamlMarshaller{
            .expandSelectors = false,
            .excludeZeroValues = false,
            .includePact = false,
            .includeImport = false,
            .includeOptionAssignments = true,
            .includeConstants = false,
            .includeEnums = false,
            .includeMessages = false,
            .includeOptionDefinitions = false,
            .includeRange = true,
            .includeInterfaces = true,
            .includeDocumentation = true,
        },
        .writeDocumentOnError = true,
    });
}

test "documentation" {
    try runTests("./data/parser/documentation.txt", .{
        .marshaler = astcoder.YamlMarshaller{
            .expandSelectors = false,
            .excludeZeroValues = true,
            .includePact = false,
            .includeImport = false,
            .includeOptionAssignments = false,
            .includeConstants = true,
            .includeEnums = true,
            .includeMessages = true,
            .includeOptionDefinitions = false,
            .includeRange = false,
            .includeInterfaces = true,
            .includeDocumentation = true,
        },
        .writeDocumentOnError = false,
    });
}

test "errors" {
    try runTests("./data/parser/errors.txt", .{
        .marshaler = astcoder.YamlMarshaller{
            .expandSelectors = false,
            .excludeZeroValues = true,
            .includePact = true,
            .includeImport = true,
            .includeOptionAssignments = true,
            .includeConstants = true,
            .includeEnums = true,
            .includeMessages = true,
            .includeOptionDefinitions = true,
            .includeRange = false,
            .includeInterfaces = true,
            .includeDocumentation = true,
        },
        .writeDocumentOnError = true,
    });
}
