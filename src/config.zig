const std = @import("std");
const Lua = @import("ziglua").Lua;
const Args = @import("args.zig").Args;
const Logger = @import("logger.zig").Logger;
const Allocator = std.mem.Allocator;

pub const Config = struct {
    symlinks: []Symlink = &[_]Symlink{},
    repos: []Repo = &[_]Repo{},
    services: []Service = &[_]Service{},
    // shell: []Shell = &[_]Shell{},
    shell: ?[Shell.n_hooks]std.ArrayList(Shell) = null,
    // current_ctx_stack: std.ArrayList(Ctx),

    pub const Symlink = struct {
        source: []const u8 = "",
        target: []const u8,
        absent: bool = false,

        fn validate(self: @This(), logger: *Logger) !void {
            var found_error = false;
            if (self.source.len == 0 and !self.absent) {
                found_error = true;
                try logger.err(
                    "symlinks[*].source cannot be empty, unless Symlink.absent == true.",
                    .{},
                );
                return error.LuaError;
            }
        }
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
        const Hook = struct {
            when: When = .after,
            what: What = .main,
            const When = enum { before, after };
            const What = enum { main, ln, repos, services, commands, pkgs, text };

            fn validate(_: @This(), _: *Logger) !void {}

            fn to_int(self: @This()) usize {
                return @intFromEnum(self.when) | (@intFromEnum(self.what) << 1);
            }
            fn from_int(x: usize) @This() {
                // 111....1110
                const foo = @bitReverse(@as(usize, 0)) ^ 1;
                const when: When = @enumFromInt(foo & x);
                const what: What = @enumFromInt(x >> 1);
                return .{ .when = when, .what = what };
            }
        };

        const n_hooks: usize = @typeInfo(Hook.What).Enum.fields.len * @typeInfo(Hook.When).Enum.fields.len;

        fn validate(_: @This(), _: *Logger) !void {}
    };

    pub fn init(args: Args, logger: *Logger, allocator: Allocator) !@This() {
        if (logger.verbose) try logger.newContext("parse lua config");

        var lua = try Lua.init(allocator);
        // defer lua.deinit();
        lua.openLibs();

        // we are running lua as basically a one-shot script, so we don't need the gc
        lua.gcStop();

        const package_load_string = try std.fmt.allocPrintZ(
            allocator,
            "package.path = '{s}/?.lua;' .. package.path",
            .{args.lua_path},
        );
        try lua.doString(package_load_string);

        lua.doFile(args.config_file) catch |err| {
            try logger.err("{s}", .{try lua.toString(-1)});
            return err;
        };
        var config = try parseFromLua(@This(), allocator, logger, lua);

        if (!args.run_shell) config.shell = null;

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

pub fn parseFromLua(comptime t: type, allocator: Allocator, logger: *Logger, lua: *Lua) !t {
    if (lua.getTop() == 0) {
        return error.LuaError;
    }
    var x: t = undefined;
    inline for (std.meta.fields(t)) |field| {
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
                    .{ @typeName(t), @typeName(t), field.name },
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

                ?[Config.Shell.n_hooks]std.ArrayList(Config.Shell) => {
                    // NOTE: no need to explicitly handle .nil, since we already
                    // do that up top
                    if (lua_type == .table) {
                        _ = lua.len(-1);
                        const n: usize = @intCast(try lua.toInteger(-1));
                        lua.pop(1);

                        var arr: [Config.Shell.n_hooks]std.ArrayList(Config.Shell) = .{std.ArrayList(Config.Shell).init(allocator)} ** Config.Shell.n_hooks;
                        for (0..n) |i| {
                            _ = lua.getIndex(-1, @intCast(i + 1));
                            defer lua.pop(1);
                            const s = try parseFromLua(Config.Shell, allocator, logger, lua);
                            const hook_idx = @intFromEnum(s.hook.when) | (@intFromEnum(s.hook.what) << 1);
                            try arr[hook_idx].append(s);
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

// test "parse shell successful" {
//     var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
//     const allocator = arena.allocator();
//     defer _ = arena.deinit();
//     const cmds: []const Config.Shell = &.{
//         .{
//             .cmd = &.{"ls"},
//             .level = .user,
//             .hook = .{ .when = .after, .what = .main },
//         },
//         .{
//             .cmd = &.{ "echo", "hey", "there" },
//             .hook = .{ .when = .before, .what = .pkgs },
//         },
//         .{
//             .cmd = &.{ "ls", "/" },
//             .level = .root,
//             .hook = .{ .when = .before, .what = .main },
//         },
//     };
//     try std.testing.expectEqualDeep(
//         Config{ .shell = @constCast(cmds) },
//         test_runner(allocator, false,
//             \\ return { shell = {
//             \\ {
//             \\     cmd = {"ls"},
//             \\     level = "user",
//             \\     hook = { when = "after", what = "main" },
//             \\ },
//             \\ {
//             \\     cmd = { "echo", "hey", "there" },
//             \\     hook = { when = "before", what = "pkgs" },
//             \\ },
//             \\ {
//             \\     cmd = { "ls", "/" },
//             \\     level = "root",
//             \\     hook = { when = "before", what = "main" },
//             \\ },
//             \\ }}
//             \\
//         ),
//     );
// }
