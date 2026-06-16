///! Inclusive byte offset range of a node in the source text.
start: usize,
end: usize,

pub const zero: @This() = .{ .start = 0, .end = 0 };
