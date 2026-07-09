const std = @import("std");

const ast = @import("ast.zig");
const LineMap = @import("LineMap.zig");

pub const Options = struct {
    line_map: ?LineMap = null,

    expand_key_path: bool = false,
    exclude_zero_values: bool = false,
    include_range: bool = false,
    include_import: bool = false,
    include_annotations: bool = false,
    include_constants: bool = false,
    include_enums: bool = false,
    include_structs: bool = false,
    include_annotation_definitions: bool = false,
    include_protocols: bool = false,
    include_documentation: bool = false,
};

const YamlState = struct {
    flag: u64 = 0,

    const Self = @This();

    const DepthMask: u64 = 0xff;
    const InArrayMask: u64 = 0b1;
    const IsNotFirstMask: u64 = 0b10;
    const IsInlineMask: u64 = 0b100;

    pub const Mode = enum {
        Array, InlineArray, Object
    };

    inline fn currentDepth(self: *const Self) u8 {
        return @truncate(self.flag & DepthMask);
    }

    inline fn inArray(self: *const Self) bool {
        const bit_count: u6 = @intCast(8 + (self.currentDepth() * 3));
        return (self.flag >> bit_count) & InArrayMask != 0;
    }

    inline fn isFirst(self: *const Self) bool {
        const bit_count: u6 = @intCast(8 + (self.currentDepth() * 3));
        return (self.flag >> bit_count) & IsNotFirstMask == 0;
    }

    inline fn isInline(self: *const Self) bool {
        const bit_count: u6 = @intCast(8 + (self.currentDepth() * 3));
        return (self.flag >> bit_count) & IsInlineMask != 0;
    }

    inline fn setFirst(self: *Self, comptime value: bool) void {
        const bit_count: u6 = @intCast(8 + (self.currentDepth() * 3));
        if (value) {
            self.flag &= ~(IsNotFirstMask << bit_count);
        } else {
            self.flag |= (IsNotFirstMask << bit_count);
        }
    }

    inline fn setDepth(self: *Self, depth: u8) void {
        self.flag = (self.flag & (~DepthMask)) | depth;
    }

    inline fn incDepth(self: *Self, comptime mode: Mode) void {
        const current_depth = self.currentDepth() + 1;
        self.setDepth(current_depth);
        const bit_count: u6 = @intCast(8 + (current_depth * 3));
        const zero_mask: u64 = ~(@as(u64, 0b111) << bit_count);
        self.flag &= zero_mask;
        switch (mode) {
            .Array => self.flag |= InArrayMask << bit_count,
            .InlineArray => self.flag |= (InArrayMask & IsInlineMask) << bit_count,
            .Object => self.setFirst(false),
        }
    }

    inline fn decDepth(self: *Self) void {
        self.setDepth(self.currentDepth() - 1);
    }
};

