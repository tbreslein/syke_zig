const std = @import("std");
const Args = @import("args.zig").Args;
const config = @import("config.zig");
const run_commands = @import("commands.zig").run_commands;
const Lua = @import("ziglua").Lua;

pub fn main() anyerror!void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    const args = try Args.init(allocator);
    defer args.deinit();
    if (args.help) {
        return;
    }

    if (args.verbose) {
        const writer = std.io.getStdOut().writer();
        try writer.print("Using syke config file: {s}\n", .{args.config_file});
        try writer.print("Running commands: {any}\n", .{args.commands});
    }

    var lua = try Lua.init(allocator);
    defer lua.deinit();

    lua.doFile(args.config_file) catch |err| {
        try std.io.getStdErr().writer().print("ERROR: {s}\n", .{try lua.toString(-1)});
        return err;
    };
    lua.setGlobal("config");
    setDefaults(lua) catch |err| {
        try std.io.getStdErr().writer().print("ERROR: {s}\n", .{try lua.toString(-1)});
        return err;
    };

    const conf = try config.parseFromLua(config.Config, allocator, lua);
    defer conf.deinit();

    try run_commands(args, conf);
}

pub fn setDefaults(lua: *Lua) !void {
    lua.openBase();
    // it's way easier to do checks and to set defaults on the config in lua
    try lua.doString(@embedFile("./postprocess_config.lua"));
}
