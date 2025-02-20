const std = @import("std");
const builtin = @import("builtin");
const Dependency = @import("Dependency.zig");
const Project = @import("Project.zig");
const utils = @import("utils.zig");
const ThreadSafeArenaAllocator = @import("ThreadSafeArenaAllocator.zig");

const Engine = @This();
const Allocator = std.mem.Allocator;
const StructField = std.builtin.TypeInfo.StructField;
const UnionField = std.builtin.TypeInfo.UnionField;
const testing = std.testing;
const assert = std.debug.assert;

pub const DepTable = std.ArrayListUnmanaged(Dependency.Source);
pub const Sources = .{
    @import("pkg.zig"),
    @import("local.zig"),
    @import("url.zig"),
    @import("git.zig"),
};

comptime {
    inline for (Sources) |source| {
        const type_info = @typeInfo(@TypeOf(source.dedupeResolveAndFetch));
        if (type_info.Fn.return_type != void)
            @compileError("dedupeResolveAndFetch has to return void, not !void");
    }
}

pub const Edge = struct {
    const ParentIndex = union(enum) {
        root: enum {
            normal,
            build,
        },
        index: usize,
    };

    from: ParentIndex,
    to: usize,
    alias: []const u8,

    pub fn format(
        edge: Edge,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) @TypeOf(writer).Error!void {
        _ = fmt;
        _ = options;

        switch (edge.from) {
            .root => |which| switch (which) {
                .normal => try writer.print("Edge: deps -> {}: {s}", .{ edge.to, edge.alias }),
                .build => try writer.print("Edge: build_deps -> {}: {s}", .{ edge.to, edge.alias }),
            },
            .index => |idx| try writer.print("Edge: {} -> {}: {s}", .{ idx, edge.to, edge.alias }),
        }
    }
};

pub const Resolutions = blk: {
    var tables_fields: [Sources.len]StructField = undefined;
    var edges_fields: [Sources.len]StructField = undefined;

    inline for (Sources) |source, i| {
        const ResolutionTable = std.ArrayListUnmanaged(source.ResolutionEntry);
        tables_fields[i] = StructField{
            .name = source.name,
            .field_type = ResolutionTable,
            .alignment = @alignOf(ResolutionTable),
            .is_comptime = false,
            .default_value = null,
        };

        const EdgeTable = std.ArrayListUnmanaged(struct {
            dep_idx: usize,
            res_idx: usize,
        });
        edges_fields[i] = StructField{
            .name = source.name,
            .field_type = EdgeTable,
            .alignment = @alignOf(EdgeTable),
            .is_comptime = false,
            .default_value = null,
        };
    }

    const Tables = @Type(std.builtin.TypeInfo{
        .Struct = .{
            .layout = .Auto,
            .is_tuple = false,
            .fields = &tables_fields,
            .decls = &.{},
        },
    });

    const Edges = @Type(std.builtin.TypeInfo{
        .Struct = .{
            .layout = .Auto,
            .is_tuple = false,
            .fields = &edges_fields,
            .decls = &.{},
        },
    });

    break :blk struct {
        text: []const u8,
        tables: Tables,
        edges: Edges,
        const Self = @This();

        pub fn deinit(self: *Self, allocator: *Allocator) void {
            inline for (Sources) |source| {
                @field(self.tables, source.name).deinit(allocator);
                @field(self.edges, source.name).deinit(allocator);
            }

            allocator.free(self.text);
        }

        pub fn fromReader(allocator: *Allocator, reader: anytype) !Self {
            var ret = Self{
                .text = try reader.readAllAlloc(allocator, std.math.maxInt(usize)),
                .tables = undefined,
                .edges = undefined,
            };

            inline for (std.meta.fields(Tables)) |field|
                @field(ret.tables, field.name) = field.field_type{};

            inline for (std.meta.fields(Edges)) |field|
                @field(ret.edges, field.name) = field.field_type{};

            errdefer ret.deinit(allocator);

            var line_it = std.mem.tokenize(u8, ret.text, "\n");
            var count: usize = 0;
            iterate: while (line_it.next()) |line| : (count += 1) {
                var it = std.mem.tokenize(u8, line, " ");
                const first = it.next() orelse return error.EmptyLine;
                inline for (Sources) |source| {
                    if (std.mem.eql(u8, first, source.name)) {
                        source.deserializeLockfileEntry(
                            allocator,
                            &it,
                            &@field(ret.tables, source.name),
                        ) catch |err| {
                            std.log.warn(
                                "invalid lockfile entry on line {}, {s} -- ignoring and removing:\n{s}\n",
                                .{ count + 1, @errorName(err), line },
                            );
                            continue :iterate;
                        };
                        break;
                    }
                } else {
                    std.log.err("unsupported lockfile prefix: {s}", .{first});
                    return error.Explained;
                }
            }

            return ret;
        }
    };
};

