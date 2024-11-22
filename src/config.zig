const std = @import("std");
const Lua = @import("ziglua").Lua;
const Args = @import("args.zig").Args;
const Logger = @import("logger.zig").Logger;
const Allocator = std.mem.Allocator;

pub const Config = struct {
    symlinks: []Symlink = &[_]Symlink{},
    repos: []Repo = &[_]Repo{},

    pub const Symlink = struct {
        source: []const u8 = "",
        target: []const u8,
        absent: bool = false,

        fn validate(self: @This(), logger: *Logger) !void {
            var found_error = false;
            if (self.source.len == 0 and !self.absent) {
                found_error = true;
                try logger.err("Symlink.source cannot be empty, unless Symlink.absent == true.", .{});
                return error.LuaError;
            }
        }
    };

    pub const Repo = struct {
        remote: []const u8,
        path: []const u8,

        fn validate(_: @This(), _: *Logger) !void {
            return;
        }
    };

    pub fn init(args: Args, logger: *Logger, allocator: Allocator) !@This() {
        if (logger.verbose) try logger.newContext("parse lua config");

        var lua = try Lua.init(allocator);
        lua.openLibs();

        try lua.doString(try std.fmt.allocPrintZ(
            allocator,
            "package.path = '{s}/?.lua;' .. package.path",
            .{args.lua_path},
        ));

        // we are running lua as basically a one-shot script, so we don't need the gc
        lua.gcStop();

        lua.doFile(args.config_file) catch |err| {
            try logger.err("{s}", .{try lua.toString(-1)});
            return err;
        };
        const config = try parseFromLua(@This(), allocator, logger, lua);

        if (logger.verbose) try logger.contextFinish();
        return config;
    }

    fn validate(_: @This(), _: *Logger) !void {
        // TODO:
        //   - no duplicate symlink targets
        //   - no duplicate repo paths
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

                else => {
                    // this might be an array...
                    if (@typeName(field.type)[0] == '[' and @typeName(field.type)[1] == ']') {
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
                            "Unparsable file type: {s}",
                            .{@typeName(field.type)},
                        );
                        return error.LuaError;
                    }
                },
            }
        }
    }
    try x.validate(logger);
    return x;
}

fn test_runner(allocator: Allocator, lua_string: [:0]const u8) !Config {
    var logger = Logger.init(.{}, allocator);
    var lua = try Lua.init(allocator);
    lua.openLibs();
    try lua.doString(lua_string);
    return parseFromLua(Config, allocator, &logger, lua);
}

test "empty file" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    const allocator = arena.allocator();
    defer _ = arena.deinit();
    try std.testing.expectError(error.LuaError, test_runner(allocator, ""));
}

test "empty table" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    const allocator = arena.allocator();
    defer _ = arena.deinit();
    try std.testing.expectEqualDeep(Config{}, test_runner(allocator, "return {}"));
}

test "parse symlinks successful" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    const allocator = arena.allocator();
    defer _ = arena.deinit();
    const symlinks: []const Config.Symlink = &.{
        .{ .source = "foo", .target = "bar", .absent = false },
        .{ .source = "foo", .target = "bar", .absent = true },
        .{ .source = "", .target = "bar", .absent = true },
    };
    try std.testing.expectEqualDeep(
        Config{ .symlinks = @constCast(symlinks) },
        test_runner(allocator,
            \\ return { symlinks = {
            \\     { source = "foo", target = "bar", absent = false },
            \\     { source = "foo", target = "bar", absent = true },
            \\     { target = "bar", absent = true },
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
        test_runner(allocator,
            \\ return { symlinks = {
            \\     { source = "foo", absent = false },
            \\ }}
            \\
        ),
    );

    try std.testing.expectError(
        error.LuaError,
        test_runner(allocator,
            \\ return { symlinks = {
            \\     { target = "foo", absent = false },
            \\ }}
            \\
        ),
    );
}
