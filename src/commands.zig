const Args = @import("args.zig").Args;
const Config = @import("config.zig").Config;
const std = @import("std");

pub const Command = enum {
    repos,
    pkgs,
    config,
    sync,
    ln,
};

pub fn run_commands(args: Args, config: Config) !void {
    for (args.commands) |c| {
        if (args.verbose) {
            const writer = std.io.getStdOut().writer();
            try writer.print("Running command: {}\n", .{c});
        }
        switch (c) {
            .ln => ln(config.symlinks),
            else => @panic("bar"),
        }
    }
}

fn ln(symlinks: []Config.Symlink) void {
    for (symlinks) |sl| {
        std.debug.print("source: {s}\ntarget: {s}\nforce: {}\n", .{ sl.source, sl.target, sl.force });
    }
}
