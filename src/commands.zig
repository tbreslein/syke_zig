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
    shell,
    // pkgs,
    // text,
    // services,
};

pub fn run_commands(args: Args, config: Config, allocator: Allocator, logger: *Logger) !void {
    try run_hook(config.shell, .{ .when = .before, .what = .main }, args.dry_run, allocator, logger);

    for (args.commands) |c| {
        switch (c) {
            .ln => try ln(config.symlinks, config.shell, args.dry_run, allocator, logger),
            .repos => try repos(config.repos, config.shell, args.dry_run, allocator, logger),
            .shell => {},
            .sync => {
                try logger.newContext("sync");
                defer logger.contextFinish() catch {};
                try ln(config.symlinks, config.shell, args.dry_run, allocator, logger);
                try repos(config.repos, config.shell, args.dry_run, allocator, logger);
            },
        }
    }

    try run_hook(config.shell, .{ .when = .after, .what = .main }, args.dry_run, allocator, logger);
}

const CommandError = error{
    ChildProcessError,
};

fn run_hook(shell_map: ?Config.ShellMap, hook: Config.Shell.Hook, dry_run: bool, allocator: Allocator, logger: *Logger) !void {
    if (shell_map == null or !shell_map.?.has_hook(hook))
        return;

    for (shell_map.?.data[hook.to_int()].items) |s|
        try shell(s, dry_run, allocator, logger);
}

fn generic_run(args: anytype, logger: *Logger) !Child.RunResult {
    const res = Child.run(args) catch |err| {
        const process_name = try std.mem.join(args.allocator, " ", args.argv);
        try logger.err(
            "Unable to spawn process '{s}'. error: {any}",
            .{ process_name, err },
        );
        return err;
    };
    if (res.term.Exited > 0) {
        const process_name = try std.mem.join(args.allocator, " ", args.argv);
        try logger.err(
            "Encountered error while running '{s}'. exit code: {}; stderr: {s}",
            .{ process_name, res.term.Exited, res.stderr },
        );
        return error.ChildProcessError;
    }
    return res;
}

fn ln(symlinks: []Config.Symlink, shell_map: ?Config.ShellMap, dry_run: bool, allocator: Allocator, logger: *Logger) !void {
    try logger.newContext(@src().fn_name);
    defer logger.contextFinish() catch {};
    try run_hook(shell_map, .{ .when = .before, .what = .ln }, dry_run, allocator, logger);

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
    try run_hook(shell_map, .{ .when = .after, .what = .ln }, dry_run, allocator, logger);
}

fn repos(repositories: []Config.Repo, shell_map: ?Config.ShellMap, dry_run: bool, allocator: Allocator, logger: *Logger) !void {
    try logger.newContext(@src().fn_name);
    defer logger.contextFinish() catch {};
    try run_hook(shell_map, .{ .when = .before, .what = .repos }, dry_run, allocator, logger);

    // TODO: run this in separate threads
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

    try run_hook(shell_map, .{ .when = .after, .what = .repos }, dry_run, allocator, logger);
}

fn shell(cmd: Config.Shell, dry_run: bool, allocator: Allocator, logger: *Logger) !void {
    try logger.newContext(@src().fn_name);
    defer logger.contextFinish() catch {};
    if (!dry_run) {
        const res = try generic_run(.{ .allocator = allocator, .argv = cmd.cmd }, logger);
        if (res.stdout.len > 0) {
            const process_name = try std.mem.join(allocator, " ", cmd.cmd);
            try logger.info("Stdout from running '{s}':\n{s}", .{ process_name, res.stdout });
        }
    }
}
