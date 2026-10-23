//! Schema modules are composed of children schema modules and a container for symbols.
const std = @import("std");

const parser = @import("parser.zig");
const ast = @import("ast.zig");
const LineMap = @import("LineMap.zig");

const Allocator = std.mem.Allocator;

// VirtualSourceLoader is an abstraction to allow iteration over
pub const VirtualSourceLoader = struct {
    pub const Error = error {
        /// Returned when end of the iteration is reached.
        EndOfIteration,
        /// Returned when an internal error is encountered during file entry listing, this would immediately
        /// abort the module loading.
        Abort,
    };
    pub const Entry = struct {
        path: []const u8,
        content: []const u8,
    };

    pub const VTable = struct {
        next: *const fn (ptr: *anyopaque) Error!Entry,
        readAll: *const fn (
            ptr: *anyopaque,
            allocator: Allocator,
            path: []const u8,
        ) error{ReadFailed, OutOfMemory}![]const u8,
    };

    ptr: *anyopaque,
    vtable: *const VTable,
};

pub const BuildOpts = struct {
    source: union(enum) {
        /// The path to the directory that should be used for the root module.
        module_root: []const u8,
        /// Use a virtual source loader to iterate over all of the pragma files and their content.
        /// Module building and merging files into the module is still handled automatically.
        virtual_source: VirtualSourceLoader,
    },
    allocator_transient: ?Allocator = null,
};

pub const LoadError = struct {
    pub const Details = union(enum) {
        invalid_utf8,
        parse_error: struct {
            message: []const u8,
            code: parser.PragmaError.Code,
        },
        duplicated_symbol: struct {
            name: []const u8,
            path: []const u8,
            range: ast.Range,
        },
    };

    pub const Location = union(enum) {
        position: usize,
        range: ast.Range,
    };

    details: Details,
    path: []const u8,
    location: ?Location,
};

pub const BuildError = error{ VirtualSourceError, DirListError } || Allocator.Error;
pub const BuildResult = struct {
    errors: []const LoadError,
};

