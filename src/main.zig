const std = @import("std");
const Args = @import("args.zig").Args;
const Config = @import("config.zig").Config;
const run_commands = @import("commands.zig").run_commands;

pub fn main() anyerror!void {
    // just use an arena, since this is a one-shot program without any internal
    // loops and pretty predictable allocations.
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const allocator = arena.allocator();
    defer _ = arena.deinit();

    const args = try Args.init(allocator);
    if (args.help) {
        return;
    }

    if (args.verbose) {
        const writer = std.io.getStdOut().writer();
        try writer.print("Using syke config file: {s}\n", .{args.config_file});
        try writer.print("Running commands: {any}\n", .{args.commands});
    }

    const conf = try Config.init(args, allocator);

    try run_commands(args, conf);
}
