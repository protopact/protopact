const ast = @import("ast.zig");
const std = @import("std");

const NewlineFilterWriter = struct {
    interface: std.Io.Writer,
    writer: *std.Io.Writer,
    lastLineWasNewLine: bool,

    const Self = @This();

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) error{WriteFailed}!usize {
        const self: *NewlineFilterWriter = @fieldParentPtr("interface", w);

        for (data[0 .. data.len - 1]) |slice| try self.process(slice);

        const pattern = data[data.len - 1];
        for (0..splat) |_| try self.process(pattern);

        return std.Io.Writer.countSplat(data, splat);
    }

    fn process(self: *NewlineFilterWriter, data: []const u8) error{WriteFailed}!void {
        for (data) |ch| {
            if (ch == '\n' and self.lastLineWasNewLine)
                continue;
            try self.writer.writeByte(ch);
            self.lastLineWasNewLine = ch == '\n';
        }
    }

    fn init(writer: *std.Io.Writer) Self {
        return .{
            .interface = .{
                .buffer = &.{},
                .vtable = &.{
                    .drain = drain,
                },
            },
            .writer = writer,
            .lastLineWasNewLine = false,
        };
    }
};

const Context = struct {
    const LiteralNone = "null";
    const Self = @This();

    writer: *std.Io.Writer,
    indentation: usize = 0,
    inArray: bool = false,

    // Config fields moved from YamlMarshaller
    expandSelectors: bool,
    includeRange: bool,
    excludeZeroValues: bool,
    includePact: bool,
    includeImport: bool,
    includeOptionAssignments: bool,
    includeConstants: bool,
    includeEnums: bool,
    includeMessages: bool,
    includeOptionDefinitions: bool,
    includeInterfaces: bool,
    includeDocumentation: bool,

    inline fn incrIndent(self: *Self) void {
        self.indentation += 2;
    }

    inline fn decrIndent(self: *Self) void {
        self.indentation -= 2;
    }

    fn writeArrayPrefix(self: *Self) !void {
        try self.writeNewLine();
        _ = try self.writer.writeSplat(&.{" "}, self.indentation);
        try self.writer.writeAll("- ");
        self.inArray = true;
    }

    fn writeNewLine(self: *Self) !void {
        try self.writer.writeByte('\n');
    }

    fn writeKey(self: *Self, key: []const u8) !void {
        if (self.inArray) {
            self.inArray = false;
        } else {
            try self.writeNewLine();
            _ = try self.writer.writeSplat(&.{" "}, self.indentation);
        }
        try self.writer.print("{s}:", .{key});
    }

    fn writePact(self: *Self, selector: ?ast.Selector) !void {
        if (!self.includePact or (self.excludeZeroValues and selector == null)) {
            return;
        }

        try self.writer.writeAll("pact:");
        if (selector) |value| {
            try self.writeSelector(value);
        } else {
            try self.writer.writeAll(LiteralNone);
        }
        try self.writeNewLine();
    }

    fn writeRange(self: *Self, range: ast.Range) !void {
        try self.writer.print(" \"{d}:{d}[{d}-{d}]\"", .{
            range.start.line,
            range.start.column,
            range.start.offset,
            range.endOffset,
        });
    }

    fn writePosition(self: *Self, position: *const ast.Position) !void {
        try self.writer.print(" \"{d}:{d}\"", .{
            position.line,
            position.column,
        });
    }

    fn writeOptions(
        self: *Self,
        options: []const ast.OptionAssignmentNode,
        includeKey: bool,
    ) std.Io.Writer.Error!void {
        if (!self.includeOptionAssignments or (self.excludeZeroValues and options.len == 0)) {
            return;
        }

        if (includeKey) {
            try self.writer.writeAll("options:");
        }
        self.incrIndent();
        defer self.decrIndent();
        for (options) |option| {
            try self.writeKey("- raw");
            try self.writer.print(" {any}", .{option.raw});
            self.incrIndent();
            defer self.decrIndent();
            try self.writeKey("private");
            try self.writer.print(" {any}", .{option.private});
            if (self.includeRange) {
                try self.writeKey("range");
                try self.writeRange(option.range);
            }
            try self.writeKey("selector");
            try self.writeSelector(option.selector);
            try self.writeOptionValue(&option.value);
        }
        try self.writeNewLine();
    }

    fn writeValue(self: *Self, value: *const ast.RangedValue) !void {
        if (self.includeRange) {
            self.incrIndent();
            defer self.decrIndent();
            try self.writeKey("range");
            try self.writeRange(value.*.range);
            try self.writeKey("data");
        }

        if (!self.inArray) {
            switch (value.*.value) {
                .Bool, .String, .Number, .Float, .None => try self.writer.writeAll(" "),
                else => {},
            }
        }

        switch (value.*.value) {
            .Bool => try self.writer.print("{any}", .{value.*.value.Bool}),
            .String => try self.writer.print("\"{s}\"", .{value.*.value.String}),
            .Number => try self.writer.print("{d}", .{value.*.value.Number}),
            .Float => try self.writer.print("{d}", .{value.*.value.Float}),
            .None => try self.writer.writeAll(LiteralNone),
            .Array => {
                self.incrIndent();
                defer self.decrIndent();
                for (value.*.value.Array) |item| {
                    if (self.includeRange) self.incrIndent();
                    defer if (self.includeRange) self.decrIndent();
                    try self.writeNewLine();
                    _ = try self.writer.writeSplat(&.{" "}, self.indentation);
                    try self.writer.writeAll("- ");
                    self.inArray = true;
                    try self.writeValue(&item);
                    self.inArray = false;
                }
            },
            .Object => {
                if (self.includeRange) self.incrIndent();
                defer if (self.includeRange) self.decrIndent();
                for (value.*.value.Object) |item| {
                    self.incrIndent();
                    defer self.decrIndent();
                    try self.writeKey("key");
                    try self.writer.print(" \"{s}\"", .{item.key});
                    try self.writeKey("value");
                    try self.writeValue(&item.value);
                    self.inArray = false;
                }
            },
        }
    }

    fn writeOptionValue(
        self: *Self,
        value: *const ast.OptionAssignmentNode.Value,
    ) !void {
        switch (value.*) {
            .Leaf => {
                try self.writeKey("value");
                try self.writeValue(&value.*.Leaf);
            },
            .Group => {
                try self.writeKey("block");
                try self.writeOptions(value.*.Group, false);
            },
        }
    }

    fn writeImports(self: *Self, imports: []const ast.Import) !void {
        if (!self.includeImport or (self.excludeZeroValues and imports.len == 0)) {
            return;
        }

        try self.writer.writeAll("imports:");
        self.incrIndent();
        defer self.decrIndent();
        for (imports) |import| {
            try self.writeKey("- alias");
            try self.writer.print(" \"{s}\"", .{import.alias});
            self.incrIndent();
            defer self.decrIndent();
            try self.writeKey("implicit");
            try self.writer.print(" {any}", .{import.implicit});
            try self.writeKey("path");
            try self.writer.print(" \"{s}\"", .{import.path});
            if (self.includeRange) {
                try self.writeKey("range");
                try self.writeRange(import.range);
            }
        }
        try self.writeNewLine();
    }

    fn writeSelector(self: *Self, selector: ast.Selector) !void {
        if (!self.includeRange and !self.expandSelectors) {
            try self.writer.print(" \"{s}\"", .{selector.content});
            return;
        }

        self.incrIndent();
        defer self.decrIndent();
        try self.writeKey("content");
        try self.writer.print(" \"{s}\"", .{selector.content});
        if (self.includeRange) {
            try self.writeKey("range");
            try self.writeRange(selector.range);
        }
        if (self.expandSelectors) {
            try self.writeKey("segments");
            self.incrIndent();
            defer self.decrIndent();
            var it = selector.iterator();
            while (it.next()) |segment| {
                try self.writeKey("- content");
                try self.writer.print(" \"{s}\"", .{segment.content});
                if (self.includeRange) {
                    self.incrIndent();
                    defer self.decrIndent();
                    try self.writeKey("position");
                    try self.writePosition(segment.position);
                }
            }
        }
    }

    fn writeConstants(self: *Self, constants: []const ast.Constant) !void {
        if (!self.includeConstants or (self.excludeZeroValues and constants.len == 0)) {
            return;
        }

        try self.writer.writeAll("constants:");
        self.incrIndent();
        defer self.decrIndent();
        for (constants) |constant| {
            try self.writeArrayPrefix();
            try self.writeKey("name");
            try self.writer.print(" \"{s}\"", .{constant.name});
            self.incrIndent();
            defer self.decrIndent();

            try self.writeDocumentation(constant.documentation);

            if (self.includeRange) {
                try self.writeKey("range");
                try self.writeRange(constant.range);
            }

            try self.writeKey("value");
            try self.writeValue(&constant.value);

            if (constant.options.len > 0 or !self.excludeZeroValues) {
                try self.writeKey("options");
                try self.writeOptions(constant.options, false);
            }
        }
        try self.writeNewLine();
    }

    fn writeEnumVariant(self: *Self, variant: ast.EnumVariant) !void {
        try self.writeKey("- name");
        try self.writer.print(" \"{s}\"", .{variant.name.value});
        self.incrIndent();
        defer self.decrIndent();

        try self.writeDocumentation(variant.documentation);

        if (self.includeRange) {
            try self.writeKey("range");
            try self.writeRange(variant.range);
        }

        if (variant.value) |value| {
            try self.writeKey("value");
            try self.writer.print(" {d}", .{value});
        } else if (!self.excludeZeroValues) {
            try self.writeKey("value");
            try self.writer.writeAll(" ");
            try self.writer.writeAll(LiteralNone);
        }

        if (variant.options.len > 0 or !self.excludeZeroValues) {
            try self.writeKey("options");
            try self.writeOptions(variant.options, false);
        }
    }

    fn writeEnums(self: *Self, enums: []const ast.Enum) !void {
        if (!self.includeEnums or (self.excludeZeroValues and enums.len == 0)) {
            return;
        }

        try self.writer.writeAll("enums:");
        self.incrIndent();
        defer self.decrIndent();
        for (enums) |enumType| {
            try self.writeKey("- name");
            try self.writer.print(" \"{s}\"", .{enumType.name.value});
            self.incrIndent();
            defer self.decrIndent();

            try self.writeDocumentation(enumType.documentation);

            if (self.includeRange) {
                try self.writeKey("range");
                try self.writeRange(enumType.range);
            }

            if (enumType.options.len > 0 or !self.excludeZeroValues) {
                try self.writeKey("options");
                try self.writeOptions(enumType.options, false);
            }

            if (enumType.variants.len > 0 or !self.excludeZeroValues) {
                try self.writeKey("variants");
                self.incrIndent();
                defer self.decrIndent();
                for (enumType.variants) |variant| {
                    try self.writeEnumVariant(variant);
                }
            }
        }
        try self.writeNewLine();
    }

    fn writeDataType(self: *Self, dataType: ast.Field.RangedDataType) !void {
        try self.writeKey("type");

        switch (dataType.value) {
            .String => |selector| {
                try self.writer.print(" \"{s}\"", .{selector.content});
            },
            .List => |selector| {
                try self.writer.print(" \"list[item={s}]\"", .{selector.content});
            },
            .Map => |mapInfo| {
                try self.writer.print(" \"map[key={s}, value={s}]\"", .{ mapInfo.key.content, mapInfo.value.content });
            },
            .OneOf => |oneOfInfo| {
                try self.writer.writeAll(" \"oneof\"");

                if (oneOfInfo.options.len > 0 or !self.excludeZeroValues) {
                    try self.writeKey("oneof_options");
                    try self.writeOptions(oneOfInfo.options, false);
                }

                if (oneOfInfo.fields.len > 0 or !self.excludeZeroValues) {
                    try self.writeKey("oneof_fields");
                    self.incrIndent();
                    defer self.decrIndent();
                    for (oneOfInfo.fields) |field| {
                        try self.writeField(field);
                    }
                }
            },
        }

        if (self.includeRange) {
            try self.writeKey("type_range");
            try self.writeRange(dataType.range);
        }
    }

    fn writeField(self: *Self, field: ast.Field) std.Io.Writer.Error!void {
        try self.writeKey("- name");
        try self.writer.print(" \"{s}\"", .{field.name.value});
        self.incrIndent();
        defer self.decrIndent();

        try self.writeDocumentation(field.documentation);

        if (self.includeRange) {
            try self.writeKey("range");
            try self.writeRange(field.range);
        }

        try self.writeDataType(field.dataType);

        if (field.tag) |tag| {
            try self.writeKey("tag");
            try self.writer.print(" {d}", .{tag});
        } else if (!self.excludeZeroValues) {
            try self.writeKey("tag");
            try self.writer.writeAll(" ");
            try self.writer.writeAll(LiteralNone);
        }

        try self.writeKey("nullable");
        try self.writer.print(" {any}", .{field.nullable});

        if (field.oneOfGroupIndex) |index| {
            try self.writeKey("oneof_group_index");
            try self.writer.print(" {d}", .{index});
        }

        if (field.options.len > 0 or !self.excludeZeroValues) {
            try self.writeKey("options");
            try self.writeOptions(field.options, false);
        }
    }

    fn writeOneOf(self: *Self, oneOf: ast.OneOf) !void {
        try self.writeKey("- name");
        try self.writer.print(" \"{s}\"", .{oneOf.name.value});
        self.incrIndent();
        defer self.decrIndent();

        if (self.includeRange) {
            try self.writeKey("range");
            try self.writeRange(oneOf.range);
        }

        if (oneOf.options.len > 0 or !self.excludeZeroValues) {
            try self.writeKey("options");
            try self.writeOptions(oneOf.options, false);
        }
    }

    fn writeMessage(self: *Self, message: ast.Message) !void {
        try self.writeKey("- name");
        try self.writer.print(" \"{s}\"", .{message.name.value});
        self.incrIndent();
        defer self.decrIndent();

        try self.writeDocumentation(message.documentation);

        if (self.includeRange) {
            try self.writeKey("range");
            try self.writeRange(message.range);
        }

        if (message.embeddedMessages.len > 0 or !self.excludeZeroValues) {
            try self.writeKey("embedded_messages");
            self.incrIndent();
            defer self.decrIndent();
            for (message.embeddedMessages) |embeddedMsg| {
                try self.writeArrayPrefix();
                try self.writeSelector(embeddedMsg);
            }
        }

        if (message.options.len > 0 or !self.excludeZeroValues) {
            try self.writeKey("options");
            try self.writeOptions(message.options, false);
        }

        if (message.oneOfGroups.len > 0 or !self.excludeZeroValues) {
            try self.writeKey("oneof_groups");
            self.incrIndent();
            defer self.decrIndent();
            for (message.oneOfGroups) |oneOf| {
                try self.writeOneOf(oneOf);
            }
        }

        if (message.fields.len > 0 or !self.excludeZeroValues) {
            try self.writeKey("fields");
            self.incrIndent();
            defer self.decrIndent();
            for (message.fields) |field| {
                try self.writeField(field);
            }
        }
    }

    fn writeMessages(self: *Self, messages: []const ast.Message) !void {
        if (!self.includeMessages or (self.excludeZeroValues and messages.len == 0)) {
            return;
        }

        try self.writer.writeAll("messages:");
        self.incrIndent();
        defer self.decrIndent();
        for (messages) |message| {
            try self.writeMessage(message);
        }
        try self.writeNewLine();
    }

    fn writeOptionTargets(self: *Self, targets: ast.OptionTargetSet) !void {
        try self.writeKey("targets");
        self.incrIndent();
        defer self.decrIndent();

        var it = targets.iterator();
        while (it.next()) |target| {
            try self.writeArrayPrefix();
            try self.writer.print("{s}", .{@tagName(target)});
        }
        self.inArray = false;
        try self.writeNewLine();
    }

    fn writeFuncArg(self: *Self, arg: ast.FuncArg) !void {
        try self.writeKey("name");
        try self.writeSelector(arg.name);
        try self.writeKey("streaming");
        try self.writer.print(" {any}", .{arg.streaming});
    }

    fn writeFunc(self: *Self, func: ast.Func) !void {
        try self.writeKey("- name");
        try self.writer.print(" \"{s}\"", .{func.name.value});
        self.incrIndent();
        defer self.decrIndent();

        try self.writeDocumentation(func.documentation);

        if (self.includeRange) {
            try self.writeKey("range");
            try self.writeRange(func.range);
        }

        if (func.tag) |tag| {
            try self.writeKey("tag");
            try self.writer.print(" {d}", .{tag});
        } else if (!self.excludeZeroValues) {
            try self.writeKey("tag");
            try self.writer.writeAll(" ");
            try self.writer.writeAll(LiteralNone);
        }

        // Write input argument
        if (func.input) |input| {
            try self.writeKey("input");
            self.incrIndent();
            defer self.decrIndent();
            try self.writeFuncArg(input);
        } else if (!self.excludeZeroValues) {
            try self.writeKey("input");
            try self.writer.writeAll(" ");
            try self.writer.writeAll(LiteralNone);
        }

        // Write output argument
        if (func.output) |output| {
            try self.writeKey("output");
            self.incrIndent();
            defer self.decrIndent();
            try self.writeFuncArg(output);
        } else if (!self.excludeZeroValues) {
            try self.writeKey("output");
            try self.writer.writeAll(" ");
            try self.writer.writeAll(LiteralNone);
        }

        if (func.options.len > 0 or !self.excludeZeroValues) {
            try self.writeKey("options");
            try self.writeOptions(func.options, false);
        }
    }

    fn writeOptionDefinition(self: *Self, optDef: ast.OptionDefinition) !void {
        self.incrIndent();
        defer self.decrIndent();

        try self.writeOptionTargets(optDef.targets);

        if (self.includeRange) {
            try self.writeKey("range");
            try self.writeRange(optDef.range);
        }

        if (optDef.fields.len > 0 or !self.excludeZeroValues) {
            try self.writeKey("fields");
            self.incrIndent();
            defer self.decrIndent();
            for (optDef.fields) |field| {
                try self.writeField(field);
            }
        }
    }

    fn writeOptionDefinitions(self: *Self, optionDefinitions: []const ast.OptionDefinition) !void {
        if (!self.includeOptionDefinitions or (self.excludeZeroValues and optionDefinitions.len == 0)) {
            return;
        }

        try self.writer.writeAll("option_definitions:");
        self.incrIndent();
        defer self.decrIndent();
        for (optionDefinitions) |optDef| {
            try self.writeArrayPrefix();
            try self.writeOptionDefinition(optDef);
        }
        try self.writeNewLine();
    }

    fn writeInterface(self: *Self, interface: ast.Interface) !void {
        try self.writeKey("- name");
        try self.writer.print(" \"{s}\"", .{interface.name.value});
        self.incrIndent();
        defer self.decrIndent();

        try self.writeDocumentation(interface.documentation);

        if (self.includeRange) {
            try self.writeKey("range");
            try self.writeRange(interface.range);
        }

        if (interface.options.len > 0 or !self.excludeZeroValues) {
            try self.writeKey("options");
            try self.writeOptions(interface.options, false);
        }

        if (interface.funcs.len > 0 or !self.excludeZeroValues) {
            try self.writeKey("funcs");
            self.incrIndent();
            defer self.decrIndent();
            for (interface.funcs) |func| {
                try self.writeFunc(func);
            }
        }
    }

    fn writeDocumentation(self: *Self, documentation: ?ast.Documentation) !void {
        if (!self.includeDocumentation) {
            return;
        }

        if (documentation) |doc| {
            try self.writeKey("documentation");
            try self.writer.writeAll(" |\n");
            self.indentation += 1;
            defer self.indentation -= 1;
            var cursor: usize = 0;
            while (cursor < doc.content.len) {
                const end = cursor + (std.mem.indexOf(u8, doc.content[cursor..], "\n") orelse break);
                if ((end - cursor) > 0) {
                    _ = try self.writer.writeSplat(&.{" "}, self.indentation);
                    try self.writer.writeAll(doc.content[cursor .. end + 1]);
                } else try self.writer.writeAll("\n\n");
                cursor = end + 1;
            }
            try self.writeNewLine();
        }
    }

    fn writeInterfaces(self: *Self, interfaces: []const ast.Interface) !void {
        if (!self.includeInterfaces or (self.excludeZeroValues and interfaces.len == 0)) {
            return;
        }

        try self.writer.writeAll("interfaces:");
        self.incrIndent();
        defer self.decrIndent();
        for (interfaces) |interface| {
            try self.writeInterface(interface);
        }
        try self.writeNewLine();
    }
};

