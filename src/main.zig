const std = @import("std");
const Args = @import("args.zig").Args;
const Config = @import("config.zig").Config;
const ziglua = @import("ziglua");

const Lua = ziglua.Lua;

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

    const config = try Config.fromLua(allocator, lua);
    defer config.deinit();
    for (config.symlinks) |s| {
        s.execute();
    }
}
