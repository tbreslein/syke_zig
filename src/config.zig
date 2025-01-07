const std = @import("std");
const Lua = @import("ziglua").Lua;
const CLI = @import("cli.zig").CLI;
const Logger = @import("logger.zig").Logger;
const Allocator = std.mem.Allocator;

const generation_prefix = "syke-generation_";

pub const ConfigGen = struct {
    conf: Config,
    gen: u32,

    pub fn initFromLua(cli: CLI, logger: *Logger, allocator: Allocator) !@This() {
        return .{
            .conf = try Config.initFromLua(cli, logger, allocator),
            .gen = 0,
        };
    }

    pub fn initFromLastGen(_: CLI, logger: *Logger, allocator: Allocator) !@This() {
        var conf_gen = ConfigGen{ .conf = undefined, .gen = 0 };

        const home = try std.process.getEnvVarOwned(allocator, "HOME");
        const cache_dir = try std.fmt.allocPrint(allocator, "{s}/.local/cache/syke", .{home});
        var dir = std.fs.cwd().openDir(cache_dir, .{ .iterate = true }) catch return conf_gen;
        defer dir.close();

        var dir_iter = dir.iterate();
        var largest_gen_file: [1024]u8 = undefined;
        var largest_gen_file_len: usize = 0;
        var at_least_one_gen = false;

        while (try dir_iter.next()) |d| {
            if (!std.mem.startsWith(u8, d.name, generation_prefix)) {
                continue;
            }
            at_least_one_gen = true;
            const gen_idx = 1 + (std.mem.lastIndexOfScalar(u8, d.name, '_') orelse {
                try logger.err(
                    "syke-generation file at {s} misspelled; has to contain a _ character",
                    .{d.name},
                );
                return error.LuaError;
            });
            const gen = std.fmt.parseUnsigned(u32, d.name[gen_idx..], 10) catch {
                try logger.err(
                    "Unable to parse syke generation number from file name {s}",
                    .{d.name},
                );
                return error.LuaError;
            };
            if (gen >= conf_gen.gen) {
                conf_gen.gen = gen;
                std.mem.copyForwards(u8, &largest_gen_file, d.name);
                largest_gen_file_len = d.name.len;
            }
        }

        if (at_least_one_gen) {
            var lua = try Lua.init(allocator);
            // defer lua.deinit();

            const last_gen_file_z = try std.fmt.allocPrintZ(
                allocator,
                "{s}/{s}",
                .{ cache_dir, largest_gen_file[0..largest_gen_file_len] },
            );
            lua.doFile(last_gen_file_z) catch |err| {
                try logger.err("{s}", .{try lua.toString(-1)});
                return err;
            };
            conf_gen.conf = try parseFromLua(Config, allocator, logger, lua);
        }

        return conf_gen;
    }

    pub fn dumpToStringLua(self: @This(), logger: *Logger, allocator: Allocator) ![]const u8 {
        if (logger.verbose) try logger.newContext("dump config into string");

        var string_buffer = std.ArrayList(u8).init(allocator);
        try string_buffer.appendSlice("return {\n");

        try dumpToLua(Config, self.conf, &string_buffer, logger);

        try string_buffer.appendSlice("}\n");

        if (logger.verbose) try logger.contextFinish();
        return string_buffer.items;
    }
};

