const std = @import("std");
const Args = @import("args.zig").Args;
const Config = @import("config.zig").Config;
const Logger = @import("logger.zig").Logger;
const run_commands = @import("commands.zig").run_commands;

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const allocator = arena.allocator();
    defer _ = arena.deinit();

    const home = try std.process.getEnvVarOwned(allocator, "HOME");
    const args = try Args.init(allocator, home);
    if (args.help) return;

    var logger = Logger.init(args, allocator);
    try logger.newContext(@src().fn_name);
    if (logger.verbose) {
        try logger.info("Using syke config file: {s}", .{args.config_file});
        try logger.info("Running commands: {any}", .{args.commands});
    }

    const conf = try Config.init(args, &logger, allocator);

    try run_commands(args, conf, allocator, &logger);

    try logger.contextFinish();
}

test "main" {
    std.testing.refAllDeclsRecursive(@This());
}