pub fn MultiQueueImpl(comptime Resolution: type, comptime Error: type) type {
    return std.MultiArrayList(struct {
        edge: Edge,
        thread: ?std.Thread = null,
        result: union(enum) {
            replace_me: usize,
            fill_resolution: usize,
            copy_deps: usize,
            new_entry: Resolution,
            err: Error,
        } = undefined,
        path: ?[]const u8 = null,
        deps: std.ArrayListUnmanaged(Dependency),
    });
}

pub const FetchQueue = blk: {
    var fields: [Sources.len]StructField = undefined;
    var next_fields: [Sources.len]StructField = undefined;

    inline for (Sources) |source, i| {
        const MultiQueue = MultiQueueImpl(
            source.Resolution,
            source.FetchError,
        );

        fields[i] = StructField{
            .name = source.name,
            .field_type = MultiQueue,
            .alignment = @alignOf(MultiQueue),
            .is_comptime = false,
            .default_value = null,
        };

        next_fields[i] = StructField{
            .name = source.name,
            .field_type = std.ArrayListUnmanaged(Edge),
            .alignment = @alignOf(std.ArrayListUnmanaged(Edge)),
            .is_comptime = false,
            .default_value = null,
        };
    }

    const Tables = @Type(std.builtin.TypeInfo{
        .Struct = .{
            .layout = .Auto,
            .is_tuple = false,
            .fields = &fields,
            .decls = &.{},
        },
    });

    const NextType = @Type(std.builtin.TypeInfo{
        .Struct = .{
            .layout = .Auto,
            .is_tuple = false,
            .fields = &next_fields,
            .decls = &.{},
        },
    });

    break :blk struct {
        tables: Tables,
        const Self = @This();

        pub const Next = struct {
            tables: NextType,

            pub fn init() @This() {
                var ret: @This() = undefined;
                inline for (Sources) |source|
                    @field(ret.tables, source.name) = std.ArrayListUnmanaged(Edge){};

                return ret;
            }

            pub fn deinit(self: *@This(), allocator: *Allocator) void {
                inline for (Sources) |source|
                    @field(self.tables, source.name).deinit(allocator);
            }

            pub fn append(
                self: *@This(),
                allocator: *Allocator,
                src_type: Dependency.SourceType,
                edge: Edge,
            ) !void {
                inline for (Sources) |source| {
                    if (src_type == @field(Dependency.SourceType, source.name)) {
                        try @field(self.tables, source.name).append(allocator, edge);
                        break;
                    }
                } else {
                    std.log.err("unsupported dependency source type: {}", .{src_type});
                    assert(false);
                    return error.Explained;
                }
            }
        };

        pub fn init() Self {
            var ret: Self = undefined;

            inline for (std.meta.fields(Tables)) |field|
                @field(ret.tables, field.name) = field.field_type{};

            return ret;
        }

        pub fn deinit(self: *Self, allocator: *Allocator) void {
            inline for (Sources) |source| {
                @field(self.tables, source.name).deinit(allocator);
            }
        }

        pub fn append(
            self: *Self,
            allocator: *Allocator,
            src_type: Dependency.SourceType,
            edge: Edge,
        ) !void {
            inline for (Sources) |source| {
                if (src_type == @field(Dependency.SourceType, source.name)) {
                    try @field(self.tables, source.name).append(allocator, .{
                        .edge = edge,
                        .deps = std.ArrayListUnmanaged(Dependency){},
                    });
                    break;
                }
            } else {
                std.log.err("unsupported dependency source type: {}", .{src_type});
                assert(false);
                return error.Explained;
            }
        }

        pub fn empty(self: Self) bool {
            return inline for (Sources) |source| {
                if (@field(self.tables, source.name).len != 0) break false;
            } else true;
        }

        pub fn clearAndLoad(self: *Self, allocator: *Allocator, next: Next) !void {
            // clear current table
            inline for (Sources) |source| {
                @field(self.tables, source.name).shrinkRetainingCapacity(0);
                for (@field(next.tables, source.name).items) |edge| {
                    try @field(self.tables, source.name).append(allocator, .{
                        .edge = edge,
                        .deps = std.ArrayListUnmanaged(Dependency){},
                    });
                }
            }
        }

        pub fn parallelFetch(
            self: *Self,
            arena: *ThreadSafeArenaAllocator,
            dep_table: DepTable,
            resolutions: Resolutions,
        ) !void {
            errdefer inline for (Sources) |source|
                for (@field(self.tables, source.name).items(.thread)) |th|
                    if (th) |t|
                        t.join();

            inline for (Sources) |source| {
                for (@field(self.tables, source.name).items(.thread)) |*th, i| {
                    th.* = try std.Thread.spawn(
                        .{},
                        source.dedupeResolveAndFetch,
                        .{
                            arena,
                            dep_table.items,
                            @field(resolutions.tables, source.name).items,
                            &@field(self.tables, source.name),
                            i,
                        },
                    );
                }
            }

            inline for (Sources) |source|
                for (@field(self.tables, source.name).items(.thread)) |th|
                    th.?.join();
        }

        pub fn cleanupDeps(self: *Self, allocator: *Allocator) void {
            _ = self;
            _ = allocator;
            //inline for (Sources) |source|
            //    for (@field(self.tables, source.name).items(.deps)) |*deps|
            //        deps.deinit(allocator);
        }
    };
};

