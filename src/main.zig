const std = @import("std");
const Args = @import("args.zig").Args;
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

    std.debug.print("isTable = {}\n", .{lua.isTable(-1)});
    _ = lua.getField(-1, "foo");
    std.debug.print("foo isTable = {}\n", .{lua.isTable(-1)});
    _ = lua.getField(-1, "bar");
    std.debug.print("bar isInteger = {}\n", .{lua.isInteger(-1)});
    const bar = lua.toInteger(-1);
    std.debug.print("bar = {any}\n", .{bar});
    lua.pop(2);

    _ = lua.getField(-1, "symlinks");
    std.debug.print("symlinks isTable = {}\n", .{lua.isTable(-1)});
    _ = lua.len(-1);
    std.debug.print("symlinks.len = {any}\n", .{lua.toInteger(-1)});
}
