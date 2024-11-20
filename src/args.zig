const std = @import("std");
const Allocator = std.mem.Allocator;
const clap = @import("clap");
const Command = @import("commands.zig").Command;

pub const Args = struct {
    help: bool = false,
    verbose: bool = false,
    color: bool = true,
    dry_run: bool = false,
    commands: []const Command = &[_]Command{},
    config_file: [:0]const u8 = @ptrCast(&[_]u8{}),
    lua_path: []const u8 = &[_]u8{},

    const ColorMode = enum { Auto, On, Off };

    pub fn init(allocator: Allocator, home: []const u8) !@This() {
        const params = comptime clap.parseParamsComptime(
            \\-h, --help                 Display this help and exit
            \\-v, --verbose              Print verbose output, useful for debugging
            \\-d, --dryrun               Only print what syke would be doing, but do not perform any actions. This also enables -v
            \\--color       <COLOR_MODE> whether to enable colors [options: auto(default), on, off]
            \\-c, --config  <PATH>       Path to the config file; defaults to $XDG_CONFIG_HOME/syke/syke.lua
            \\<COMMAND>...
            \\
        );

        const parsers = comptime .{
            .PATH = clap.parsers.string,
            .COMMAND = clap.parsers.enumeration(Command),
            .COLOR_MODE = clap.parsers.enumeration(ColorMode),
        };

        var diag = clap.Diagnostic{};
        var res = clap.parse(clap.Help, &params, parsers, .{
            .diagnostic = &diag,
            .allocator = allocator,
        }) catch |err| {
            try diag.report(std.io.getStdErr().writer(), err);
            return err;
        };
        defer res.deinit();

        const help = res.args.help != 0;
        if (help)
            try clap.help(std.io.getStdErr().writer(), clap.Help, &params, .{});

        return @This(){
            .color = blk: {
                if (res.args.color) |c| {
                    break :blk switch (c) {
                        .Auto => std.io.tty.detectConfig(std.io.getStdOut()) != .no_color,
                        .On => true,
                        .Off => false,
                    };
                }
                break :blk true;
            },
            .help = help,
            .dry_run = res.args.dryrun != 0,
            .verbose = res.args.verbose != 0 or res.args.dryrun != 0,
            .config_file = blk: {
                if (res.args.config) |c|
                    break :blk try std.fmt.allocPrintZ(allocator, "{s}", .{c});
                break :blk try std.fmt.allocPrintZ(allocator, "{s}/.config/syke/syke.lua", .{home});
            },
            .lua_path = blk: {
                if (res.args.config) |c|
                    break :blk try std.fmt.allocPrint(allocator, "{s}", .{std.fs.path.dirname(c).?});
                break :blk try std.fmt.allocPrint(allocator, "{s}/.config/syke/lua", .{home});
            },
            .commands = blk: {
                var n_commands = res.positionals.len;
                var have_sync = false;

                for (res.positionals) |p| {
                    if (p == .sync) {
                        have_sync = true;
                        n_commands = 1;
                        break;
                    }
                }

                var commands = try allocator.alloc(Command, if (n_commands == 0) 1 else n_commands);
                if (n_commands == 0 or have_sync) {
                    commands[0] = Command.sync;
                    n_commands = 1;
                } else {
                    for (res.positionals, 0..) |c, i| {
                        commands[i] = c;
                    }
                }
                break :blk commands;
            },
        };
    }
};
