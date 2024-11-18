const Args = @import("args.zig").Args;
const Config = @import("config.zig").Config;
const Logger = @import("logger.zig").Logger;
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Command = enum {
    repos,
    pkgs,
    config,
    sync,
    ln,
};

pub fn run_commands(args: Args, config: Config, allocator: Allocator, logger: *Logger) !void {
    for (args.commands) |c| {
        switch (c) {
            .ln => try ln(config.symlinks, allocator, logger),
            .sync => {
                try logger.newContext("sync");
                defer logger.contextFinish() catch {};
                try ln(config.symlinks, allocator, logger);
            },
            else => unreachable,
        }
    }
}

fn ln(symlinks: []Config.Symlink, allocator: Allocator, logger: *Logger) !void {
    try logger.newContext(@src().fn_name);
    defer logger.contextFinish() catch {};

    for (symlinks) |sl| {
        var res: std.process.Child.RunResult = undefined;
        if (sl.absent) {
            res = try std.process.Child.run(.{ .allocator = allocator, .argv = &[_][]const u8{
                "unlink",
                sl.target,
            } });
        } else {
            try std.fs.cwd().makePath(std.fs.path.dirname(sl.target).?);
            res = try std.process.Child.run(.{ .allocator = allocator, .argv = &[_][]const u8{
                "ln",
                if (sl.force) "-sfv" else "-sv",
                sl.source,
                sl.target,
            } });
            if (logger.verbose)
                try logger.log(.Info, "{s}", .{res.stdout[0 .. res.stdout.len - 1]});
        }
        if (res.term.Exited != 0) {
            try logger.log(
                .Error,
                "exitcode = {}; stderr: {s}",
                .{ res.term.Exited, res.stderr },
            );
            logger.saw_error = true;
        }
    }
}
