const code = @import("code.zig");

/// Value describes a dynamic value that can be a string, nothing, numbers, arrays or a map.
pub const Value = union(enum) {
    String: []const u8,
    Bool: bool,
    Number: i64,
    Float: f64,
    None,
    Array: []const RangedValue,
    Object: []const Entry,
};

/// RangedValue is similar to Value but has source code range.
pub const RangedValue = code.Ranged(Value);

/// Entry describes a map and the keys can only be strings.
pub const Entry = struct {
    key: []const u8,
    value: RangedValue,
    /// indicates whether or not the key is a field selector or a raw string.
    selector: bool,
};
