//! Selector is a dot-separated path that can be iterated over.

const std = @import("std");

const Allocator = std.mem.Allocator;
const Range = @import("Range.zig");
const Self = @This();

content: []const u8,
markers: []const SegmentMarker,
range: Range,

/// SelectorSegmentInfo describes a single segment in a keypath.
const SegmentMarker = struct {
    /// Byte position of the segment in the content.
    index: usize,
    /// Inclusive byte offset of the segment in the source file.
    start: usize,
};

pub const Segment = struct {
    content: []const u8,
    range: Range,
};

pub const Iterator = struct {
    content: []const u8,
    markers: []const SegmentMarker,
    start: usize,
    i: usize,

    fn init(content: []const u8, markers: []const SegmentMarker, start: usize) Iterator {
        return .{
            .content = content,
            .start = start,
            .markers = markers,
            .i = 0,
        };
    }

    pub fn next(self: *Iterator) ?Segment {
        if (self.i >= self.markers.len) {
            if (self.i == 0 and self.content.len > 0) {
                self.i += 1;
                return Segment{
                    .content = self.content,
                    .range = .{ .start = self.start, .end = self.content.len },
                };
            }
            return null;
        }

        defer self.i += 1;
        if (self.i + 1 >= self.markers.len) {
            // last segment!
            const content = self.content[self.markers[self.i].index..];
            const start = self.markers[self.i].start;
            return Segment{
                .content = content,
                .range = .{ .start = start, .end = start + content.len },
            };
        } else {
            // pull the next segment.
            const next_marker = self.markers[self.i + 1];
            const content = self.content[self.markers[self.i].index .. next_marker.index - 1];
            const start = self.markers[self.i].start;
            return Segment{
                .content = content,
                .range = .{ .start = start, .end = start + content.len },
            };
        }
    }
};

pub const BuilderError = error{OutOfRoom};

const Builder = struct {
    content: std.ArrayList(u8),
    markers: std.ArrayList(SegmentMarker),

    fn init(allocator: Allocator, contentSize: usize, segmentCount: usize) Allocator.Error!Builder {
        return .{
            .content = try std.ArrayList(u8).initCapacity(allocator, contentSize),
            .markers = try std.ArrayList(SegmentMarker).initCapacity(allocator, segmentCount),
        };
    }

    pub fn appendSegment(self: *Builder, segment: []const u8, start: usize) BuilderError!void {
        const noRoomForContent = self.content.items.len + segment.len > self.content.capacity;
        const noRoomForMarker = self.markers.items.len >= self.markers.capacity;
        if (noRoomForContent or noRoomForMarker) {
            return BuilderError.OutOfRoom;
        }

        self.markers.appendAssumeCapacity(.{
            .index = self.content.items.len,
            .start = start,
        });
        self.content.appendSliceAssumeCapacity(segment);
    }

    pub fn appendSeparator(self: *Builder) BuilderError!void {
        if (self.content.items.len >= self.content.capacity) {
            return BuilderError.OutOfRoom;
        }

        self.content.appendAssumeCapacity('.');
    }

    /// build creates a keypath with the original allocator.
    pub fn build(self: Builder, range: Range) Self {
        return .{
            .content = self.content.items,
            .markers = self.markers.items,
            .range = range,
        };
    }
};

/// Create a single segment keypath.
pub fn init(segment: []const u8, range: Range) Self {
    return .{
        .content = segment,
        .range = range,
        .markers = &.{},
    };
}

pub fn builder(allocator: Allocator, contentSize: usize, segmentCount: usize) Allocator.Error!Builder {
    return try Builder.init(allocator, contentSize, segmentCount);
}

pub fn iterator(self: *const Self) Iterator {
    return Iterator.init(self.content, self.markers, self.range.start);
}

fn expectIterator(it: *Iterator, items: []const []const u8) !void {
    const t = std.testing;

    for (items) |value| {
        const next = it.next();
        try t.expect(next != null);
        try t.expectEqualStrings(next.?.content, value);
    }

    const next = it.next();
    try t.expectEqual(null, next);
}

test "keypath single segment" {
    const keypath = init("single", Range.zero);
    var it = keypath.iterator();

    try expectIterator(&it, &[_][]const u8{"single"});
}

test "keypath multi segment" {
    const t = std.testing;

    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();

    var b = try builder(arena.allocator(), comptime "name.x.y".len, 3);

    try b.appendSegment("name", 0);
    try b.appendSeparator();
    try b.appendSegment("x", 0);
    try b.appendSeparator();
    try b.appendSegment("y", 0);

    const keypath = b.build(.zero);
    var it = keypath.iterator();

    try expectIterator(&it, &.{ "name", "x", "y" });
}

test "keypath multi segment edge" {
    const t = std.testing;

    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();

    var b = try builder(arena.allocator(), comptime "name.x.y".len, 3);

    try b.appendSegment("name", 0);
    try b.appendSeparator();
    try b.appendSegment("x", 0);

    { // don't use all the items
        const keypath = b.build(.zero);
        var it = keypath.iterator();

        try expectIterator(&it, &.{ "name", "x" });
    }

    // too many
    try b.appendSeparator();
    try t.expectError(BuilderError.OutOfRoom, b.appendSegment("yy", 0));
    try b.appendSegment("y", 0);
    // too many with separator
    try t.expectError(BuilderError.OutOfRoom, b.appendSeparator());

    { // should still be able to use the builder
        const keypath = b.build(.zero);
        var it = keypath.iterator();

        try expectIterator(&it, &.{ "name", "x", "y" });
    }
}
