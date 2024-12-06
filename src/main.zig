const std = @import("std");
const CLI = @import("cli.zig").CLI;
const Config = @import("config.zig").Config;
const Logger = @import("logger.zig").Logger;
const run_commands = @import("commands.zig").run_commands;

// TODO:
//   - ln absent does not seem to work
//   - make ln completely declarative (needs some way to store the current config somewhere)
//   - introduce my own error set
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
    const cli = try CLI.init(allocator, home);
    if (cli.help) return;

    var logger = Logger.init(cli, allocator);
    try logger.newContext(@src().fn_name);
    if (logger.verbose) {
        try logger.info("Using syke config file: {s}", .{cli.config_file});
        try logger.info("Running commands: {any}", .{cli.commands});
    }

    const conf = try Config.init(cli, &logger, allocator);

    try run_commands(cli, conf, allocator, &logger);

    try logger.contextFinish();
}

test "main" {
    std.testing.refAllDeclsRecursive(@This());
}
