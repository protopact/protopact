const std = @import("std");
const Allocator = std.mem.Allocator;

const code = @import("ast/code.zig");

pub const Selector = @import("ast/Selector.zig");
pub const Range = code.Range;
pub const Position = code.Position;

const dyn = @import("ast/dynamic_value.zig");
pub const Value = dyn.Value;
pub const RangedValue = dyn.RangedValue;
pub const Entry = dyn.Entry;

const opts = @import("ast/options.zig");
pub const OptionAssignmentNode = opts.AssignmentNode;

pub const Identifier = code.Ranged([]const u8);

pub const Documentation = struct {
    content: []const u8,
};

/// Import describes a single import statement.
pub const Import = struct {
    /// indicates whether or not the import statement is implicitly importing the package.
    ///
    /// In an implicit import, there is no need to use a prefix to import objects.
    implicit: bool,
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
    name: []const u8,
    /// options assigned to the constant.
    options: []OptionAssignmentNode,
    /// value is the ranged value of the constant.
    value: RangedValue,
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
    options: []const OptionAssignmentNode,
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
    options: []const OptionAssignmentNode,
    /// variants of the enum.
    variants: []const EnumVariant,
    /// range is the boundary of the statement in the source code.
    range: Range,
    /// captured documentation for the enum.
    documentation: ?Documentation,
};

/// Field holds all the information for a field inside a model.
pub const Field = struct {
    name: Identifier,
    dataType: RangedDataType,
    tag: ?u32,
    /// options assigned to the field.
    options: []const OptionAssignmentNode,
    /// range is the boundary of the statement in the source code.
    range: Range,
    /// captured documentation for the field.
    documentation: ?Documentation,
    // TODO: this shouldn't be variable based on the system, should be either u16 or u32.
    oneOfGroupIndex: ?usize,

    pub const DataType = union(enum) {
        String: Selector,
        List: Selector,
        Map: MapTypeInfo,
        OneOf: OneOfTypeInfo,
    };
    pub const OneOfTypeInfo = struct {
        fields: []const Field,
        options: []const OptionAssignmentNode,
    };
    pub const MapTypeInfo = struct {
        key: Selector,
        value: Selector,
    };
    pub const RangedDataType = code.Ranged(DataType);
};

/// OneOf describes a oneof group reference.
pub const OneOf = struct {
    /// name of the oneof group.
    name: Identifier,
    /// options assigned to the constant.
    options: []const OptionAssignmentNode,
    /// range is the boundary of the statement in the source code.
    range: Range,
};

/// Message describes a model.
pub const Message = struct {
    /// name of the constant.
    name: Identifier,
    /// messages that are directly embedded into the message.
    embeddedMessages: []const Selector,
    /// options assigned to the message.
    options: []const OptionAssignmentNode,
    /// all of the model fields.
    fields: []const Field,
    /// range is the boundary of the statement in the source code.
    range: Range,
    oneOfGroups: []const OneOf,
    /// captured documentation for the message.
    documentation: ?Documentation,
};

pub const OptionTarget = enum(u16) {
    Pact,
    Enum,
    EnumVariant,
    Field,
    Interface,
    Func,
    Message,
    OneOf,
    Constant,
};

pub const OptionTargetSet = std.enums.EnumSet(OptionTarget);

pub const OptionDefinition = struct {
    targets: OptionTargetSet,
    fields: []const Field,
    range: Range,
};

pub const FuncArg = struct {
    name: Selector,
    streaming: bool,
};

pub const Func = struct {
    name: Identifier,
    input: ?FuncArg,
    output: ?FuncArg,
    tag: ?u32,
    options: []const OptionAssignmentNode,
    /// range is the boundary of the statement in the source code.
    range: Range,
    /// captured documentation for the func.
    documentation: ?Documentation,
};

pub const Interface = struct {
    name: Identifier,
    funcs: []const Func,
    options: []const OptionAssignmentNode,
    /// range is the boundary of the statement in the source code.
    range: Range,
    /// captured documentation for the func.
    documentation: ?Documentation,
};

/// Document describes a single pactum source file.
pub const Document = struct {
    /// the pact package designation.
    pact: ?Selector,

    /// all of the imported packages in the document.
    imports: []const Import,

    /// options are all of the document option assignments.
    options: []const OptionAssignmentNode,

    /// constants are fixed value literals.
    constants: []const Constant,

    /// enums are types that can assume a limited set of values.
    enums: []const Enum,

    /// messages are the models defined in the file.
    messages: []const Message,

    /// option definitions declared in the document.
    optionDefinitions: []const OptionDefinition,

    /// interfaces denote a service or a collection of functions.
    interfaces: []const Interface,

    /// captured documentation for the pact.
    documentation: ?Documentation,

    pub fn empty() Document {
        return .{
            .pact = null,
            .imports = &[_]Import{},
            .options = &[_]OptionAssignmentNode{},
            .constants = &[_]Constant{},
            .enums = &[_]Enum{},
            .messages = &[_]Message{},
            .optionDefinitions = &[_]OptionDefinition{},
            .interfaces = &[_]Interface{},
            .documentation = null,
        };
    }
};
