const Args = @import("args.zig").Args;
const Config = @import("config.zig").Config;
const Logger = @import("logger.zig").Logger;
const std = @import("std");
const Child = std.process.Child;
const Allocator = std.mem.Allocator;

pub const Command = enum {
    sync,
    ln,
    repos,
    // pkgs,
    // config,
    // shell
};

pub fn run_commands(args: Args, config: Config, allocator: Allocator, logger: *Logger) !void {
    for (args.commands) |c| {
        switch (c) {
            .ln => try ln(config.symlinks, args.dry_run, allocator, logger),
            .repos => try repos(config.repos, args.dry_run, allocator, logger),
            .sync => {
                try logger.newContext("sync");
                defer logger.contextFinish() catch {};
                try ln(config.symlinks, args.dry_run, allocator, logger);
                try repos(config.repos, args.dry_run, allocator, logger);
            },
        }
    }
}

fn ln(symlinks: []Config.Symlink, dry_run: bool, allocator: Allocator, logger: *Logger) !void {
    try logger.newContext(@src().fn_name);
    defer logger.contextFinish() catch {};
    if (symlinks.len == 0) return;

    for (symlinks) |sl| {
        if (sl.absent) {
            if (logger.verbose)
                try logger.info("Removing symlink: {s}", .{sl.target});

            const cwd = std.fs.cwd();
            if (cwd.statFile(sl.target)) |_| {
                var buffer: [256]u8 = undefined;
                _ = cwd.readLink(sl.target, &buffer) catch |err| switch (err) {
                    error.NotLink => {
                        try logger.err(
                            "File is not a symlink: {s}; Ignoring.",
                            .{sl.target},
                        );
                        continue;
                    },
                    else => {
                        try logger.err(
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
                        try logger.info(
                            "File already absent: {s}",
                            .{sl.target},
                        );
                    continue;
                },
                else => return err,
            }
        } else {
            if (logger.verbose)
                try logger.info("{s} -> {s}", .{ sl.source, sl.target });
            if (!dry_run) {
                try std.fs.cwd().makePath(std.fs.path.dirname(sl.target).?);
                try std.fs.atomicSymLink(allocator, sl.source, sl.target);
            }
        }
    }
}

const CommandError = error{
    ChildProcessError,
};

fn generic_run(args: anytype, logger: *Logger) !Child.RunResult {
    const res = Child.run(args) catch |err| {
        const process_name = try std.mem.concat(args.allocator, u8, args.argv);
        try logger.err(
            "Unable to spawn process '{s}'. error: {any}",
            .{ process_name, err },
        );
        return err;
    };
    if (res.term.Exited > 0) {
        const process_name = try std.mem.concat(args.allocator, u8, args.argv);
        try logger.err(
            "Encountered error while running '{s}'. exit code: {}; stderr: {s}",
            .{ process_name, res.term.Exited, res.stderr },
        );
        return error.ChildProcessError;
    }
    return res;
}

fn repos(repositories: []Config.Repo, _: bool, allocator: Allocator, logger: *Logger) !void {
    try logger.newContext(@src().fn_name);
    defer logger.contextFinish() catch {};
    if (repositories.len == 0) return;

    // TODO: run this in separate threads
    // TODO: extract all these processes into a separate function, because I
    // handle all of them pretty much the same
    for (repositories) |repo| {
        const dir = std.fs.openDirAbsolute(repo.path, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                _ = generic_run(.{
                    .allocator = allocator,
                    .argv = &.{ "git", "clone", repo.remote, repo.path },
                }, logger) catch {};
                continue;
            },
            else => return err,
        };

        const git_remote = generic_run(.{
            .allocator = allocator,
            .argv = &.{ "git", "remote", "-v" },
            .cwd_dir = dir,
        }, logger) catch continue;

        if (git_remote.stdout.len == 0) {
            try logger.err(
                "Found git repository at {s}, but it has no remotes set up",
                .{repo.path},
            );
            continue;
        }

        const remote_starts_at = std.mem.indexOf(u8, git_remote.stdout, "\t").? + 1;
        if (!std.mem.startsWith(u8, git_remote.stdout[remote_starts_at..], repo.remote)) {
            try logger.err(
                "Found git repository at {s}, but it is pointing not pointing at remote {s}. 'git remote -v' output:\n{s}",
                .{
                    repo.path,
                    repo.remote,
                    git_remote.stdout,
                },
            );
            continue;
        }

        const git_status = generic_run(.{
            .allocator = allocator,
            .argv = &.{ "git", "status", "--porcelain=v1" },
            .cwd_dir = dir,
        }, logger) catch continue;
        if (git_status.stdout.len > 1) {
            try logger.warn(
                "Repo at {s} contains uncommited changes. Skipping pull.",
                .{repo.path},
            );
            continue;
        }

        const git_pull = generic_run(.{
            .allocator = allocator,
            .argv = &.{ "git", "pull" },
            .cwd_dir = dir,
        }, logger) catch continue;
        try logger.info("git pull @{s} stdout: {s}", .{ repo.path, git_pull.stdout[0 .. git_pull.stdout.len - 2] });
    }
}
