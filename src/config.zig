const std = @import("std");
const Lua = @import("ziglua").Lua;
const Args = @import("args.zig").Args;
const Logger = @import("logger.zig").Logger;
const Allocator = std.mem.Allocator;

pub const Config = struct {
    symlinks: []Symlink = undefined,

    pub const Symlink = struct {
        source: []const u8 = "",
        target: []const u8 = "",
        force: bool = false,
    };

    pub fn init(args: Args, logger: *Logger, allocator: Allocator) !Config {
        if (logger.verbose)
            try logger.newContext("parse lua config");

        var lua = try Lua.init(allocator);
        lua.openLibs();

        // we are running lua as basically a one-shot script, so we don't need the gc
        lua.gcStop();

        lua.doFile(args.config_file) catch |err| {
            try logger.log(.Error, "{s}", .{try lua.toString(-1)});
            return err;
        };
        lua.setGlobal("config");
        setDefaults(lua) catch |err| {
            try logger.log(.Error, "{s}", .{try lua.toString(-1)});
            return err;
        };
        const config = try parseFromLua(Config, allocator, logger, lua);

        if (logger.verbose)
            try logger.contextFinish();

        return config;
    }
};

pub fn setDefaults(lua: *Lua) !void {
    // it's way easier to do checks and to set defaults on the config in lua
    try lua.doString(@embedFile("./postprocess_config.lua"));
}

pub fn parseFromLua(comptime t: type, allocator: Allocator, logger: *Logger, lua: *Lua) !t {
    // IDEA: using @embed, I can probably define the structure of Config in a
    // separate file that I can parse into both lua and zig to have a single
    // definition for Config that is used by both languages. That would be so
    // sick...
    var x = t{};
    inline for (std.meta.fields(t)) |field| {
        _ = lua.getField(-1, field.name);
        defer lua.pop(1);
        switch (field.type) {
            []const u8 => @field(x, field.name) = try lua.toString(-1),
            bool => @field(x, field.name) = lua.toBoolean(-1),

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
                    try logger.log(
                        .Error,
                        "Unparsable file type: {s}",
                        .{@typeName(field.type)},
                    );
                    return error.LuaError;
                }
            },
        }
    }
    return x;
}