allocator: *Allocator,
arena: ThreadSafeArenaAllocator,
project: *Project,
dep_table: DepTable,
edges: std.ArrayListUnmanaged(Edge),
fetch_queue: FetchQueue,
resolutions: Resolutions,
paths: std.AutoHashMapUnmanaged(usize, []const u8),

pub fn init(
    allocator: *Allocator,
    project: *Project,
    lockfile_reader: anytype,
) !Engine {
    const initial_deps = project.deps.items.len + project.build_deps.items.len;
    var dep_table = try DepTable.initCapacity(allocator, initial_deps);
    errdefer dep_table.deinit(allocator);

    var fetch_queue = FetchQueue.init();
    errdefer fetch_queue.deinit(allocator);

    for (project.deps.items) |dep| {
        try dep_table.append(allocator, dep.src);
        try fetch_queue.append(allocator, dep.src, .{
            .from = .{
                .root = .normal,
            },
            .to = dep_table.items.len - 1,
            .alias = dep.alias,
        });
    }

    for (project.build_deps.items) |dep| {
        try dep_table.append(allocator, dep.src);
        try fetch_queue.append(allocator, dep.src, .{
            .from = .{
                .root = .build,
            },
            .to = dep_table.items.len - 1,
            .alias = dep.alias,
        });
    }

    const resolutions = try Resolutions.fromReader(allocator, lockfile_reader);
    errdefer resolutions.deinit(allocator);

    return Engine{
        .allocator = allocator,
        .arena = ThreadSafeArenaAllocator.init(allocator),
        .project = project,
        .dep_table = dep_table,
        .edges = std.ArrayListUnmanaged(Edge){},
        .fetch_queue = fetch_queue,
        .resolutions = resolutions,
        .paths = std.AutoHashMapUnmanaged(usize, []const u8){},
    };
}