const Context = struct {
    const LiteralNone = "null";

    writer: *std.Io.Writer,
    opts: Options,
    state: YamlState,

    fn writeKey(self: *Context, key: []const u8) !void {
        if (self.state.isFirst()) {
            self.state.setFirst(false);
        } else {
            try self.writePrefixForDepth();
        }
        try self.writer.print("{s}:", .{key});
    }

    fn writeValue(self: *Context, comptime pattern: []const u8, args: anytype) !void {
        if (self.state.inArray()) {
            if (self.state.isInline()) {
                if (self.state.isFirst()) {
                    self.state.setFirst(false);
                } else try self.writer.print(", " ++ pattern, args);
            } else {
                try self.writePrefixForDepth();
                try self.writer.print("- " ++ pattern, args);
            }
        } else {
            try self.writer.print(" " ++ pattern, args);
        }
    }

    fn writeQuotedValue(self: *Context, comptime pattern: []const u8, args: anytype) !void {
        try self.writeValue("\"" ++ pattern ++ "\"", args);
    }

    fn writePrefixForDepth(self: *Context) !void {
        try self.writer.writeByte('\n');
        _ = try self.writer.writeSplat(&.{" "}, self.state.currentDepth()*2);
    }

    fn startArray(self: *Context) !void {
        const in_array = self.state.inArray();
        self.state.incDepth(.Array);
        if (in_array) {
            _ = try self.writer.write(":");
        }
    }

    fn startInlineArray(self: *Context) !void {
        self.state.incDepth(.InlineArray);
        try self.writeValue("[", .{});
    }

    fn endInlineArray(self: *Context) !void {
        self.state.decDepth();
        try self.writeValue("[", .{});
    }

    fn endArray(self: *Context) void {
        self.state.decDepth();
    }

    fn startObject(self: *Context) !void {
        const starts_in_array = self.state.inArray();
        if (starts_in_array) try self.writePrefixForDepth();
        self.state.incDepth(.Object);
        if (starts_in_array) {
            _ = try self.writer.write("- ");
            self.state.setFirst(true);
        }
    }

    fn endObject(self: *Context) void {
        self.state.decDepth();
    }

    fn writeRange(self: *Context, range: ast.Range) !void {
        if (self.opts.line_map) |map| {
            const start: LineMap.Position = map.resolveOffset(range.start) catch .zero;
            const end: LineMap.Position = map.resolveOffset(range.end) catch .zero;
            if (end.line != start.line) {
                try self.writeQuotedValue("{d}:{d}-{d}:{d}[{d}-{d}]", .{
                    start.line + 1,
                    start.column + 1,
                    end.line + 1,
                    end.column + 1,
                    range.start,
                    range.end,
                });
            } else {
                try self.writeQuotedValue("{d}:{d}-{d}[{d}-{d}]", .{
                    start.line + 1,
                    start.column + 1,
                    end.column + 1,
                    range.start,
                    range.end,
                });
            }
        } else try self.writeQuotedValue("{d}-{d}", .{range.start, range.end});
    }

    fn writePosition(self: *Context, offset: usize) !void {
        if (self.opts.line_map) |map| {
            const position: LineMap.Position = map.resolveOffset(offset) catch {
                return try self.writeValue("<invalid offset:{}>", .{offset});
            };
            try self.writeQuotedValue("{d}:{d}", .{
                position.line + 1,
                position.column + 1,
            });
        } else try self.writeQuotedValue("{d}", .{offset});
    }

    fn writeAnnotationGroup(self: *Context, group: *const ast.AnnotationGroup) std.Io.Writer.Error!void {
        if (!self.opts.include_annotations or (self.opts.exclude_zero_values and group.values.len == 0)) {
            return;
        }

        if (group.block) {
            try self.startObject();
            defer self.endObject();

            try self.writeKey("block");
            try self.writeAnnotations(group.values, false);
        } else {
            try self.writeAnnotations(group.values, false);
        }
    }

    fn writeAnnotations(
        self: *Context,
        annotations: []const ast.AnnotationNode,
        include_key: bool,
    ) std.Io.Writer.Error!void {
        if (!self.opts.include_annotations or (self.opts.exclude_zero_values and annotations.len == 0)) {
            return;
        }

        if (include_key) {
            try self.writeKey("annotations");
        }
        try self.startArray();
        defer self.endArray();
        for (annotations) |annotation| {
            try self.startObject();
            defer self.endObject();

            if (!self.opts.exclude_zero_values or annotation.flags.extra) {
                try self.writeKey("extra");
                try self.writeValue("{any}", .{annotation.flags.extra});
            }

            if (!self.opts.exclude_zero_values or annotation.flags.private) {
                try self.writeKey("private");
                try self.writeValue("{any}", .{annotation.flags.private});
            }

            if (!self.opts.exclude_zero_values or annotation.flags.bare) {
                try self.writeKey("bare");
                try self.writeValue("{any}", .{annotation.flags.bare});
            }

            if (!self.opts.exclude_zero_values or annotation.flags.headless) {
                try self.writeKey("headless");
                try self.writeValue("{any}", .{annotation.flags.headless});
            }

            if (self.opts.include_range) {
                try self.writeKey("range");
                try self.writeRange(annotation.range);
            }
            if (!annotation.flags.headless) {
                try self.writeKey("key_path");
                try self.writeKeyPath(annotation.key_path);
            }
            try self.writeAnnotationValue(&annotation.value);
        }
    }

    fn writeRangedLiteral(self: *Context, value: *const ast.RangedLiteral) !void {
        if (self.opts.include_range) {
            try self.startObject();
            try self.writeKey("range");
            try self.writeRange(value.range);
            try self.writeKey("data");
        }
        defer if (self.opts.include_range) self.endObject();

        switch (value.literal) {
            .boolean => try self.writeValue("{any}", .{value.literal.boolean}),
            .string => try self.writeQuotedValue("{s}", .{value.literal.string}),
            .number => try self.writeValue("{d}", .{value.literal.number}),
            .float => try self.writeValue("{d}", .{value.literal.float}),
            .none => try self.writeValue("{s}", .{LiteralNone}),
            .array => {
                try self.startArray();
                defer self.endArray();

                for (value.literal.array) |*item| {
                    try self.writeRangedLiteral(item);
                }
            },
            .object => {
                try self.startArray();
                defer self.endArray();

                for (value.literal.object) |item| {
                    try self.startObject();
                    defer self.endObject();

                    try self.writeKey("key");
                    try self.writeQuotedValue("{s}", .{item.key.string});
                    try self.writeKey("value");
                    try self.writeRangedLiteral(&item.value);
                }
            },
            .ref => {},
        }
    }

    fn writeAnnotationValue(
        self: *Context,
        value: *const ast.AnnotationNode.Value,
    ) !void {
        switch (value.*) {
            .leaf => {
                try self.writeKey("value");
                try self.writeRangedLiteral(&value.leaf);
            },
            .group => {
                try self.writeKey("block");
                try self.writeAnnotations(value.group, false);
            },
        }
    }

    fn writeImports(self: *Context, imports: []const ast.Import) !void {
        if (!self.opts.include_import or (self.opts.exclude_zero_values and imports.len == 0)) {
            return;
        }

        try self.writeKey("imports");
        try self.startArray();
        defer self.endArray();

        for (imports) |import| {
            try self.startObject();
            defer self.endObject();

            if (!self.opts.exclude_zero_values or import.alias.len > 0) {
                try self.writeKey("alias");
                try self.writeQuotedValue("{s}", .{import.alias});
            }

            if (!self.opts.exclude_zero_values or import.bare) {
                try self.writeKey("bare");
                try self.writeValue("{any}", .{import.bare});
            }
            try self.writeKey("path");
            try self.writeQuotedValue("{s}", .{import.path});
            if (self.opts.include_range) {
                try self.writeKey("range");
                try self.writeRange(import.range);
            }
        }
    }

    fn writeKeyPath(self: *Context, key_path: ast.KeyPath) !void {
        if (!self.opts.include_range and !self.opts.expand_key_path) {
            try self.writeQuotedValue("{s}", .{key_path.content});
            return;
        }

        try self.startObject();
        defer self.endObject();

        try self.writeKey("content");
        try self.writeQuotedValue("{s}", .{key_path.content});
        if (self.opts.include_range) {
            try self.writeKey("range");
            try self.writeRange(key_path.range);
        }
        if (self.opts.expand_key_path) {
            try self.writeKey("segments");
            try self.startArray();
            defer self.endArray();

            var it = key_path.iterator();
            while (it.next()) |segment| {
                try self.writeKey("content");
                try self.writeQuotedValue("{s}", .{segment.content});
                if (self.opts.include_range) {
                    try self.startObject();
                    defer self.endObject();
                    try self.writeKey("position");
                    try self.writePosition(segment.range.start);
                }
            }
        }
    }

    fn writeConstants(self: *Context, constants: []const ast.Constant) !void {
        if (!self.opts.include_constants or (self.opts.exclude_zero_values and constants.len == 0)) {
            return;
        }

        try self.writeKey("constants");
        try self.startArray();
        defer self.endArray();
        for (constants) |constant| {
            try self.startObject();
            defer self.endObject();

            try self.writeKey("name");
            try self.writeQuotedValue("{s}", .{constant.name.value});

            try self.writeDocumentation(constant.documentation);

            if (self.opts.include_range) {
                try self.writeKey("range");
                try self.writeRange(constant.range);
            }

            try self.writeKey("value");
            try self.writeRangedLiteral(&constant.value);

            if (self.opts.include_annotations and (constant.annotations.values.len > 0 or !self.opts.exclude_zero_values)) {
                try self.writeKey("annotations");
                try self.writeAnnotationGroup(&constant.annotations);
            }
        }
    }

    fn writeEnumVariant(self: *Context, variant: ast.EnumVariant) !void {
        try self.startObject();
        defer self.endObject();

        try self.writeKey("name");
        try self.writeQuotedValue("{s}", .{variant.name.value});

        try self.writeDocumentation(variant.documentation);

        if (self.opts.include_range) {
            try self.writeKey("range");
            try self.writeRange(variant.range);
        }

        if (variant.value) |value| {
            try self.writeKey("value");
            try self.writeValue("{d}", .{value});
        } else if (!self.opts.exclude_zero_values) {
            try self.writeKey("value");
            try self.writeValue(LiteralNone, .{});
        }

        if (self.opts.include_annotations and (variant.annotations.values.len > 0 or !self.opts.exclude_zero_values)) {
            try self.writeKey("annotations");
            try self.writeAnnotationGroup(&variant.annotations);
        }
    }

    fn writeEnums(self: *Context, enums: []const ast.Enum) !void {
        if (!self.opts.include_enums or (self.opts.exclude_zero_values and enums.len == 0)) {
            return;
        }

        try self.writeKey("enums");
        try self.startArray();
        defer self.endArray();

        for (enums) |enum_type| {
            try self.startObject();
            defer self.endObject();

            try self.writeKey("name");
            try self.writeQuotedValue("{s}", .{enum_type.name.value});

            try self.writeDocumentation(enum_type.documentation);

            if (self.opts.include_range) {
                try self.writeKey("range");
                try self.writeRange(enum_type.range);
            }

            if (self.opts.include_annotations and (enum_type.annotations.len > 0 or !self.opts.exclude_zero_values)) {
                try self.writeKey("annotations");
                try self.writeAnnotations(enum_type.annotations, false);
            }

            if (enum_type.variants.len > 0 or !self.opts.exclude_zero_values) {
                try self.writeKey("variants");
                try self.startArray();
                defer self.endArray();

                for (enum_type.variants) |variant| {
                    try self.writeEnumVariant(variant);
                }
            }
        }
    }

    fn writeDataType(self: *Context, data_type: ast.Field.RangedDataType) !void {
        try self.writeKey("type");

        switch (data_type.value) {
            .string => |key_path| {
                try self.writeQuotedValue("{s}", .{key_path.content});
            },
            .list => |key_path| {
                try self.writeQuotedValue("list[item={s}]", .{key_path.content});
            },
            .map => |map_info| {
                try self.writeQuotedValue("map[key={s}, value={s}]", .{ map_info.key.content, map_info.value.content });
            },
            .oneof => |oneof_info| {
                try self.writeValue("{s}", .{"oneof"});

                if (oneof_info.annotations.len > 0 or !self.opts.exclude_zero_values) {
                    try self.writeKey("oneof_options");
                    try self.writeAnnotations(oneof_info.annotations, false);
                }

                if (oneof_info.fields.len > 0 or !self.opts.exclude_zero_values) {
                    try self.writeKey("oneof_fields");
                    try self.startArray();
                    defer self.endArray();
                    for (oneof_info.fields) |field| {
                        try self.writeField(field);
                    }
                }
            },
        }

        if (self.opts.include_range) {
            try self.writeKey("type_range");
            try self.writeRange(data_type.range);
        }
    }

    fn writeField(self: *Context, field: ast.Field) std.Io.Writer.Error!void {
        try self.startObject();
        defer self.endObject();

        try self.writeKey("name");
        try self.writeQuotedValue("{s}", .{field.name.value});

        try self.writeDocumentation(field.documentation);

        if (self.opts.include_range) {
            try self.writeKey("range");
            try self.writeRange(field.range);
        }

        try self.writeDataType(field.data_type);

        if (field.tag) |tag| {
            try self.writeKey("tag");
            try self.writeValue("{d}", .{tag});
        } else if (!self.opts.exclude_zero_values) {
            try self.writeKey("tag");
            try self.writeValue("{s}", .{LiteralNone});
        }

        if (!self.opts.exclude_zero_values or field.nullable) {
            try self.writeKey("nullable");
            try self.writeValue("{any}", .{field.nullable});
        }

        if (field.oneof_group_index) |index| {
            try self.writeKey("oneof_group_index");
            try self.writeValue("{d}", .{index});
        }

        if (self.opts.include_annotations and (field.annotations.values.len > 0 or !self.opts.exclude_zero_values)) {
            try self.writeKey("annotations");
            try self.writeAnnotationGroup(&field.annotations);
        }
    }

    fn writeOneOf(self: *Context, oneof: ast.OneOf) !void {
        try self.startObject();
        defer self.endObject();

        try self.writeKey("name");
        try self.writeQuotedValue("{s}", .{oneof.name.value});

        if (self.opts.include_range) {
            try self.writeKey("range");
            try self.writeRange(oneof.range);
        }

        if (self.opts.include_annotations and (oneof.annotations.len > 0 or !self.opts.exclude_zero_values)) {
            try self.writeKey("annotations");
            try self.writeAnnotations(oneof.annotations, false);
        }
    }

    fn writeStruct(self: *Context, info: ast.Struct) !void {
        try self.startObject();
        defer self.endObject();

        try self.writeKey("name");
        try self.writeQuotedValue("{s}", .{info.name.value});

        if (self.opts.include_documentation and (!self.opts.exclude_zero_values or info.documentation != null)) {
            try self.writeDocumentation(info.documentation);
        }

        if (self.opts.include_range) {
            try self.writeKey("range");
            try self.writeRange(info.range);
        }

        if (self.opts.include_annotations and (info.annotations.len > 0 or !self.opts.exclude_zero_values)) {
            try self.writeKey("annotations");
            try self.writeAnnotations(info.annotations, false);
        }

        if (info.oneof_groups.len > 0 or !self.opts.exclude_zero_values) {
            try self.writeKey("oneof_groups");
            try self.startArray();
            defer self.endArray();
            for (info.oneof_groups) |oneof| {
                try self.writeOneOf(oneof);
            }
        }

        if (info.members.len > 0 or !self.opts.exclude_zero_values) {
            try self.writeKey("members");
            try self.startArray();
            defer self.endArray();
            for (info.members) |member| {
                switch (member) {
                    .field => |field| try self.writeField(field),
                    .embed => |embed| {
                        try self.startObject();
                        defer self.endObject();
                        try self.writeKey("embed");
                        try self.writeKeyPath(embed);
                    },
                }
            }
        }
    }

    fn writeStructs(self: *Context, structs: []const ast.Struct) !void {
        if (!self.opts.include_structs or (self.opts.exclude_zero_values and structs.len == 0)) {
            return;
        }

        try self.writeKey("structs");
        try self.startArray();
        defer self.endArray();
        for (structs) |struct_info| {
            try self.writeStruct(struct_info);
        }
    }

    fn writeAnnotationTargets(self: *Context, targets: ast.AnnotationTargetSet) !void {
        try self.writeKey("targets");
        try self.startArray();
        defer self.endArray();

        var it = targets.iterator();
        while (it.next()) |target| {
            try self.writeValue("{s}", .{@tagName(target)});
        }
    }

    fn writeFuncArg(self: *Context, arg: ast.FuncArg) !void {
        try self.startObject();
        defer self.endObject();

        try self.writeKey("name");
        try self.writeKeyPath(arg.name);
        try self.writeKey("streaming");
        try self.writeValue("{any}", .{arg.streaming});
    }

    fn writeFunc(self: *Context, func: ast.Func) !void {
        try self.startObject();
        defer self.endObject();

        try self.writeKey("name");
        try self.writeQuotedValue("{s}", .{func.name.value});

        try self.writeDocumentation(func.documentation);

        if (self.opts.include_range) {
            try self.writeKey("range");
            try self.writeRange(func.range);
        }

        if (func.tag) |tag| {
            try self.writeKey("tag");
            try self.writeValue("{d}", .{tag});
        } else if (!self.opts.exclude_zero_values) {
            try self.writeKey("tag");
            try self.writeValue("{s}", .{LiteralNone});
        }

        // Write input argument
        if (func.input) |input| {
            try self.writeKey("input");
            try self.writeFuncArg(input);
        } else if (!self.opts.exclude_zero_values) {
            try self.writeKey("input");
            try self.writeValue("{s}", .{LiteralNone});
        }

        // Write output argument
        if (func.output) |output| {
            try self.writeKey("output");
            try self.writeFuncArg(output);
        } else if (!self.opts.exclude_zero_values) {
            try self.writeKey("output");
            try self.writeValue("{s}", .{LiteralNone});
        }

        if (self.opts.include_annotations and (func.annotations.values.len > 0 or !self.opts.exclude_zero_values)) {
            try self.writeKey("annotations");
            try self.writeAnnotationGroup(&func.annotations);
        }
    }

    fn writeAnnotationDefinition(self: *Context, def: ast.AnnotationDefinition) !void {
        try self.startObject();
        defer self.endObject();

        try self.writeAnnotationTargets(def.targets);

        if (self.opts.include_range) {
            try self.writeKey("range");
            try self.writeRange(def.range);
        }

        if (def.fields.len > 0 or !self.opts.exclude_zero_values) {
            try self.writeKey("fields");
            try self.startArray();
            defer self.endArray();

            for (def.fields) |field| {
                try self.writeField(field);
            }
        }
    }

    fn writeAnnotationDefinitions(self: *Context, defs: []const ast.AnnotationDefinition) !void {
        if (!self.opts.include_annotation_definitions or (self.opts.exclude_zero_values and defs.len == 0)) {
            return;
        }

        try self.writeKey("annotation_definitions");
        try self.startArray();
        defer self.endArray();

        for (defs) |def| {
            try self.writeAnnotationDefinition(def);
        }
    }

    fn writeProtocol(self: *Context, protocol: ast.Protocol) !void {
        try self.startObject();
        defer self.endObject();

        try self.writeKey("name");
        try self.writeQuotedValue("{s}", .{protocol.name.value});

        try self.writeDocumentation(protocol.documentation);

        if (self.opts.include_range) {
            try self.writeKey("range");
            try self.writeRange(protocol.range);
        }

        if (self.opts.include_annotations and (protocol.annotations.len > 0 or !self.opts.exclude_zero_values)) {
            try self.writeKey("annotations");
            try self.writeAnnotations(protocol.annotations, false);
        }

        if (protocol.funcs.len > 0 or !self.opts.exclude_zero_values) {
            try self.writeKey("funcs");

            try self.startArray();
            defer self.endArray();

            for (protocol.funcs) |func| {
                try self.writeFunc(func);
            }
        }
    }

    fn writeDocumentation(self: *Context, documentation: ?ast.Documentation) !void {
        if (!self.opts.include_documentation) {
            return;
        }

        if (documentation) |doc| {
            try self.writeKey("documentation");
            try self.writeValue("|", .{});

            var cursor: usize = 0;
            while (cursor < doc.content.len) {
                const end = std.mem.indexOfScalarPos(u8, doc.content, cursor, '\n') orelse break;
                try self.writer.writeByte('\n');
                _ = try self.writer.writeSplat(&.{" "}, (self.state.currentDepth() + 1) * 2);
                try self.writer.writeAll(doc.content[cursor .. end]);
                cursor = end + 1;
            }
        }
    }

    fn writeProtocols(self: *Context, protocols: []const ast.Protocol) !void {
        if (!self.opts.include_protocols or (self.opts.exclude_zero_values and protocols.len == 0)) {
            return;
        }

        try self.writeKey("protocols");
        try self.startArray();
        defer self.endArray();

        for (protocols) |protocol| {
            try self.writeProtocol(protocol);
        }
    }
};


