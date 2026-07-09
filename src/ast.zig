const std = @import("std");
const Allocator = std.mem.Allocator;

pub const KeyPath = @import("ast/KeyPath.zig");
pub const Range = @import("ast/Range.zig");

pub const Identifier = struct {
    value: []const u8,
    range: Range,
};

/// LiteralValue describes a value expressed directly in source code.
/// This includes primitive types, collections, objects and references
/// to language objects via @ref().
pub const LiteralValue = union(enum) {
    /// A UTF-8 string literal.
    string: []const u8,
    boolean: bool,
    number: i64,
    float: f64,
    /// Represents the absence of a value.
    none,
    /// An ordered sequence of ranged literals.
    array: []const RangedLiteral,
    /// A map of key-value pairs. Keys are either strings or @ref() expressions.
    object: []const Pair,
    /// Reference to a language object via @ref().
    ref: KeyPath,
};

/// RangedLiteral pairs a LiteralValue with its source code range,
/// used to preserve location information for diagnostics and tooling.
pub const RangedLiteral = struct { literal: LiteralValue, range: Range };

/// Entry represents a single key-value pair in an Object literal.
pub const Pair = struct {
    /// Key is the key of an Entry, either a plain string or a @ref() expression.
    pub const Key = union(enum) {
        /// A plain string key.
        string: []const u8,
        /// A reference to a language object used as a key.
        ref: KeyPath,
    };

    key: Key,
    value: RangedLiteral,
};

/// AssignmentNode describes an annotation setting, since annotations can be blocks or single assignments
/// the value can either be a leaf or a tree.
pub const AnnotationNode = struct {
    const Flags = packed struct {
        /// extra indicates whether or not the annotation is marked as extra.
        extra: bool = false,
        /// private means the annotation is marked as private.
        private: bool = false,
        // bare means the import uses the bare import syntax.
        bare: bool = false,
    };

    pub const Value = union(enum) {
        leaf: RangedLiteral,
        group: []const AnnotationNode,
    };

    flags: Flags,

    /// profiles can only be set when the private flag is set.
    profiles: []const Identifier,

    /// selector is the key used for the assignment. For instance in a.b = 1, "a.b" is the selector.
    key_path: KeyPath,

    /// value is the assigned value, which can be a group if a nested block is used or a single ranged value.
    value: Value,

    /// range captures the entire range of the option.
    range: Range,
};

/// Most of the annotations use either the headless and modifierless group form or inline values.
/// This struct is a wrapper just to indicate whether or not a block is used.
pub const AnnotationGroup = struct {
    values: []const AnnotationNode,
    block: bool,

    pub const empty: AnnotationGroup = .{ .values = &.{}, .block = false };
};

pub const Documentation = struct {
    content: []const u8,
};

/// Import describes a single import statement.
pub const Import = struct {
    /// indicates whether or not the import statement is marked as bare (via # token).
    bare: bool,
    /// if non-empty, it is the alias used to access the contents of the package.
    alias: []const u8,
    /// path to the package.
    path: []const u8,
    /// range of the import statement in the source file.
    range: Range,
};

/// Constant describes a named fixed value.
pub const Constant = struct {
    /// name of the constant.
    name: Identifier,
    /// annotations assigned to the constant.
    annotations: AnnotationGroup,
    /// value is the ranged value of the constant.
    value: RangedLiteral,
    /// range is the boundary of the statement in the source code.
    range: Range,
    /// captured documentation for the constant.
    documentation: ?Documentation,
};

/// EnumVariant is a possible enum value.
pub const EnumVariant = struct {
    /// name of the enum variant.
    name: Identifier,
    /// optional explicit value assignment.
    value: ?u32,
    /// options assigned to the constant.
    annotations: AnnotationGroup,
    /// range is the boundary of the statement in the source code.
    range: Range,
    /// captured documentation for the variant.
    documentation: ?Documentation,
};

/// Enum describes an enum definition along with all the defined variants.
pub const Enum = struct {
    /// name of the constant.
    name: Identifier,
    /// options assigned to the constant.
    annotations: []const AnnotationNode,
    /// variants of the enum.
    variants: []const EnumVariant,
    /// range is the boundary of the statement in the source code.
    range: Range,
    /// captured documentation for the enum.
    documentation: ?Documentation,
};