pub const Config = struct {
    symlinks: []Symlink = &[_]Symlink{},
    repos: []Repo = &[_]Repo{},
    services: []Service = &[_]Service{},
    shell: ?ShellMap = null,

    pub const Symlink = struct {
        source: []const u8 = "",
        target: []const u8,

        fn validate(_: @This(), _: *Logger) !void {}
    };

    pub const Repo = struct {
        remote: []const u8,
        path: []const u8,

        fn validate(_: @This(), _: *Logger) !void {}
    };

    const Level = enum { user, root };

    pub const Service = struct {
        name: []const u8,
        level: Level = .user,
        state: State,
        const State = enum { enabled, disabled, started, stopped, restarted };

        fn validate(_: @This(), _: *Logger) !void {}
    };

    pub const Shell = struct {
        cmd: []const []const u8,
        level: Level = .user,
        hook: Hook = .{},
        cwd: ?[]const u8 = null,

        pub const Hook = struct {
            when: When = .after,
            what: What = .main,
            const When = enum { before, after };
            const What = enum { main, ln, repos, services, commands, pkgs, text };

            fn validate(_: @This(), _: *Logger) !void {}

            pub fn to_int(self: @This()) HookSize {
                return @as(HookSize, @intFromEnum(self.when)) | (@as(HookSize, @intFromEnum(self.what)) << 1);
            }
            fn from_int(x: HookSize) @This() {
                const when: When = @enumFromInt(x & 1);
                const what: What = @enumFromInt(x >> 1);
                return .{ .when = when, .what = what };
            }
        };

        const HookSize: type = u4;
        const n_hooks: HookSize = blk: {
            const s = @typeInfo(Hook.What).Enum.fields.len * @typeInfo(Hook.When).Enum.fields.len;
            std.debug.assert(s < 16);
            break :blk s;
        };

        fn validate(_: @This(), _: *Logger) !void {}
    };

    pub const ShellMap = struct {
        data: [Shell.n_hooks]std.ArrayList(Shell),

        const Self = @This();

        fn init(allocator: Allocator) Self {
            return .{ .data = .{std.ArrayList(Shell).init(allocator)} ** Shell.n_hooks };
        }

        fn deinit(self: *Self) void {
            for (self.data) |d| d.deinit();
        }

        fn append(self: *Self, s: Shell) !void {
            try self.data[s.hook.to_int()].append(s);
        }

        pub fn has_hook(self: Self, hook: Shell.Hook) bool {
            return self.data[hook.to_int()].items.len > 0;
        }
    };

    pub fn initFromLua(cli: CLI, logger: *Logger, allocator: Allocator) !@This() {
        if (logger.verbose) try logger.newContext("parse lua config");

        var lua = try Lua.init(allocator);
        // defer lua.deinit();
        lua.openLibs();

        // we are running lua as basically a one-shot script, so we don't need the gc
        lua.gcStop();

        const package_load_string = try std.fmt.allocPrintZ(
            allocator,
            "package.path = '{s}/?.lua;' .. package.path",
            .{cli.lua_path},
        );
        try lua.doString(package_load_string);

        lua.doFile(cli.config_file) catch |err| {
            try logger.err("{s}", .{try lua.toString(-1)});
            return err;
        };
        var config = try parseFromLua(@This(), allocator, logger, lua);

        if (!cli.run_shell) config.shell = null;

        if (logger.verbose) try logger.contextFinish();
        return config;
    }

    fn checkDuplicates(
        self: @This(),
        comptime T: type,
        comptime outer_field: []const u8,
        comptime inner_field: []const u8,
        logger: *Logger,
    ) !void {
        for (0..@field(self, outer_field).len) |i| {
            for (0..@field(self, outer_field).len) |j| {
                if (i == j)
                    continue;

                switch (T) {
                    []const u8 => {
                        if (std.mem.eql(
                            u8,
                            @field(@field(self, outer_field)[i], inner_field),
                            @field(@field(self, outer_field)[j], inner_field),
                        )) {
                            try logger.err(
                                "Found duplicate entries for {s}[{}].{s} and {s}[{}].{s}.",
                                .{ outer_field, i + 1, inner_field, outer_field, j + 1, inner_field },
                            );
                            return error.LuaError;
                        }
                    },
                    else => {
                        try logger.err(
                            "Equality check for type {s} not implemented yet in checkDuplicates",
                            .{@typeName(T)},
                        );
                        return error.LuaError;
                    },
                }
            }
        }
    }

    fn validate(self: @This(), logger: *Logger) !void {
        try self.checkDuplicates([]const u8, "repos", "path", logger);
        try self.checkDuplicates([]const u8, "symlinks", "target", logger);
        try self.checkDuplicates([]const u8, "services", "name", logger);
        return;
    }
};