pub fn deinit(self: *Engine) void {
    self.dep_table.deinit(self.allocator);
    self.edges.deinit(self.allocator);
    self.fetch_queue.deinit(self.allocator);
    self.resolutions.deinit(self.allocator);
    self.paths.deinit(self.allocator);
    self.arena.deinit();
}

// look at root dependencies and clear the resolution associated with it.
// note: will update the same alias in both dep and build_deps
pub fn clearResolution(self: *Engine, alias: []const u8) !void {
    inline for (Sources) |source| {
        for (@field(self.fetch_queue.tables, source.name).items(.edge)) |edge| if (edge.from == .root) {
            if (std.mem.eql(u8, alias, edge.alias)) {
                const dep = self.dep_table.items[edge.to];
                if (dep == @field(Dependency.Source, source.name)) {
                    if (source.findResolution(dep, @field(self.resolutions.tables, source.name).items)) |res_idx| {
                        _ = @field(self.resolutions.tables, source.name).orderedRemove(res_idx);
                    }
                }
            }
        };
    }
}

pub fn fetch(self: *Engine) !void {
    defer self.fetch_queue.cleanupDeps(self.allocator);
    while (!self.fetch_queue.empty()) {
        var next = FetchQueue.Next.init();
        defer next.deinit(self.allocator);

        {
            try self.fetch_queue.parallelFetch(&self.arena, self.dep_table, self.resolutions);

            // inline for workaround because the compiler wasn't generating the right code for this
            var explained = false;
            for (self.fetch_queue.tables.pkg.items(.result)) |_, i|
                Sources[0].updateResolution(self.allocator, &self.resolutions.tables.pkg, self.dep_table.items, &self.fetch_queue.tables.pkg, i) catch |err| {
                    if (err == error.Explained)
                        explained = true
                    else
                        return err;
                };

            for (self.fetch_queue.tables.local.items(.result)) |_, i|
                Sources[1].updateResolution(self.allocator, &self.resolutions.tables.local, self.dep_table.items, &self.fetch_queue.tables.local, i) catch |err| {
                    if (err == error.Explained)
                        explained = true
                    else
                        return err;
                };

            for (self.fetch_queue.tables.url.items(.result)) |_, i|
                Sources[2].updateResolution(self.allocator, &self.resolutions.tables.url, self.dep_table.items, &self.fetch_queue.tables.url, i) catch |err| {
                    if (err == error.Explained)
                        explained = true
                    else
                        return err;
                };

            for (self.fetch_queue.tables.git.items(.result)) |_, i|
                Sources[3].updateResolution(self.allocator, &self.resolutions.tables.git, self.dep_table.items, &self.fetch_queue.tables.git, i) catch |err| {
                    if (err == error.Explained)
                        explained = true
                    else
                        return err;
                };

            if (explained)
                return error.Explained;

            inline for (Sources) |source| {
                for (@field(self.fetch_queue.tables, source.name).items(.path)) |opt_path, i| {
                    if (opt_path) |path| {
                        try self.paths.putNoClobber(
                            self.allocator,
                            @field(self.fetch_queue.tables, source.name).items(.edge)[i].to,
                            path,
                        );
                    }
                }

                // set up next batch of deps to fetch
                for (@field(self.fetch_queue.tables, source.name).items(.deps)) |deps, i| {
                    const dep_index = @field(self.fetch_queue.tables, source.name).items(.edge)[i].to;
                    for (deps.items) |dep| {
                        try self.dep_table.append(self.allocator, dep.src);
                        const edge = Edge{
                            .from = .{
                                .index = dep_index,
                            },
                            .to = self.dep_table.items.len - 1,
                            .alias = dep.alias,
                        };

                        try next.append(self.allocator, dep.src, edge);
                    }
                }

                // copy edges
                try self.edges.appendSlice(
                    self.allocator,
                    @field(self.fetch_queue.tables, source.name).items(.edge),
                );
            }
        }

        try self.fetch_queue.clearAndLoad(self.allocator, next);
    }

    // TODO: check for circular dependencies

    // TODO: deleteTree doesn't work on windows with hidden or read-only files
    if (builtin.target.os.tag != .windows) {
        // clean up cache
        var paths = std.StringHashMap(void).init(self.allocator);
        defer paths.deinit();

        inline for (Sources) |source| {
            if (@hasDecl(source, "resolutionToCachePath")) {
                for (@field(self.resolutions.tables, source.name).items) |entry| {
                    if (entry.dep_idx != null) {
                        try paths.putNoClobber(try source.resolutionToCachePath(&self.arena.allocator, entry), {});
                    }
                }
            }
        }

        var cache_dir = try std.fs.cwd().openDir(".gyro", .{ .iterate = true });
        defer cache_dir.close();

        var it = cache_dir.iterate();
        while (try it.next()) |entry| switch (entry.kind) {
            .Directory => if (!paths.contains(entry.name)) {
                try cache_dir.deleteTree(entry.name);
            },
            else => {},
        };
    }
}

