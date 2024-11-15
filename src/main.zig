const std = @import("std");
const Args = @import("args.zig").Args;
const Config = @import("config.zig").Config;
const Logger = @import("logger.zig").Logger;
const run_commands = @import("commands.zig").run_commands;

pub fn main() anyerror!void {
    // just use an arena, since this is a one-shot program without any internal
    // loops and pretty predictable allocations.
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const allocator = arena.allocator();
    defer _ = arena.deinit();

    const home = try std.process.getEnvVarOwned(allocator, "HOME");
    const args = try Args.init(allocator, home);
    if (args.help) {
        return;
    }

    var logger = Logger.init(args, allocator);
    if (logger.verbose) {
        try logger.newContext(@src().fn_name);
        try logger.log(.Info, "Using syke config file: {s}", .{args.config_file});
        try logger.log(.Info, "Running commands: {any}", .{args.commands});
    }

    const conf = try Config.init(args, &logger, allocator);

    try run_commands(args, conf, allocator, &logger);

    if (logger.verbose)
        try logger.contextFinish();
}
