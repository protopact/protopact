/// Position is the position of a token in the original source file.
pub const Position = struct {
    /// line is the line number starting from 1.
    line: u16,
    /// column is 1-indexed position of the character in the line.
    column: u16,
    /// offset is the number of bytes from the beginning of the file (0-indexed).
    offset: usize,

    pub fn empty() Position {
        return .{
            .line = 0,
            .column = 0,
            .offset = 0,
        };
    }
};

/// Range describes a range in the original source code.
pub const Range = struct {
    /// start is the starting position of the token / AST object.
    start: Position,
    /// is the byte offset of the end position.
    endOffset: usize,

    pub fn empty() Range {
        return .{ .start = Position.empty(), .endOffset = 0 };
    }
};

/// Ranged returns a wrapper type that includes a range and a value.
pub fn Ranged(T: type) type {
    return struct {
        value: T,
        range: Range,
    };
}
