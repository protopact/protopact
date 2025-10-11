const std = @import("std");
const scanner = @import("scanner.zig");
const parser = @import("parser.zig");
const astcoder = @import("astcoder.zig");

pub fn main() !void {
    const allocator = std.heap.smp_allocator;

    var it = try std.process.argsWithAllocator(allocator);
    _ = it.skip();

    const fileName = it.next() orelse {
        std.debug.print("no filename entered\n", .{});
        return;
    };

    const sourceFile = try std.fs.cwd().openFile(fileName, .{ .mode = .read_only });
    const data = try sourceFile.readToEndAlloc(allocator, 1_000_000);

    const now = std.time.microTimestamp();
    const parseResult = try parser.parse(allocator, data);
    var marshaler = astcoder.YamlMarshaller{
        .excludeZeroValues = true,
        .includeConstants = true,
        .expandSelectors = false,
        .includeDocumentation = true,
        .includeEnums = true,
        .includeImport = true,
        .includeInterfaces = true,
        .includeMessages = true,
        .includeOptionAssignments = true,
        .includeOptionDefinitions = true,
        .includePact = true,
        .includeRange = false,
    };
    const diff = std.time.microTimestamp() - now;
    try marshaler.writeDocument(std.io.getStdOut().writer(), parseResult.document);
    for (parseResult.errors) |err| {
        std.debug.print("\nLiteral: {?s}, Message: {s}, Location: {?any}\n", .{
            err.literal,
            err.message,
            err.location,
        });
    }
    std.debug.print("\ntook {d}ms s\n", .{@as(f32, @floatFromInt(diff)) / 1000.0});
}