pub const YamlMarshaller = struct {
    const Self = @This();

    expandSelectors: bool = false,
    includeRange: bool = false,
    excludeZeroValues: bool = false,
    includePact: bool = false,
    includeImport: bool = false,
    includeOptionAssignments: bool = false,
    includeConstants: bool = false,
    includeEnums: bool = false,
    includeMessages: bool = false,
    includeOptionDefinitions: bool = false,
    includeInterfaces: bool = false,
    includeDocumentation: bool = false,

    pub fn writeDocument(self: Self, writer: *std.Io.Writer, doc: ast.Document) !void {
        var filteredWriter = NewlineFilterWriter.init(writer);
        var ctx = Context{
            .writer = &filteredWriter.interface,
            .expandSelectors = self.expandSelectors,
            .includeRange = self.includeRange,
            .excludeZeroValues = self.excludeZeroValues,
            .includePact = self.includePact,
            .includeImport = self.includeImport,
            .includeOptionAssignments = self.includeOptionAssignments,
            .includeConstants = self.includeConstants,
            .includeEnums = self.includeEnums,
            .includeMessages = self.includeMessages,
            .includeOptionDefinitions = self.includeOptionDefinitions,
            .includeInterfaces = self.includeInterfaces,
            .includeDocumentation = self.includeDocumentation,
        };

        try ctx.writeDocumentation(doc.documentation);
        try ctx.writePact(doc.pact);
        try ctx.writeImports(doc.imports);
        try ctx.writeOptions(doc.options, true);
        try ctx.writeConstants(doc.constants);
        try ctx.writeEnums(doc.enums);
        try ctx.writeMessages(doc.messages);
        try ctx.writeOptionDefinitions(doc.optionDefinitions);
        try ctx.writeInterfaces(doc.interfaces);
    }
};
