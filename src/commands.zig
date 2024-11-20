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
            .ln => try ln(config.symlinks, args.dry_run, allocator, logger),
            .sync => {
                try logger.newContext("sync");
                defer logger.contextFinish() catch {};
                try ln(config.symlinks, args.dry_run, allocator, logger);
            },
            else => unreachable,
        }
    }
}

fn ln(symlinks: []Config.Symlink, dry_run: bool, allocator: Allocator, logger: *Logger) !void {
    try logger.newContext(@src().fn_name);
    defer logger.contextFinish() catch {};

    for (symlinks) |sl| {
        if (sl.absent) {
            if (logger.verbose)
                try logger.log(.Info, "Removing symlink: {s}", .{sl.target});

            const cwd = std.fs.cwd();
            if (cwd.statFile(sl.target)) |_| {
                var buffer: [256]u8 = undefined;
                _ = cwd.readLink(sl.target, &buffer) catch |err| switch (err) {
                    error.NotLink => {
                        try logger.log(
                            .Error,
                            "File is not a symlink: {s}; Ignoring.",
                            .{sl.target},
                        );
                        logger.saw_error = true;
                        continue;
                    },
                    else => {
                        try logger.log(
                            .Error,
                            "Unexpected error while trying to remove symlink: {s}; error = {}",
                            .{ sl.target, err },
                        );
                        return err;
                    },
                };
                if (!dry_run)
                    try cwd.deleteFile(sl.target);
            } else |err| switch (err) {
                error.FileNotFound => {
                    if (logger.verbose)
                        try logger.log(
                            .Info,
                            "File already absent: {s}",
                            .{sl.target},
                        );
                    continue;
                },
                else => return err,
            }
        } else {
            if (logger.verbose)
                try logger.log(.Info, "{s} -> {s}", .{ sl.source, sl.target });
            if (!dry_run) {
                try std.fs.cwd().makePath(std.fs.path.dirname(sl.target).?);
                try std.fs.atomicSymLink(allocator, sl.source, sl.target);
            }
        }
    }
}