// old

/// Field holds all the information for a field inside a model.
pub const Field = struct {
    /// name of the field as it appears in the input file.
    name: Identifier,
    /// field data type.
    data_type: RangedDataType,
    /// optional explicit field tag assignment. This is a numerical identifier for this field.
    tag: ?u16,
    /// whether or not field can be null.
    nullable: bool,
    /// annotations assigned to the field.
    annotations: AnnotationGroup,
    /// range is the boundary of the statement in the source code.
    range: Range,
    /// captured documentation for the field.
    documentation: ?Documentation,
    /// the index of the one of group it belongs to, if any.
    oneof_group_index: ?u16,

    pub const DataType = union(enum) {
        string: KeyPath,
        list: KeyPath,
        map: MapTypeInfo,
        oneof: OneOfTypeInfo,
    };
    pub const OneOfTypeInfo = struct {
        fields: []const Field,
        annotations: []const AnnotationNode,
    };
    pub const MapTypeInfo = struct {
        key: KeyPath,
        value: KeyPath,
    };
    pub const RangedDataType = struct {
        value: DataType,
        range: Range,
    };
};

/// OneOf describes a oneof group reference.
pub const OneOf = struct {
    /// name of the oneof group.
    name: Identifier,
    /// options assigned to the constant.
    annotations: []const AnnotationNode,
    /// range is the boundary of the statement in the source code.
    range: Range,
};

/// Struct describes a data model.
pub const Struct = struct {
    /// Describes either a field or an embed declaration.
    pub const Member = union(enum) {
        embed: KeyPath,
        field: Field,
    };

    /// name of the constant.
    name: Identifier,
    /// members of the struct which can be either fields or embedded structs.
    members: []const Member,
    /// annotations assigned to the struct.
    annotations: []const AnnotationNode,
    /// range is the boundary of the statement in the source code.
    range: Range,
    oneof_groups: []const OneOf,
    /// captured documentation for the struct.
    documentation: ?Documentation,
};

pub const AnnotationTarget = enum {
    Package,
    Enum,
    EnumVariant,
    Field,
    Protocol,
    Func,
    Struct,
    OneOf,
    Constant,
};

pub const AnnotationTargetSet = std.enums.EnumSet(AnnotationTarget);

pub const AnnotationDefinition = struct {
    targets: AnnotationTargetSet,
    fields: []const Field,
    range: Range,
};

pub const FuncArg = struct {
    name: KeyPath,
    streaming: bool,
};

pub const Func = struct {
    name: Identifier,
    input: ?FuncArg,
    output: ?FuncArg,
    tag: ?u16,
    annotations: AnnotationGroup,
    /// range is the boundary of the statement in the source code.
    range: Range,
    /// captured documentation for the func.
    documentation: ?Documentation,
};

pub const Protocol = struct {
    name: Identifier,
    funcs: []const Func,
    annotations: []const AnnotationNode,
    /// range is the boundary of the statement in the source code.
    range: Range,
    /// captured documentation for the func.
    documentation: ?Documentation,
};

/// Document describes a single pragma source file.
pub const Document = struct {
    /// all of the imported packages in the document.
    imports: []const Import,

    /// annotations for the current package.
    annotations: []const AnnotationNode,

    /// constants are fixed value literals.
    constants: []const Constant,

    /// enums are types that can assume a limited set of values.
    enums: []const Enum,

    /// structs that are defined in the document.
    structs: []const Struct,

    /// option definitions declared in the document.
    annotation_definitions: []const AnnotationDefinition,
    protocols: []const Protocol,

    /// captured documentation for the pragma package (should not conflict).
    documentation: ?Documentation,

    pub const empty: Document = .{
        .imports = &.{},
        .annotations = &.{},
        .constants = &.{},
        .enums = &.{},
        .structs = &.{},
        .annotation_definitions = &.{},
        .protocols = &.{},
        .documentation = null,
    };
};
