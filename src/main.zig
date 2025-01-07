const std = @import("std");
const CLI = @import("cli.zig").CLI;
const ConfigGen = @import("config.zig").ConfigGen;
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

    var conf_gen = try ConfigGen.initFromLua(cli, &logger, allocator);
    const last_conf_gen = try ConfigGen.initFromLastGen(cli, &logger, allocator);
    std.debug.print("last gen:\n{any}\n\n", .{last_conf_gen.conf});

    conf_gen.gen = last_conf_gen.gen + 1;

    try run_commands(cli, conf_gen.conf, last_conf_gen.conf, allocator, &logger);

    const current_gen_string = try conf_gen.dumpToStringLua(&logger, allocator);
    const new_gen_file_path = try std.fmt.allocPrint(
        allocator,
        "{s}/{s}/{s}_{}",
        .{ home, "/.local/cache/syke/", "foo", conf_gen.gen },
    );
    const new_gen_file = try std.fs.cwd().createFile(new_gen_file_path, .{});
    defer new_gen_file.close();
    try new_gen_file.writeAll(current_gen_string);

    std.debug.print("{s}", .{current_gen_string});

    try logger.contextFinish();
}

test "main" {
    std.testing.refAllDeclsRecursive(@This());
}
