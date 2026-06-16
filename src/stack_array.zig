const std = @import("std");

/// Very similar to BoundedArray in older versions of Zig standard library.
/// It uses a stack array/buffer to store a pre-determined number of items.
pub fn StackArray(T: type, comptime count: usize) type {
    return struct {
        buffer: [count]T,
        len: usize = 0,

        const Self = @This();

        pub fn append(self: *Self, item: T) error{OutOfMemory}!void {
            if (self.len >= count) return error.OutOfMemory;
            self.buffer[self.len] = item;
            self.len += 1;
        }

        pub fn appendAssumeCapacity(self: *Self, item: T) void {
            self.buffer[self.len] = item;
            self.len += 1;
        }

        pub inline fn slice(self: *const Self) []const T {
            return self.buffer[0..self.len];
        }

        pub fn clear(self: *Self) void {
            self.len = 0;
        }

        pub inline fn getLastAssumeSafe(self: *const Self) T {
            return self.buffer[self.len - 1];
        }

        pub inline fn capacity(self: *const Self) usize {
            _ = self;
            return count;
        }

        pub fn pop(self: *Self) ?T {
            if (self.len == 0) return null;
            self.len -= 1;
            return self.buffer[self.len];
        }

        pub fn init() Self {
            return .{ .buffer = undefined, .len = 0 };
        }
    };
}

/// Creates an array with a stack buffer and then proceeds to use a dynamic allocation if it runs out of memory in the
/// stack buffer.
pub fn StackFallbackArray(T: type, comptime count: usize) type {
    return struct {
        stack_buffer: [count]T,
        stack_len: usize,
        heap_array: std.ArrayList(T),
        allocator: std.mem.Allocator,

        const Self = @This();
        const heapArrayInitialCapacity = 50;

        pub fn init(ally: std.mem.Allocator) Self {
            return .{
                .stack_buffer = undefined,
                .stack_len = 0,
                .allocator = ally,
                .heap_array = std.ArrayList(T).initCapacity(ally, 0) catch unreachable,
            };
        }

        pub fn append(self: *Self, item: T) std.mem.Allocator.Error!void {
            // If there is room in the stack buffer, fill it up first.
            if (self.stack_len < count) {
                self.stack_buffer[self.stack_len] = item;
                self.stack_len += 1;
                return;
            }

            // If arraylist has non-zero items, initialize it with 50 items to avoid growing again.
            if (self.heap_array.items.len == 0)
                try self.heap_array.ensureTotalCapacity(self.allocator, heapArrayInitialCapacity);

            try self.heap_array.append(self.allocator, item);
        }

        pub fn len(self: Self) usize {
            return self.stack_len + self.heap_array.items.len;
        }

        /// allocates memory with the newAllocator and drains both the stack and any dynamically allocated items
        /// into the new memory.
        /// NOTE: The heap allocated buffer gets freed if this function returns without an error.
        pub fn toOwnedSlice(self: *Self, new_allocator: std.mem.Allocator) std.mem.Allocator.Error![]T {
            const new_buffer = try new_allocator.alloc(T, self.stack_len + self.heap_array.items.len);
            @memcpy(new_buffer[0..self.stack_len], self.stack_buffer[0..self.stack_len]);
            if (self.heap_array.items.len > 0) {
                @memcpy(new_buffer[self.stack_len..], self.heap_array.items);
                self.heap_array.deinit(self.allocator);
            }
            return new_buffer;
        }

        pub const Iterator = struct {
            array: *const Self,
            i: usize = 0,

            pub fn next(self: *Iterator) ?T {
                if (self.i >= count) {
                    // heap array mode.
                    const position = self.i - count;
                    if (position >= self.array.heap_array.items.len)
                        return null;
                    defer self.i += 1;
                    return self.array.heap_array.items[position];
                } else {
                    // stack array mode.
                    if (self.i >= self.array.stack_len)
                        return null;
                    defer self.i += 1;
                    return self.array.stack_buffer[self.i];
                }
            }
        };

        pub fn iterator(self: *const Self) Iterator {
            return .{ .array = self };
        }

        pub inline fn getFirstAssumeSafe(self: Self) T {
            return self.stack_buffer[0];
        }

        pub fn clear(self: *Self) void {
            self.stack_len = 0;
            self.heap_array.clearRetainingCapacity();
        }

        pub fn deinit(self: *Self) void {
            self.stack_len = 0;
            self.heap_array.clearAndFree(self.allocator);
        }
    };
}

test "Stack Array" {
    const t = std.testing;

    var list = StackArray(i32, 3).init();

    try t.expectEqual(0, list.len);
    try t.expectEqualSlices(i32, &.{}, list.slice());

    try list.append(1);
    try list.append(2);
    try list.append(3);
    try t.expectError(error.OutOfMemory, list.append(4));

    try t.expectEqualSlices(i32, &.{ 1, 2, 3 }, list.slice());

    try t.expectEqual(3, list.pop());
    try t.expectEqual(2, list.pop());
    try t.expectEqual(1, list.pop());
    try t.expectEqual(null, list.pop());
}

test "Stack Fallback Array" {
    const t = std.testing;

    { // Stack buffer
        var list = StackFallbackArray(i32, 3).init(t.failing_allocator);
        try list.append(1);
        try list.append(2);
        const slice = try list.toOwnedSlice(t.allocator);
        try t.expectEqualSlices(i32, &.{ 1, 2 }, slice);
        t.allocator.free(slice);
    }

    { // Heap allocation
        var list = StackFallbackArray(usize, 3).init(t.allocator);
        for (0..5) |i| try list.append(i + 1);
        const slice = try list.toOwnedSlice(t.allocator);
        try t.expectEqualSlices(usize, &.{ 1, 2, 3, 4, 5 }, slice);
        t.allocator.free(slice);
    }

    { // Iterator
        var list = StackFallbackArray(usize, 5).init(t.allocator);
        defer list.deinit();
        for (0..3) |i| try list.append(i + 1); // fill up with stack, test the iterator.
        var it = list.iterator();
        try t.expectEqual(it.next(), 1);
        try t.expectEqual(it.next(), 2);
        try t.expectEqual(it.next(), 3);
        try t.expectEqual(it.next(), null);

        it = list.iterator();
        for (3..6) |i| try list.append(i + 1); // now fill up the heap.
        try t.expectEqual(it.next(), 1);
        try t.expectEqual(it.next(), 2);
        try t.expectEqual(it.next(), 3);
        try t.expectEqual(it.next(), 4);
        try t.expectEqual(it.next(), 5);
        try t.expectEqual(it.next(), 6);
        try t.expectEqual(it.next(), null);
    }
}
