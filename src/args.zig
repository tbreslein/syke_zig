const std = @import("std");
const Allocator = std.mem.Allocator;
const clap = @import("clap");

const Command = @import("commands.zig").Command;

pub const Args = struct {
    help: bool,
    verbose: bool,
    commands: []const Command,
    config_file: [:0]const u8,

    pub fn init(allocator: Allocator) !Args {
        const params = comptime clap.parseParamsComptime(
            \\-h, --help           Display this help and exit.
            \\-v, --verbose        Print verbose output, useful for debugging.
            \\-c, --config  <PATH> Path to the config file; defaults to $XDG_CONFIG_HOME/syke/syke.lua.
            \\<COMMAND>...
            \\
        );

        const parsers = comptime .{
            .PATH = clap.parsers.string,
            .COMMAND = clap.parsers.enumeration(Command),
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
        const verbose = res.args.verbose != 0;

        if (help) {
            try clap.help(std.io.getStdErr().writer(), clap.Help, &params, .{});
        }

        var config_file: [:0]const u8 = undefined;
        if (res.args.config) |c| {
            // NOTE: this is needed to "cast" the file name from a []const u8 to
            // [:0]const u8 (which lua.doFile expects)
            config_file = try std.fmt.allocPrintZ(allocator, "{s}", .{c});
        } else {
            config_file = "/Users/tommy/.config/syke/syke.lua";
        }
        // NOTE: I'm explicitly NOT checking whether this file exists, in order
        // to avoid Time-Of-Check-Time-Of-Use race conditions. Let the process
        // of opening file do this check and the necessary error handling.

        var n_commands = res.positionals.len;
        var commands = try allocator.alloc(Command, if (n_commands == 0) 1 else n_commands);
        if (n_commands == 0) {
            commands[0] = Command.sync;
            n_commands = 1;
        } else {
            for (res.positionals, 0..) |c, i| {
                commands[i] = c;
            }
        }

        return Args{
            .help = help,
            .verbose = verbose,
            .config_file = config_file,
            .commands = commands,
        };
    }
};
