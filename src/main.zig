const std = @import("std");
const parser = @import("parser.zig");
const astcoder = @import("astcoder.zig");
const module = @import("module.zig");

pub fn main(init: std.process.Init) !void {
    const r = try module.build(init.arena.allocator(), init.io, .{ .source = .{ .module_root = "test/data/package" } });
    for (r.errors) |e| {
        // TODO : log the errors.
        // var allocator = std.heap.stackFallback(1024, init.gpa);
        // try std.fmt.allocPrint(allocator.get(), "", .{});
        std.log.err("{s}: {s}", .{ @tagName(e.details), e.path });
    }
}

// pub fn main(init: std.process.Init) !void {
//     const allocator = std.heap.page_allocator;
//
//     var it = try init.minimal.args.iterateAllocator(allocator);
//     _ = it.skip();
//
//     const fileName = it.next() orelse {
//         std.debug.print("no filename entered\n", .{});
//         return;
//     };
//
//     const quiet = if (it.next()) |x| std.mem.eql(u8, x, "-q") else false;
//
//     const data = try std.Io.Dir.cwd().readFileAlloc(init.io, fileName, allocator, std.Io.Limit.unlimited);
//
//     const now = std.Io.Timestamp.now(init.io, std.Io.Clock.awake);
//     const parseResult = try parser.parse(allocator, data, .{ .transient_allocator = std.heap.smp_allocator });
//     const diff = std.Io.Timestamp.untilNow(now, init.io, std.Io.Clock.awake);
//     if (quiet) {
//         std.debug.print("\ntook {}ms\n", .{diff.toMilliseconds()});
//         return;
//     }
//     const marshaler = astcoder.Options{};
//
//     var buffer: [2048]u8 = undefined;
//     var stdOutFile = std.Io.File.stdout();
//     var stdOutWriter = stdOutFile.writer(init.io, &buffer);
//
//     try marshaler.writeDocument(&stdOutWriter.interface, parseResult.document);
//     try stdOutWriter.interface.flush();
//     for (parseResult.errors) |err| {
//         std.debug.print("\nLiteral: {?s}, Message: {s}, Location: {?any}\n", .{
//             err.literal,
//             err.message,
//             err.location,
//         });
//     }
//     std.debug.print("\ntook {}ms\n", .{diff.toMilliseconds()});
// }