pub fn dumpToLua(comptime T: type, x: T, buffer: *std.ArrayList(u8), logger: *Logger) !void {
    inline for (std.meta.fields(T)) |field| {
        if (field.type != ?Config.ShellMap) {
            try buffer.appendSlice(field.name);
            try buffer.append('=');
        }
        switch (field.type) {
            []const u8 => {
                try buffer.append('"');
                try buffer.appendSlice(@field(x, field.name));
                try buffer.appendSlice("\",\n");
            },
            bool => {
                if (@field(x, field.name)) {
                    try buffer.appendSlice("true,\n");
                } else try buffer.appendSlice("false,\n");
            },
            []const []const u8 => {
                for (@field(x, field.name)) |s| {
                    try buffer.append('"');
                    try buffer.appendSlice(s);
                    try buffer.appendSlice("\",\n");
                }
            },
            ?Config.ShellMap => {
                // this is skipped, because shell commands aren't declarative
            },
            else => {
                const type_info = @typeInfo(field.type);
                switch (type_info) {
                    .Struct => {
                        try buffer.appendSlice("{\n");
                        try dumpToLua(field.type, @field(x, field.name), buffer, logger);
                        try buffer.appendSlice("},\n");
                    },
                    .Pointer => {
                        try buffer.appendSlice("{\n");

                        const elem_type: type = std.meta.Elem(field.type);
                        for (@field(x, field.name)) |y| {
                            try buffer.appendSlice("{\n");
                            try dumpToLua(elem_type, y, buffer, logger);
                            try buffer.appendSlice("},\n");
                        }

                        try buffer.appendSlice("},\n");
                    },
                    .Enum => {
                        try buffer.append('"');
                        try buffer.appendSlice(@tagName(@field(x, field.name)));
                        try buffer.appendSlice("\",\n");
                    },
                    else => {
                        try logger.err(
                            "Unable to dump type {s} to string",
                            .{@typeName(field.type)},
                        );
                        return error.LuaError;
                    },
                }
            },
        }
    }
}

