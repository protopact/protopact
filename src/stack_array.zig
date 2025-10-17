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

        pub fn slice(self: Self) []const T {
            return self.buffer[0..self.len];
        }

        pub fn clear(self: *Self) void {
            self.len = 0;
        }

        pub fn capacity(self: Self) usize {
            return self.buffer.len;
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
        stackBuffer: [count]T,
        stackLen: usize,
        heapArray: std.ArrayList(T),
        allocator: std.mem.Allocator,

        const Self = @This();
        const heapArrayInitialCapacity = 50;

        pub fn init(ally: std.mem.Allocator) Self {
            return .{
                .stackBuffer = undefined,
                .stackLen = 0,
                .allocator = ally,
                .heapArray = std.ArrayList(T).initCapacity(ally, 0) catch unreachable,
            };
        }

        pub fn append(self: *Self, item: T) std.mem.Allocator.Error!void {
            // If there is room in the stack buffer, fill it up first.
            if (self.stackLen < count) {
                self.stackBuffer[self.stackLen] = item;
                self.stackLen += 1;
                return;
            }

            // If arraylist has non-zero items, initialize it with 50 items to avoid growing again.
            if (self.heapArray.items.len == 0)
                try self.heapArray.ensureTotalCapacity(self.allocator, heapArrayInitialCapacity);

            try self.heapArray.append(self.allocator, item);
        }

        /// allocates memory with the newAllocator and drains both the stack and any dynamically allocated items
        /// into the new memory.
        /// NOTE: The heap allocated buffer gets freed if this function returns without an error.
        pub fn toOwnedSlice(self: *Self, newAllocator: std.mem.Allocator) std.mem.Allocator.Error![]T {
            const newBuffer = try newAllocator.alloc(T, self.stackLen + self.heapArray.items.len);
            @memcpy(newBuffer[0..self.stackLen], self.stackBuffer[0..self.stackLen]);
            if (self.heapArray.items.len > 0) {
                @memcpy(newBuffer[self.stackLen..], self.heapArray.items);
                self.heapArray.deinit(self.allocator);
            }
            return newBuffer;
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
}
