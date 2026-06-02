const std = @import("std");
const parser = @import("parser.zig");
const astcoder = @import("astcoder.zig");

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    var it = try std.process.argsWithAllocator(allocator);
    _ = it.skip();

    const fileName = it.next() orelse {
        std.debug.print("no filename entered\n", .{});
        return;
    };

    const quiet = if (it.next()) |x| std.mem.eql(u8, x, "-q") else false;

    const data = try std.fs.cwd().readFileAlloc(allocator, fileName, std.math.maxInt(usize));

    const now = std.time.microTimestamp();
    const parseResult = try parser.parse(allocator, data, .{ .transientAllocator = std.heap.smp_allocator });
    const diff = std.time.microTimestamp() - now;
    if (quiet) {
        std.debug.print("\ntook {d}ms\n", .{@as(f32, @floatFromInt(diff)) / 1000.0});
        return;
    }
    const marshaler = astcoder.YamlMarshaller{
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

    var buffer: [2048]u8 = undefined;
    var stdOutFile = std.fs.File.stdout();
    var stdOutWriter = stdOutFile.writer(&buffer);

    try marshaler.writeDocument(&stdOutWriter.interface, parseResult.document);
    try stdOutWriter.interface.flush();
    for (parseResult.errors) |err| {
        std.debug.print("\nLiteral: {?s}, Message: {s}, Location: {?any}\n", .{
            err.literal,
            err.message,
            err.location,
        });
    }
    std.debug.print("\ntook {d}ms\n", .{@as(f32, @floatFromInt(diff)) / 1000.0});
}