pub fn parseFromLua(comptime T: type, allocator: Allocator, logger: *Logger, lua: *Lua) !T {
    if (lua.getTop() == 0) {
        return error.LuaError;
    }
    var x: T = undefined;
    inline for (std.meta.fields(T)) |field| {
        const lua_type = lua.getField(-1, field.name);
        defer lua.pop(1);
        if (lua_type == .nil) {
            if (field.default_value) |default| {
                @field(x, field.name) = @as(*const field.type, @alignCast(@ptrCast(default))).*;
            } else if (field.type == Allocator) {
                @field(x, field.name) = allocator;
            } else {
                try logger.err(
                    "Error while parsing type {s}. Field {s}.{s} cannot be nil.",
                    .{ @typeName(T), @typeName(T), field.name },
                );
                return error.LuaError;
            }
        } else {
            switch (field.type) {
                []const u8 => {
                    if (lua_type == .string) {
                        @field(x, field.name) = try lua.toString(-1);
                        if (@field(x, field.name).len == 0) {
                            try logger.err(
                                "Error while parsing {s}.{s}. Field cannot be an empty string.",
                                .{ @typeName(field.type), field.name },
                            );
                            return error.LuaError;
                        }
                    } else {
                        try logger.err(
                            "Error while parsing type {s}. Field {s} was set to type {s}, but expected type string.",
                            .{ @typeName(field.type), field.name, @tagName(lua_type) },
                        );
                        return error.LuaError;
                    }
                },

                bool => {
                    if (lua_type == .boolean) {
                        @field(x, field.name) = lua.toBoolean(-1);
                    } else {
                        try logger.err(
                            "Error while parsing type {s}. Field {s} was set to type {s}, but expected type boolean.",
                            .{ @typeName(field.type), field.name, @tagName(lua_type) },
                        );
                        return error.LuaError;
                    }
                },

                []const []const u8 => {
                    if (lua_type == .table) {
                        _ = lua.len(-1);
                        const n: usize = @intCast(try lua.toInteger(-1));
                        lua.pop(1);

                        const arr = try allocator.alloc([]const u8, n);
                        for (0..n) |i| {
                            _ = lua.getIndex(-1, @intCast(i + 1));
                            defer lua.pop(1);
                            arr[i] = try lua.toString(-1);
                        }
                        @field(x, field.name) = arr;
                    } else {
                        try logger.err(
                            "Error while parsing type {s}. Field {s} was set to type {s}, but expected type table.",
                            .{ @typeName(field.type), field.name, @tagName(lua_type) },
                        );
                        return error.LuaError;
                    }
                },

                ?Config.ShellMap => {
                    // NOTE: no need to explicitly handle .nil, since we already
                    // do that up top
                    if (lua_type == .table) {
                        _ = lua.len(-1);
                        const n: usize = @intCast(try lua.toInteger(-1));
                        lua.pop(1);

                        var sm: Config.ShellMap = Config.ShellMap.init(allocator);
                        for (0..n) |i| {
                            _ = lua.getIndex(-1, @intCast(i + 1));
                            defer lua.pop(1);
                            const s = try parseFromLua(Config.Shell, allocator, logger, lua);
                            try sm.append(s);
                        }
                        @field(x, field.name) = sm;
                    } else {
                        try logger.err(
                            "Error while parsing type {s}. Field {s} was set to type {s}, but expected type table.",
                            .{ @typeName(field.type), field.name, @tagName(lua_type) },
                        );
                        return error.LuaError;
                    }
                },

                else => {
                    const type_info = @typeInfo(field.type);
                    switch (type_info) {
                        // NOTE: I'm not sure whether I can test for slices specifically
                        .Pointer => {
                            if (lua_type == .table) {
                                const elem_type: type = std.meta.Elem(field.type);
                                _ = lua.len(-1);
                                const n: usize = @intCast(try lua.toInteger(-1));
                                lua.pop(1);

                                const arr = try allocator.alloc(elem_type, n);
                                for (0..n) |i| {
                                    _ = lua.getIndex(-1, @intCast(i + 1));
                                    defer lua.pop(1);
                                    arr[i] = try parseFromLua(elem_type, allocator, logger, lua);
                                }
                                @field(x, field.name) = arr;
                            } else {
                                try logger.err(
                                    "Error while parsing type {s}. Field {s} was set to type {s}, but expected type table.",
                                    .{ @typeName(field.type), field.name, @tagName(lua_type) },
                                );
                                return error.LuaError;
                            }
                        },
                        .Enum => {
                            if (lua_type == .string) {
                                const enum_str = try lua.toString(-1);
                                var found_match = false;
                                inline for (type_info.Enum.fields) |enum_field| {
                                    if (std.mem.eql(u8, enum_str, enum_field.name)) {
                                        @field(x, field.name) = @enumFromInt(enum_field.value);
                                        found_match = true;
                                    }
                                }
                                if (!found_match) {
                                    try logger.err(
                                        "Error while parsing enum {s} for field {s}. String {s} is not a variant of this enum.",
                                        .{ @typeName(field.type), field.name, enum_str },
                                    );
                                    return error.LuaError;
                                }
                            } else {
                                try logger.err(
                                    "Error while parsing type {s}. Field {s} was set to type {s}, but expected type string.",
                                    .{ @typeName(field.type), field.name, @tagName(lua_type) },
                                );
                                return error.LuaError;
                            }
                        },
                        .Struct => {
                            if (lua_type == .table) {
                                @field(x, field.name) = try parseFromLua(field.type, allocator, logger, lua);
                            } else {
                                try logger.err(
                                    "Error while parsing type {s}. Field {s} was set to type {s}, but expected type table.",
                                    .{ @typeName(field.type), field.name, @tagName(lua_type) },
                                );
                                return error.LuaError;
                            }
                        },
                        else => {
                            try logger.err(
                                "Unparsable file type: {s}",
                                .{@typeName(field.type)},
                            );
                            return error.LuaError;
                        },
                    }
                },
            }
        }
    }
    try x.validate(logger);
    return x;
}

fn test_runner(allocator: Allocator, quiet: bool, lua_string: [:0]const u8) !Config {
    var logger = Logger.init(.{ .very_quiet = quiet }, allocator);
    var lua = try Lua.init(allocator);
    lua.openLibs();
    try lua.doString(lua_string);
    return parseFromLua(Config, allocator, &logger, lua);
}

test "empty file" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    const allocator = arena.allocator();
    defer _ = arena.deinit();
    try std.testing.expectError(error.LuaError, test_runner(allocator, true, ""));
}

test "empty table" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    const allocator = arena.allocator();
    defer _ = arena.deinit();
    try std.testing.expectEqualDeep(Config{}, test_runner(allocator, true, "return {}"));
}