pub fn writeLockfile(self: Engine, writer: anytype) !void {
    inline for (Sources) |source|
        try source.serializeResolutions(@field(self.resolutions.tables, source.name).items, writer);
}

pub fn writeDepBeginRoot(self: *Engine, writer: anytype, indent: usize, edge: Edge) !void {
    const escaped = try utils.escape(self.allocator, edge.alias);
    defer self.allocator.free(escaped);

    try writer.writeByteNTimes(' ', 4 * indent);
    try writer.print("pub const {s} = Pkg{{\n", .{escaped});
    try writer.writeByteNTimes(' ', 4 * (indent + 1));
    try writer.print(".name = \"{s}\",\n", .{edge.alias});

    try writer.writeByteNTimes(' ', 4 * (indent + 1));
    try writer.print(".path = FileSource{{\n", .{});

    const path = if (builtin.target.os.tag == .windows)
        try std.mem.replaceOwned(u8, self.allocator, self.paths.get(edge.to).?, "\\", "\\\\")
    else
        self.paths.get(edge.to).?;
    defer if (builtin.target.os.tag == .windows) self.allocator.free(path);

    try writer.writeByteNTimes(' ', 4 * (indent + 2));
    try writer.print(".path = \"{s}\",\n", .{path});

    try writer.writeByteNTimes(' ', 4 * (indent + 1));
    try writer.print("}},\n", .{});
}

pub fn writeDepEndRoot(writer: anytype, indent: usize) !void {
    try writer.writeByteNTimes(' ', 4 * (1 + indent));
    try writer.print("}},\n", .{});

    try writer.writeByteNTimes(' ', 4 * indent);
    try writer.print("}};\n\n", .{});
}

pub fn writeDepBegin(self: Engine, writer: anytype, indent: usize, edge: Edge) !void {
    try writer.writeByteNTimes(' ', 4 * indent);
    try writer.print("Pkg{{\n", .{});

    try writer.writeByteNTimes(' ', 4 * (indent + 1));
    try writer.print(".name = \"{s}\",\n", .{edge.alias});

    try writer.writeByteNTimes(' ', 4 * (indent + 1));
    try writer.print(".path = FileSource{{\n", .{});

    const path = if (builtin.target.os.tag == .windows)
        try std.mem.replaceOwned(u8, self.allocator, self.paths.get(edge.to).?, "\\", "\\\\")
    else
        self.paths.get(edge.to).?;
    defer if (builtin.target.os.tag == .windows) self.allocator.free(path);

    try writer.writeByteNTimes(' ', 4 * (indent + 2));
    try writer.print(".path = \"{s}\",\n", .{path});

    try writer.writeByteNTimes(' ', 4 * (indent + 1));
    try writer.print("}},\n", .{});

    _ = self;
}

pub fn writeDepEnd(writer: anytype, indent: usize) !void {
    try writer.writeByteNTimes(' ', 4 * (1 + indent));
    try writer.print("}},\n", .{});
}

