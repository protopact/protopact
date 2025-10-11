//! Selector is a dot-separated path that can be iterated over.

const std = @import("std");
const code = @import("code.zig");

const Allocator = std.mem.Allocator;
const Range = code.Range;
const Position = code.Position;
const Self = @This();

content: []const u8,
markers: []const SegmentMarker,
range: Range,

/// SelectorSegmentInfo describes a single segment in a selector.
const SegmentMarker = struct {
    /// index is the byte position of the segment in the content.
    index: usize,
    /// position is the position of the segment in the source file.
    position: Position,
};

pub const Segment = struct {
    content: []const u8,
    position: *const Position,
};

pub const Iterator = struct {
    content: []const u8,
    markers: []const SegmentMarker,
    start: *const Position,
    i: usize,

    fn init(content: []const u8, markers: []const SegmentMarker, start: *const Position) Iterator {
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
                    .position = self.start,
                };
            }
            return null;
        }

        defer self.i += 1;
        if (self.i + 1 >= self.markers.len) {
            // last segment!
            return Segment{
                .content = self.content[self.markers[self.i].index..],
                .position = &(self.markers[self.i].position),
            };
        } else {
            // pull the next segment.
            const nextMarker = self.markers[self.i + 1];
            return Segment{
                .content = self.content[self.markers[self.i].index .. nextMarker.index - 1],
                .position = &(self.markers[self.i].position),
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

    pub fn appendSegment(self: *Builder, segment: []const u8, position: Position) BuilderError!void {
        const noRoomForContent = self.content.items.len + segment.len > self.content.capacity;
        const noRoomForMarker = self.markers.items.len >= self.markers.capacity;
        if (noRoomForContent or noRoomForMarker) {
            return BuilderError.OutOfRoom;
        }

        self.markers.appendAssumeCapacity(.{
            .index = self.content.items.len,
            .position = position,
        });
        self.content.appendSliceAssumeCapacity(segment);
    }

    pub fn appendSeparator(self: *Builder) BuilderError!void {
        if (self.content.items.len >= self.content.capacity) {
            return BuilderError.OutOfRoom;
        }

        self.content.appendAssumeCapacity('.');
    }

    /// build creates a selector with the original allocator.
    pub fn build(self: Builder, range: Range) Self {
        return .{
            .content = self.content.items,
            .markers = self.markers.items,
            .range = range,
        };
    }
};

pub fn init(segment: []const u8, range: Range) Self {
    return .{
        .content = segment,
        .range = range,
        .markers = &[_]SegmentMarker{},
    };
}

pub fn builder(allocator: Allocator, contentSize: usize, segmentCount: usize) Allocator.Error!Builder {
    return try Builder.init(allocator, contentSize, segmentCount);
}

pub fn iterator(self: *const Self) Iterator {
    return Iterator.init(self.content, self.markers, &self.range.start);
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

test "selector single segment" {
    const selector = init("single", Range.empty());
    var it = selector.iterator();

    try expectIterator(&it, &[_][]const u8{"single"});
}

test "selector multi segment" {
    const t = std.testing;

    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();

    var b = try builder(arena.allocator(), comptime "name.x.y".len, 3);

    try b.appendSegment("name", .empty());
    try b.appendSeparator();
    try b.appendSegment("x", .empty());
    try b.appendSeparator();
    try b.appendSegment("y", .empty());

    const selector = b.build(.{ .start = .empty(), .endOffset = 0 });
    var it = selector.iterator();

    try expectIterator(&it, &[_][]const u8{ "name", "x", "y" });
}

test "selector multi segment edge" {
    const t = std.testing;

    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();

    var b = try builder(arena.allocator(), comptime "name.x.y".len, 3);

    try b.appendSegment("name", .empty());
    try b.appendSeparator();
    try b.appendSegment("x", .empty());

    { // don't use all the items
        const selector = b.build(.{ .start = .empty(), .endOffset = 0 });
        var it = selector.iterator();

        try expectIterator(&it, &[_][]const u8{ "name", "x" });
    }

    // too many
    try b.appendSeparator();
    try t.expectError(BuilderError.OutOfRoom, b.appendSegment("yy", .empty()));
    try b.appendSegment("y", .empty());
    // too many with separator
    try t.expectError(BuilderError.OutOfRoom, b.appendSeparator());

    { // should still be able to use the builder
        const selector = b.build(.{ .start = .empty(), .endOffset = 0 });
        var it = selector.iterator();

        try expectIterator(&it, &[_][]const u8{ "name", "x", "y" });
    }
}