pub const YamlMarshaller = struct {
    pub fn writeDocument(writer: *std.Io.Writer, doc: ast.Document, opts: Options) !void {
        var ctx = Context{
            .opts = opts,
            .writer = writer,
            .state = .{ .flag = 0 },
        };

        try ctx.writeDocumentation(doc.documentation);
        try ctx.writeImports(doc.imports);
        try ctx.writeAnnotations(doc.annotations, true);
        try ctx.writeConstants(doc.constants);
        try ctx.writeEnums(doc.enums);
        try ctx.writeStructs(doc.structs);
        try ctx.writeAnnotationDefinitions(doc.annotation_definitions);
        try ctx.writeProtocols(doc.protocols);
    }
};

test "yaml" {
    const t = std.testing;

    var writer = std.Io.Writer.Allocating.init(t.allocator);
    defer writer.deinit();
    var ctx: Context = .{ .state = .{ .flag = 0 }, .writer = &writer.writer, .opts = .{} };
    try ctx.writeKey("key");
    try ctx.writeValue("value", .{});
    try ctx.writeKey("another");
    try ctx.writeQuotedValue("ok, another", .{});
    try ctx.writeKey("object");
    try ctx.startObject();
    try ctx.writeKey("values");
    try ctx.startArray();
    try ctx.writeValue("1", .{});
    try ctx.writeValue("2", .{});
    try ctx.startArray();
    try ctx.writeValue("3", .{});
    try ctx.writeValue("4", .{});
    try ctx.startObject();
    try ctx.writeKey("key");
    try ctx.writeValue("value", .{});
    try ctx.writeKey("key2");
    try ctx.writeValue("value2", .{});
    ctx.endObject();
    ctx.endArray();
    ctx.endArray();
    ctx.endObject();

    const expected_output =
        \\key: value
        \\another: "ok, another"
        \\object:
        \\  values:
        \\    - 1
        \\    - 2:
        \\      - 3
        \\      - 4
        \\      - key: value
        \\        key2: value2
        ;
    try t.expectEqualStrings(expected_output, writer.written());
}