pub fn writeDepsZig(self: *Engine, writer: anytype) !void {
    try writer.print(
        \\const std = @import("std");
        \\const Pkg = std.build.Pkg;
        \\const FileSource = std.build.FileSource;
        \\
        \\pub const pkgs = struct {{
        \\
    , .{});

    for (self.edges.items) |edge| {
        switch (edge.from) {
            .root => |root| if (root == .normal) {
                var stack = std.ArrayList(struct {
                    current: usize,
                    edge_idx: usize,
                    has_deps: bool,
                }).init(self.allocator);
                defer stack.deinit();

                var current = edge.to;
                var edge_idx = 1 + edge.to;
                var has_deps = false;
                try self.writeDepBeginRoot(writer, 1 + stack.items.len, edge);

                while (true) {
                    while (edge_idx < self.edges.items.len) : (edge_idx += 1) {
                        const root_level = stack.items.len == 0;
                        switch (self.edges.items[edge_idx].from) {
                            .index => |idx| if (idx == current) {
                                if (!has_deps) {
                                    const offset: usize = if (root_level) 2 else 3;
                                    try writer.writeByteNTimes(' ', 4 * (stack.items.len + offset));
                                    try writer.print(".dependencies = &[_]Pkg{{\n", .{});
                                    has_deps = true;
                                }

                                try stack.append(.{
                                    .current = current,
                                    .edge_idx = edge_idx,
                                    .has_deps = has_deps,
                                });

                                const offset: usize = if (root_level) 2 else 3;
                                try self.writeDepBegin(writer, offset + stack.items.len, self.edges.items[edge_idx]);
                                current = edge_idx;
                                edge_idx += 1;
                                has_deps = false;
                                break;
                            },
                            else => {},
                        }
                    } else if (stack.items.len > 0) {
                        if (has_deps) {
                            try writer.writeByteNTimes(' ', 4 * (stack.items.len + 3));
                            try writer.print("}},\n", .{});
                        }

                        const offset: usize = if (stack.items.len == 1) 2 else 3;
                        try writer.writeByteNTimes(' ', 4 * (stack.items.len + offset));
                        try writer.print("}},\n", .{});

                        const pop = stack.pop();
                        current = pop.current;
                        edge_idx = 1 + pop.edge_idx;
                        has_deps = pop.has_deps;
                    } else {
                        if (has_deps) {
                            try writer.writeByteNTimes(' ', 8);
                            try writer.print("}},\n", .{});
                        }

                        break;
                    }
                }

                try writer.writeByteNTimes(' ', 4);
                try writer.print("}};\n\n", .{});
            },
            else => {},
        }
    }
    try writer.print("    pub fn addAllTo(artifact: *std.build.LibExeObjStep) void {{\n", .{});
    for (self.edges.items) |edge| {
        switch (edge.from) {
            .root => |root| if (root == .normal) {
                try writer.print("        artifact.addPackage(pkgs.{s});\n", .{
                    try utils.escape(&self.arena.allocator, edge.alias),
                });
            },
            else => {},
        }
    }
    try writer.print("    }}\n", .{});

    try writer.print("}};\n", .{});

    if (self.project.packages.count() == 0)
        return;

    try writer.print("\npub const exports = struct {{\n", .{});
    var it = self.project.packages.iterator();
    while (it.next()) |pkg| {
        const path: []const u8 = pkg.value_ptr.root orelse utils.default_root;
        try writer.print(
            \\    pub const {s} = Pkg{{
            \\        .name = "{s}",
            \\        .path = "{s}",
            \\
        , .{
            try utils.escape(&self.arena.allocator, pkg.value_ptr.name),
            pkg.value_ptr.name,
            path,
        });

        if (self.project.deps.items.len > 0) {
            try writer.print("        .dependencies = &[_]Pkg{{\n", .{});
            for (self.edges.items) |edge| {
                switch (edge.from) {
                    .root => |root| if (root == .normal) {
                        try writer.print("            pkgs.{s},\n", .{
                            try utils.escape(&self.arena.allocator, edge.alias),
                        });
                    },
                    else => {},
                }
            }
            try writer.print("        }},\n", .{});
        }

        try writer.print("    }};\n", .{});
    }
    try writer.print("}};\n", .{});
}

fn recursivePrint(pkg: std.build.Pkg, depth: usize) void {
    const stdout = std.io.getStdOut().writer();
    stdout.writeByteNTimes(' ', depth) catch {};
    stdout.print("{s}\n", .{pkg.name}) catch {};

    if (pkg.dependencies) |deps| for (deps) |dep|
        recursivePrint(dep, depth + 1);
}

/// arena only stores the arraylists, not text, return slice is allocated in the arena
pub fn genBuildDeps(self: Engine, arena: *ThreadSafeArenaAllocator) !std.ArrayList(std.build.Pkg) {
    const allocator = arena.child_allocator;

    var ret = std.ArrayList(std.build.Pkg).init(allocator);
    errdefer ret.deinit();

    for (self.edges.items) |edge| {
        switch (edge.from) {
            .root => |root| if (root == .build) {
                var stack = std.ArrayList(struct {
                    current: usize,
                    edge_idx: usize,
                    deps: std.ArrayListUnmanaged(std.build.Pkg),
                }).init(allocator);
                defer stack.deinit();

                var current = edge.to;
                var edge_idx = 1 + edge.to;
                var deps = std.ArrayListUnmanaged(std.build.Pkg){};

                while (true) {
                    while (edge_idx < self.edges.items.len) : (edge_idx += 1) {
                        switch (self.edges.items[edge_idx].from) {
                            .index => |idx| if (idx == current) {
                                try deps.append(&arena.allocator, .{
                                    .name = self.edges.items[edge_idx].alias,
                                    .path = .{
                                        .path = self.paths.get(self.edges.items[edge_idx].to).?,
                                    },
                                });

                                try stack.append(.{
                                    .current = current,
                                    .edge_idx = edge_idx,
                                    .deps = deps,
                                });

                                current = edge_idx;
                                edge_idx += 1;
                                deps = std.ArrayListUnmanaged(std.build.Pkg){};
                                break;
                            },
                            else => {},
                        }
                    } else if (stack.items.len > 0) {
                        const pop = stack.pop();
                        if (deps.items.len > 0)
                            pop.deps.items[pop.deps.items.len - 1].dependencies = deps.items;

                        current = pop.current;
                        edge_idx = 1 + pop.edge_idx;
                        deps = pop.deps;
                    } else {
                        break;
                    }
                }

                try ret.append(.{
                    .name = edge.alias,
                    .path = .{ .path = self.paths.get(edge.to).? },
                    .dependencies = deps.items,
                });

                assert(stack.items.len == 0);
            },
            else => {},
        }
    }

    for (ret.items) |entry|
        recursivePrint(entry, 0);

    return ret;
}

test "Resolutions" {
    var text = "".*;
    var fb = std.io.fixedBufferStream(&text);
    var resolutions = try Resolutions.fromReader(testing.allocator, fb.reader());
    defer resolutions.deinit(testing.allocator);
}

test "FetchQueue" {
    var fetch_queue = FetchQueue.init();
    defer fetch_queue.deinit(testing.allocator);
}

test "fetch" {
    var text = "".*;
    var fb = std.io.fixedBufferStream(&text);
    var engine = Engine{
        .allocator = testing.allocator,
        .arena = ThreadSafeArenaAllocator.init(testing.allocator),
        .dep_table = DepTable{},
        .edges = std.ArrayListUnmanaged(Edge){},
        .fetch_queue = FetchQueue.init(),
        .resolutions = try Resolutions.fromReader(testing.allocator, fb.reader()),
    };
    defer engine.deinit();

    try engine.fetch();
}

test "writeLockfile" {
    var text = "".*;
    var fb = std.io.fixedBufferStream(&text);
    var engine = Engine{
        .allocator = testing.allocator,
        .arena = ThreadSafeArenaAllocator.init(testing.allocator),
        .dep_table = DepTable{},
        .edges = std.ArrayListUnmanaged(Edge){},
        .fetch_queue = FetchQueue.init(),
        .resolutions = try Resolutions.fromReader(testing.allocator, fb.reader()),
    };
    defer engine.deinit();

    try engine.writeLockfile(fb.writer());
}
