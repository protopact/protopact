const std = @import("std");

pub const Encoding = enum { Utf8, Utf16 };

pub const Position = struct {
    line: u32,
    column: u16,

    pub const zero: Position = .{ .line = 0, .column = 0 };
};

const Self = @This();

lines: std.ArrayList(usize) = .empty,
source: []const u8 = &.{},

pub const empty: Self = .{};

pub fn initSource(allocator: std.mem.Allocator, source: []const u8) std.mem.Allocator.Error!Self {
    var new: Self = .{.source = source };
    errdefer new.lines.clearAndFree(allocator);
    try new.update(allocator, source);
    return new;
}

pub fn update(
    self: *Self,
    allocator: std.mem.Allocator,
    source: []const u8,
) error{ InvalidText, OutOfMemory }!void {
    self.lines.clearRetainingCapacity();
    try self.lines.append(allocator, 0);
    self.source = source;

    var position: usize = 0;
    while (position < source.len) {
        const count = std.unicode.utf8ByteSequenceLength(source[position]) catch return error.InvalidText;
        const new_position = position + count;
        if (source[position] == '\n') {
            try self.lines.append(allocator, new_position);
        }
        position = new_position;
    }
}

fn utf16Length(line: []const u8) u16 {
    var count: u16 = 0;
    var i: usize = 0;
    while (i < line.len) {
        const n = std.unicode.utf8ByteSequenceLength(line[i]) catch unreachable;
        count += switch (n) {
            1...3 => 1,
            4 => 2,
            else => unreachable,
        };
        i += n;
    }
    return count;
}

fn utf16LengthToOffset(text: []const u8, offset: usize, count: u16) usize {
    _ = text;
    _ = offset;
    _ = count;
    return 0;
}

pub fn resolveOffset(self: *const Self, offset: usize) error{OutOfRange}!Position {
    if (offset > self.source.len)
        return error.OutOfRange;

    const S = struct {
        fn compare(context: usize, item: usize) std.math.Order {
            return std.math.order(context, item);
        }
    };
    const line_index = std.sort.upperBound(usize, self.lines.items, offset, S.compare) - 1;
    const line = self.source[self.lines.items[line_index]..offset];
    return Position{ .line = @intCast(line_index), .column = @intCast(line.len) };
}

pub fn resolveOffsetEncoding(self: *const Self, encoding: Encoding, offset: usize) error{OutOfRange}!Position {
    if (offset > self.source.len)
        return error.OutOfRange;

    const S = struct {
        fn compare(context: usize, item: usize) std.math.Order {
            return std.math.order(context, item);
        }
    };
    const line_index = std.sort.upperBound(usize, self.lines.items, offset, S.compare) - 1;
    const line = self.source[self.lines.items[line_index]..offset];
    const column: u16 = switch (encoding) {
        .Utf8 => @intCast(line.len),
        .Utf16 => utf16Length(line),
    };
    return Position{ .line = @intCast(line_index), .column = column };
}

pub fn resolvePosition(self: *const Self, encoding: Encoding, position: Position) error{OutOfRange}!usize {
    if (self.lines.items.len < position.line)
        return error.OutOfRange;

    const offset = switch (encoding) {
        .Utf8 => self.lines.items[position.line] + position.column,
        .Utf16 => self.lines.items[position.line] + utf16LengthToOffset(
            self.source,
            self.lines.items[position.line],
            position.column,
        ),
    };
    return if (offset < self.source.len) offset else error.OutOfRange;
}

pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
    self.lines.deinit(allocator);
}

test "LineMap.resolve()" {
    const t = std.testing;

    const text =
        \\pragma some.cool.company
        \\struct Request {}
        \\protocol UserService {}
    ;

    var builder: Self = .{};
    defer builder.deinit(t.allocator);

    try builder.update(t.allocator, text);
    try t.expectEqual(Position{ .line = 0, .column = 10 }, try builder.resolveOffsetEncoding(.Utf8, 10));
    // Boundary
    try t.expectEqual(Position{ .line = 0, .column = 24 }, try builder.resolveOffsetEncoding(.Utf8, 24));
    try t.expectEqual(Position{ .line = 1, .column = 0 }, try builder.resolveOffsetEncoding(.Utf8, 25));
    try t.expectEqual(Position{ .line = 1, .column = 1 }, try builder.resolveOffsetEncoding(.Utf8, 26));
    // Last Line
    try t.expectEqual(Position{ .line = 2, .column = 0 }, try builder.resolveOffsetEncoding(.Utf8, 43));
    try t.expectEqual(Position{ .line = 2, .column = 1 }, try builder.resolveOffsetEncoding(.Utf8, 44));
    try t.expectError(error.OutOfRange, builder.resolveOffsetEncoding(.Utf8, 70));
}
