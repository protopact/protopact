const std = @import("std");
const parser = @import("parser.zig");
const astcoder = @import("astcoder.zig");

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.page_allocator;

    var it = try init.minimal.args.iterateAllocator(allocator);
    _ = it.skip();

    const fileName = it.next() orelse {
        std.debug.print("no filename entered\n", .{});
        return;
    };

    const quiet = if (it.next()) |x| std.mem.eql(u8, x, "-q") else false;

    const data = try std.Io.Dir.cwd().readFileAlloc(init.io, fileName, allocator, std.Io.Limit.unlimited);

    const now = std.Io.Timestamp.now(init.io, std.Io.Clock.awake);
    const parseResult = try parser.parse(allocator, data, .{ .transient_allocator = std.heap.smp_allocator });
    const diff = std.Io.Timestamp.untilNow(now, init.io, std.Io.Clock.awake);
    if (quiet) {
        std.debug.print("\ntook {}ms\n", .{diff.toMilliseconds()});
        return;
    }
    const options = astcoder.Options{
        .expand_key_path = true,
        .exclude_zero_values = true,
        .include_range = true,
        .include_import = true,
        .include_annotations = true,
        .include_constants = true,
        .include_enums = true,
        .include_structs = true,
        .include_annotation_definitions = true,
        .include_protocols = true,
        .include_documentation = true,
        .include_field_types = true,
    };

    var buffer: [2048]u8 = undefined;
    var stdOutFile = std.Io.File.stdout();
    var stdOutWriter = stdOutFile.writer(init.io, &buffer);

    try astcoder.YamlMarshaller.writeDocument(&stdOutWriter.interface, parseResult.document, options);
    try stdOutWriter.interface.flush();
    for (parseResult.errors) |err| {
        std.debug.print("\nCode: {}, Message: {s}, Location: {?any}\n", .{
            err.code,
            err.message,
            err.location,
        });
    }
    std.debug.print("\ntook {}ms\n", .{diff.toMilliseconds()});
}
