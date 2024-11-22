const std = @import("std");
const Args = @import("args.zig").Args;
const Config = @import("config.zig").Config;
const Logger = @import("logger.zig").Logger;
const run_commands = @import("commands.zig").run_commands;

// TODO:
//   - put shell commands into a [][]Shell, where the outer slice tells you the
//     hook (combining .when and .what into a single usize), and inner slice is
//     the list of commands to run at that hook position
//   - measure the memory footprint of syke, and if it IS bad, limit memory
//     usage by using a regular GPA throughout most of the program, and then use
//     an arena in some parts where it's practical
//   - impl text file manipulation
//   - impl pkg management:
//     - homebrew
//     - pacman
//     - paru

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
    std.debug.print("{any}\n", .{conf.shell});

    try run_commands(args, conf, allocator, &logger);

    try logger.contextFinish();
}

test "main" {
    std.testing.refAllDeclsRecursive(@This());
}
