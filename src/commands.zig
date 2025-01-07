const CLI = @import("cli.zig").CLI;
const Config = @import("config.zig").Config;
const ConfigGen = @import("config.zig").ConfigGen;
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

const Args = struct {
    shell_map: ?Config.ShellMap,
    dry_run: bool,
    allocator: Allocator,
    logger: *Logger,
};

const CommandError = error{
    ChildProcessError,
};

pub fn run_commands(
    cli: CLI,
    config: Config,
    _: Config,
    allocator: Allocator,
    logger: *Logger,
) !void {
    const command_args = Args{
        .shell_map = config.shell,
        .dry_run = cli.dry_run,
        .allocator = allocator,
        .logger = logger,
    };
    try run_hook(.{ .when = .before, .what = .main }, command_args);

    for (cli.commands) |c| {
        switch (c) {
            .ln => try ln(config.symlinks, command_args),
            .repos => try repos(config.repos, command_args),
            .shell => {},
            .sync => {
                try logger.newContext("sync");
                defer logger.contextFinish() catch {};
                try ln(config.symlinks, command_args);
                try repos(config.repos, command_args);
            },
        }
    }

    try run_hook(.{ .when = .after, .what = .main }, command_args);
}

fn run_hook(hook: Config.Shell.Hook, args: Args) !void {
    if (args.shell_map == null or !args.shell_map.?.has_hook(hook))
        return;

    for (args.shell_map.?.data[hook.to_int()].items) |s|
        try shell(s, args);
}

fn captured_run(args: struct {
    allocator: Allocator,
    argv: []const []const u8,
    cwd: ?[]const u8 = null,
    cwd_dir: ?std.fs.Dir = null,
    logger: *Logger,
}) !Child.RunResult {
    const res = Child.run(.{
        .allocator = args.allocator,
        .argv = args.argv,
        .cwd = args.cwd,
        .cwd_dir = args.cwd_dir,
    }) catch |err| {
        const process_name = try std.mem.join(args.allocator, " ", args.argv);
        try args.logger.err(
            "Unable to spawn process '{s}'. error: {any}",
            .{ process_name, err },
        );
        return err;
    };
    if (res.term.Exited > 0) {
        const process_name = try std.mem.join(args.allocator, " ", args.argv);
        try args.logger.err(
            "Encountered error while running '{s}'. exit code: {}; stderr: {s}",
            .{ process_name, res.term.Exited, res.stderr },
        );
        return error.ChildProcessError;
    }
    return res;
}

fn generic_run(args: struct {
    allocator: Allocator,
    argv: []const []const u8,
    cwd: ?[]const u8 = null,
    cwd_dir: ?std.fs.Dir = null,
    logger: *Logger,
}) !void {
    var process = Child.init(args.argv, args.allocator);
    process.cwd = args.cwd;
    process.cwd_dir = args.cwd_dir;
    const term = process.spawnAndWait() catch |err| {
        try args.logger.err(
            "Unable to spawn process: process = '{s}'; error = {any}",
            .{ try std.mem.join(args.allocator, " ", args.argv), err },
        );
        return err;
    };
    switch (term) {
        .Exited => |exit_code| {
            if (exit_code > 0) {
                try args.logger.err(
                    "Shell process encountered error: process = '{s}'; error code = {any}",
                    .{ try std.mem.join(args.allocator, " ", args.argv), exit_code },
                );
            }
        },
        .Signal => |signal| {
            try args.logger.err(
                "Shell process encountered signal: process = '{s}'; signal code = {any}",
                .{ try std.mem.join(args.allocator, " ", args.argv), signal },
            );
        },
        .Stopped => |stop_code| {
            try args.logger.err(
                "Shell process encountered stop: process = '{s}'; stop code = {any}",
                .{ try std.mem.join(args.allocator, " ", args.argv), stop_code },
            );
        },
        .Unknown => |code| {
            try args.logger.err(
                "Shell process encountered unknown term: process = '{s}'; code = {any}",
                .{ try std.mem.join(args.allocator, " ", args.argv), code },
            );
        },
    }
}

fn ln(symlinks: []Config.Symlink, args: Args) !void {
    try args.logger.newContext(@src().fn_name);
    defer args.logger.contextFinish() catch {};
    try run_hook(.{ .when = .before, .what = .ln }, args);

    for (symlinks) |sl| {
        if (args.logger.verbose)
            try args.logger.info("{s} -> {s}", .{ sl.source, sl.target });
        if (!args.dry_run) {
            try std.fs.cwd().makePath(std.fs.path.dirname(sl.target).?);
            try std.fs.atomicSymLink(args.allocator, sl.source, sl.target);
        }
    }
    try run_hook(.{ .when = .after, .what = .ln }, args);
}

fn repos(repositories: []Config.Repo, args: Args) !void {
    try args.logger.newContext(@src().fn_name);
    defer args.logger.contextFinish() catch {};
    try run_hook(.{ .when = .before, .what = .repos }, args);

    // TODO: run this in separate threads
    for (repositories) |repo| {
        const dir = std.fs.openDirAbsolute(repo.path, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                _ = generic_run(.{
                    .allocator = args.allocator,
                    .argv = &.{ "git", "clone", repo.remote, repo.path },
                    .logger = args.logger,
                }) catch {};
                continue;
            },
            else => return err,
        };

        const git_remote = captured_run(.{
            .allocator = args.allocator,
            .argv = &.{ "git", "remote", "-v" },
            .cwd_dir = dir,
            .logger = args.logger,
        }) catch continue;

        if (git_remote.stdout.len == 0) {
            try args.logger.err(
                "Found git repository at {s}, but it has no remotes set up",
                .{repo.path},
            );
            continue;
        }

        const remote_starts_at = std.mem.indexOf(u8, git_remote.stdout, "\t").? + 1;
        if (!std.mem.startsWith(u8, git_remote.stdout[remote_starts_at..], repo.remote)) {
            try args.logger.err(
                "Found git repository at {s}, but it is pointing not pointing at remote {s}. 'git remote -v' output:\n{s}",
                .{
                    repo.path,
                    repo.remote,
                    git_remote.stdout,
                },
            );
            continue;
        }

        const git_status = captured_run(.{
            .allocator = args.allocator,
            .argv = &.{ "git", "status", "--porcelain=v1" },
            .cwd_dir = dir,
            .logger = args.logger,
        }) catch continue;
        if (git_status.stdout.len > 1) {
            try args.logger.warn(
                "Repo at {s} contains uncommited changes. Skipping pull.",
                .{repo.path},
            );
            continue;
        }

        const git_pull = captured_run(.{
            .allocator = args.allocator,
            .argv = &.{ "git", "pull" },
            .cwd_dir = dir,
            .logger = args.logger,
        }) catch continue;
        try args.logger.info("git pull @{s} stdout: {s}", .{ repo.path, git_pull.stdout[0 .. git_pull.stdout.len - 2] });
    }

    try run_hook(.{ .when = .after, .what = .repos }, args);
}

fn shell(cmd: Config.Shell, args: Args) !void {
    try args.logger.newContext(@src().fn_name);
    defer args.logger.contextFinish() catch {};
    try args.logger.info(
        "Running shell command: '{s}':",
        .{try std.mem.join(args.allocator, " ", cmd.cmd)},
    );
    if (!args.dry_run)
        try generic_run(.{ .allocator = args.allocator, .argv = cmd.cmd, .logger = args.logger });
}