test "parse symlinks successful" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    const allocator = arena.allocator();
    defer _ = arena.deinit();
    const symlinks: []const Config.Symlink = &.{
        .{ .source = "foo", .target = "bar", .absent = false },
        .{ .source = "foo", .target = "baz", .absent = true },
        .{ .source = "", .target = "faz", .absent = true },
    };
    try std.testing.expectEqualDeep(
        Config{ .symlinks = @constCast(symlinks) },
        test_runner(allocator, false,
            \\ return { symlinks = {
            \\     { source = "foo", target = "bar", absent = false },
            \\     { source = "foo", target = "baz", absent = true },
            \\     { target = "faz", absent = true },
            \\ }}
            \\
        ),
    );
}

test "empty strings without default" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    const allocator = arena.allocator();
    defer _ = arena.deinit();
    try std.testing.expectError(
        error.LuaError,
        test_runner(allocator, true,
            \\ return { symlinks = {
            \\     { source = "foo", target = "", absent = false },
            \\ }}
            \\
        ),
    );
}

test "symlink missing fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    const allocator = arena.allocator();
    defer _ = arena.deinit();
    try std.testing.expectError(
        error.LuaError,
        test_runner(allocator, true,
            \\ return { symlinks = {
            \\     { source = "foo", absent = false },
            \\ }}
            \\
        ),
    );

    try std.testing.expectError(
        error.LuaError,
        test_runner(allocator, true,
            \\ return { symlinks = {
            \\     { target = "foo", absent = false },
            \\ }}
            \\
        ),
    );
}

test "parse repos successful" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    const allocator = arena.allocator();
    defer _ = arena.deinit();
    const repos: []const Config.Repo = &.{
        .{ .remote = "foo", .path = "bar" },
        .{ .remote = "baz", .path = "far" },
    };
    try std.testing.expectEqualDeep(
        Config{ .repos = @constCast(repos) },
        test_runner(allocator, false,
            \\ return { repos = {
            \\   { remote = "foo", path = "bar" },
            \\   { remote = "baz", path = "far" },
            \\ }}
            \\
        ),
    );
}

test "parse services successful" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    const allocator = arena.allocator();
    defer _ = arena.deinit();
    const services: []const Config.Service = &.{
        .{ .name = "foo.service", .level = .user, .state = .enabled },
        .{ .name = "bar.service", .level = .user, .state = .disabled },
        .{ .name = "baz.service", .level = .root, .state = .restarted },
    };
    try std.testing.expectEqualDeep(
        Config{ .services = @constCast(services) },
        test_runner(allocator, false,
            \\ return { services = {
            \\   { name = "foo.service", level = "user", state = "enabled" },
            \\   { name = "bar.service", state = "disabled" },
            \\   { name = "baz.service", level = "root", state = "restarted" },
            \\ }}
            \\
        ),
    );
}

test "hook to int and back" {
    inline for (@typeInfo(Config.Shell.Hook.What).Enum.fields) |what| {
        inline for (@typeInfo(Config.Shell.Hook.When).Enum.fields) |when| {
            const hook = Config.Shell.Hook{ .what = @enumFromInt(what.value), .when = @enumFromInt(when.value) };
            const hook_int = hook.to_int();
            try std.testing.expectEqual(hook, Config.Shell.Hook.from_int(hook_int));
        }
    }
}

test "parse shell successful" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    const allocator = arena.allocator();
    defer _ = arena.deinit();
    var shellmap = Config.ShellMap.init(allocator);
    const cmds: []const Config.Shell = &.{
        .{
            .cmd = &.{"ls"},
            .level = .user,
            .hook = .{ .when = .after, .what = .main },
        },
        .{
            .cmd = &.{ "echo", "hey", "there" },
            .hook = .{ .when = .before, .what = .pkgs },
        },
        .{
            .cmd = &.{ "ls", "/" },
            .level = .root,
            .hook = .{ .when = .before, .what = .main },
        },
    };
    for (cmds) |c| {
        try shellmap.append(c);
    }
    try std.testing.expectEqualDeep(
        Config{ .shell = shellmap },
        test_runner(allocator, false,
            \\ return { shell = {
            \\ {
            \\     cmd = {"ls"},
            \\     level = "user",
            \\     hook = { when = "after", what = "main" },
            \\ },
            \\ {
            \\     cmd = { "echo", "hey", "there" },
            \\     hook = { when = "before", what = "pkgs" },
            \\ },
            \\ {
            \\     cmd = { "ls", "/" },
            \\     level = "root",
            \\     hook = { when = "before", what = "main" },
            \\ },
            \\ }}
            \\
        ),
    );
}