const ModuleBuilder = struct {
    io: std.Io,
    allocator_output: Allocator,
    allocator_transient: Allocator,
    opts: BuildOpts,

    errors: std.ArrayList(LoadError) = .empty,

    symbols: std.ArrayList(Symbol) = .empty,
    symbols_cache: std.HashMapUnmanaged(SymbolKey, u32, SymbolKey.Context, 80) = .empty,
    modules: Node = std.mem.zeroes(Node), // root module is always available!
    next_module_id: ModuleId = 1,
    files: std.ArrayList(File) = .empty,

    const SymbolId = u32;
    const TypeId = u32;
    const ModuleId = u32;

    const File = struct {
        path: []const u8,
    };

    const Symbol = struct {
        const Decl = union(enum) {
            struct_def: *const ast.Struct,
            enum_def: *const ast.Enum,
            protocol_def: *const ast.Protocol,
            constant_def: *const ast.Constant,
            // ... other types.
        };

        name: []const u8,
        module: *Node,
        file_index: u32,
        decl: Decl,

        fn rangeOfName(decl: Decl) ?ast.Range {
            return switch (decl) {
                .struct_def => |v| v.name.range,
                .enum_def => |v| v.name.range, 
                .protocol_def => |v| v.name.range, 
                .constant_def => |v| v.name.range, 
            };
        }
    };

    const SymbolKey = struct {
        module_id: ModuleId,
        name: []const u8,

        const Context = struct {
            pub fn hash(_: Context, key: SymbolKey) u64 {
                var hasher = std.hash.Wyhash.init(0);
                hasher.update(std.mem.asBytes(&key.module_id));
                hasher.update(key.name);
                return hasher.final();
            }

            pub fn eql(_: Context, one: SymbolKey, another: SymbolKey) bool {
                return one.module_id == another.module_id and std.mem.eql(u8, one.name, another.name);
            }
        };
    };

    const StringContext = struct {
        pub fn hash(_: @This(), key: []const u8) u64 {
            var hasher = std.hash.Wyhash.init(0);
            hasher.update(key);
            return hasher.final();
        }

        pub fn eql(_: @This(), one: []const u8, another: []const u8) bool {
            return std.mem.eql(u8, one, another);
        }
    };

    const Node = struct {
        id: ModuleId,
        name: []const u8,
        parent: ?*Node,
        first_child: ?*Node,
        next_sibling: ?*Node,
        symbols: std.ArrayList(SymbolId),
        documentation: ?[]const u8,
        // TODO: I should register the annotations here as well.

        // TODO: add methods for finding, inserting and resolving.
    };

    fn init(allocator: Allocator, io: std.Io, opts: BuildOpts) ModuleBuilder {
        return .{
            .allocator_output = allocator,
            .allocator_transient = opts.allocator_transient orelse allocator,
            .io = io,
            .opts = opts,
        };
    }

    const SymbolRegisterResult = struct {
        symbol: *Symbol,
        found_existing: bool,
    };

    fn registerSymbol(
        self: *ModuleBuilder,
        module: *Node,
        name: []const u8,
        file_index: u32,
        decl: Symbol.Decl,
    ) BuildError!SymbolRegisterResult {
        // First make sure the symbol is not already registered.
        const result = try self.symbols_cache.getOrPut(
            self.allocator_transient,
            SymbolKey{ .module_id = module.id, .name = name },
        );
        if (result.found_existing) {
            const existing_symbol_index: usize = @intCast(result.value_ptr.*);
            const existing_symbol: *Symbol = &self.symbols.items[existing_symbol_index];
            const existing_file: *File = &self.files.items[existing_symbol.file_index];

            const new_file: *File = &self.files.items[file_index];

            const load_error: LoadError = .{
                .path = new_file.path,
                .details = .{
                    .duplicated_symbol = .{
                        .name = name,
                        .path = existing_file.path,
                        .range = Symbol.rangeOfName(existing_symbol.decl) orelse @panic("unexpected symbol"),
                    },
                },
                .location = .{ .range = Symbol.rangeOfName(decl) orelse @panic("unexpected symbol") }
            };
            try self.errors.append(self.allocator_transient, load_error);

            // Issue an error indicating that this symbol is a duplicate and is already defined elsewhere.
            return .{ .symbol = existing_symbol, .found_existing = true };
        }

        // Allocate the symbol and insert it to the module.
        const symbol_ptr: *Symbol = try self.symbols.addOne(self.allocator_transient);
        symbol_ptr.name = name;
        symbol_ptr.decl = decl;
        symbol_ptr.file_index = file_index;
        symbol_ptr.module = module;

        const symbol_id: u32 = @intCast(self.symbols.items.len - 1);
        result.value_ptr.* = symbol_id;
        try module.symbols.append(self.allocator_transient, symbol_id);
        return .{ .symbol = symbol_ptr, .found_existing = false };
    }

    inline fn createModule(self: *ModuleBuilder, name: []const u8) Allocator.Error!*Node {
        var new_node: *Node = try self.allocator_transient.create(Node);
        new_node.* = std.mem.zeroes(Node);
        new_node.name = try self.allocator_transient.dupe(u8, name);
        new_node.id = self.next_module_id;
        self.next_module_id += 1;
        return new_node;
    }

    fn getOrCreateModule(self: *ModuleBuilder, path: []const u8) Allocator.Error!*Node {
        // TODO: the name of the module has to get sanitized.
        const module_path = path[0..std.mem.lastIndexOfScalar(u8, path, '/') orelse path.len];
        var it = std.Io.Dir.path.componentIterator(module_path);
        var cursor: *Node = &self.modules;
        while (it.next()) |segment| {
            // Find the segment and if it does not exist, create it!
            cursor = cursor.first_child orelse {
                const new_node: *Node = try self.createModule(segment.name);
                cursor.first_child = new_node;
                cursor = new_node;
                continue;
            };

            while (true) {
                if (std.mem.eql(u8, segment.name, cursor.name)) {
                    break;
                }
                cursor = cursor.next_sibling orelse {
                    const new_node: *Node = try self.createModule(segment.name);
                    cursor.next_sibling = new_node;
                    cursor = new_node;
                    break;
                };
            }
        }
        return cursor;
    }

    fn registerAllSymbols(self: *ModuleBuilder) BuildError!void {
        switch (self.opts.source) {
            .module_root => |root| {
                var dir = std.Io.Dir.cwd().openDir(self.io, root, .{
                    .iterate = true,
                    .access_sub_paths = true,
                    .follow_symlinks = true,
                }) catch |err| {
                    std.log.err("dir read error: {s}", .{ @errorName(err) });
                    return BuildError.DirListError;
                };
                var it = try dir.walk(self.allocator_transient);
                defer it.deinit();
                while (true) {
                    const entry = it.next(self.io) catch |err| {
                        std.log.err("dir read error: {s}", .{ @errorName(err) });
                        return BuildError.DirListError;
                    };
                    if (entry) |item| {
                        if (item.kind != .file) {
                            continue;
                        }
                        if (!std.mem.endsWith(u8, item.basename, ".pragma")) {
                            continue;
                        }

                        const content = dir.readFileAlloc(
                            self.io,
                            item.path,
                            self.allocator_transient,
                            .unlimited,
                        ) catch |err| {
                            std.log.err("dir read error({s}): {s}", .{ item.path, @errorName(err) });
                            return BuildError.DirListError;
                        };
                        defer self.allocator_transient.free(content);
                        try self.addFile(item.path, content);
                    } else break;
                }
            },
            .virtual_source => |virtual_it| {
                while (virtual_it.vtable.next(virtual_it.ptr)) |entry| {
                    try self.addFile(entry.path, entry.content);
                } else |err| switch (err) {
                    VirtualSourceLoader.Error.EndOfIteration => return,
                    VirtualSourceLoader.Error.Abort => return BuildError.VirtualSourceError,
                }
            },
        }
    }

    fn bindSymbols(self: *ModuleBuilder) BuildError!void {
        _ = self;
    }

    fn start(self: *ModuleBuilder) BuildError!void {
        // Phase 1: Load all of the files, insert all symbols into the symbol registry.
        //          Prepare all of the modules and register them in the module trie.
        //          At the end of the phase, we should have a record of all modules
        //          and all of the symbols.
        try self.registerAllSymbols();

        // Phase 2: Bind all of the symbols and hold add strong and weak references between types.
        //          Every symbol gets an adjacency vector where A -> B means A depends on B.
        try self.bindSymbols();
    }

    // Add a file in the module trie.
    // The file gets parsed, all of its symbols registered in the module trie and the symbol registry.
    fn addFile(self: *ModuleBuilder, path: []const u8, content: []const u8) BuildError!void {
        const result = parser.parse(self.allocator_transient, content, .{}) catch |err| switch (err) {
            error.InvalidUtf8 => {
                try self.errors.append(
                    self.allocator_transient,
                    .{ .path = path, .location = null, .details = .invalid_utf8 },
                );
                return;
            },
            error.OutOfMemory => |e| return e,
        };

        const file = try self.files.addOne(self.allocator_transient);
        file.path = try self.allocator_transient.dupe(u8, path);
        const file_index: u32 = @intCast(self.files.items.len - 1);

        if (!result.ok()) {
            // TODO: use a config to limit the number of errors per file and the number of files before giving up.
            for (result.errors) |parse_err| {
                const err_location: ?LoadError.Location = blk: {
                    if (parse_err.location) |loc| switch (loc) {
                        .position => |pos| break :blk .{ .position = pos },
                        .range => |range| break :blk .{ .range = range },
                    } else break :blk null;
                };
                try self.errors.append(self.allocator_transient, .{
                    .path = file.path,
                    .location = err_location,
                    .details = .{
                        .parse_error = .{
                            .code = parse_err.code,
                            .message = parse_err.message,
                        },
                    },
                });
            }
        }

        // Create the module entry and go over the symbols and register all of them.
        const module: *Node = try self.getOrCreateModule(path);
        for (result.document.structs) |struct_def| {
            _ = try self.registerSymbol(module, struct_def.name.value, file_index, .{ .struct_def = &struct_def });
        }
        for (result.document.enums) |enum_def| {
            _ = try self.registerSymbol(module, enum_def.name.value, file_index, .{ .enum_def = &enum_def });
        }
        for (result.document.protocols) |protocol_def| {
            _ = try self.registerSymbol(module, protocol_def.name.value, file_index, .{ .protocol_def = &protocol_def });
        }
        for (result.document.constants) |constant_def| {
            _ = try self.registerSymbol(module, constant_def.name.value, file_index, .{ .constant_def = &constant_def });
        }
    }
};

pub fn build(allocator: Allocator, io: std.Io, opts: BuildOpts) BuildError!BuildResult {
    // TODO : Figure out the allocators here, do we use transient? do we use arena? page allocator?
    //        How do we deinit?

    // TODO : find the module file, if you can't find it, return an error.
    //        once you find it, load it. For the time being, you can ignore this.
    var loader: ModuleBuilder = .init(allocator, io, opts);
    try loader.start();

    return BuildResult{ .errors = loader.errors.items };
}
