const code = @import("code.zig");
const dyn = @import("dynamic_value.zig");
const Selector = @import("Selector.zig");
const Range = code.Range;

/// AssignmentNode describes an option setting, since options can be blocks or a single assignment
/// the value can either be a leaf or a tree.
pub const AssignmentNode = struct {
    /// indicates that the assignment is marked as private or internally valuable.
    private: bool,

    /// raw indicates that the assignment is a loose and raw key.
    raw: bool,

    /// selector is the key used for the assignment. For instance in a.b = 1, "a.b" is the selector.
    selector: Selector,

    /// value is the assigned value, which can be a group if a nested block is used or a single ranged value.
    value: Value,

    /// range captures the entire range of the option.
    range: Range,

    pub const Value = union(enum) {
        Leaf: dyn.RangedValue,
        Group: []const AssignmentNode,
    };
};
