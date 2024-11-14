const Args = @import("args.zig").Args;
const Config = @import("config.zig").Config;
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Command = enum {
    repos,
    pkgs,
    config,
    sync,
    ln,
};

pub fn run_commands(args: Args, config: Config, allocator: Allocator) !void {
    for (args.commands) |c| {
        if (args.verbose) {
            const writer = std.io.getStdOut().writer();
            try writer.print("Running command: {}\n", .{c});
        }
        switch (c) {
            .ln => try ln(config.symlinks, allocator),
            else => @panic("bar"),
        }
    }
}

fn ln(symlinks: []Config.Symlink, allocator: Allocator) !void {
    for (symlinks) |sl| {
        std.debug.print(
            "source: {s}\ntarget: {s}\nforce: {}\n",
            .{ sl.source, sl.target, sl.force },
        );
        const res = try std.process.Child.run(.{ .allocator = allocator, .argv = &[_][]const u8{
            "ln",
            if (sl.force) "-sf" else "-s",
            sl.source,
            sl.target,
        } });
        std.debug.print(
            "exitcode = {}\nstdout = {s}\nstderr = {s}",
            .{ res.term.Exited, res.stdout, res.stderr },
        );
    }
}
