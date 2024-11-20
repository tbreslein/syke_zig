const Args = @import("args.zig").Args;
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Level = enum { Info, Warn, Error, Success };

fn getColor(comptime level: Level) []const u8 {
    const colNum = switch (level) {
        .Info => "34",
        .Warn => "33",
        .Error => "31",
        .Success => "32",
    };
    return "\x1b[1;" ++ colNum ++ "m";
}

pub const Logger = struct {
    verbose: bool,
    color: bool,
    stdout: std.fs.File.Writer,
    stderr: std.fs.File.Writer,
    current_ctx_stack: std.ArrayList([]const u8),
    saw_error: bool,

    pub fn init(args: Args, allocator: Allocator) @This() {
        return .{
            .color = args.color,
            .verbose = args.verbose,
            .stdout = std.io.getStdOut().writer(),
            .stderr = std.io.getStdErr().writer(),
            .current_ctx_stack = std.ArrayList([]const u8).init(allocator),
            .saw_error = false,
        };
    }

    pub fn newContext(self: *@This(), comptime ctx: []const u8) !void {
        try self.current_ctx_stack.append(ctx);
        try self.log(.Info, "Start", .{});
        self.saw_error = false;
    }

    pub fn info(self: @This(), comptime fstring: []const u8, fargs: anytype) !void {
        try self.log(.Info, fstring, fargs);
    }

    pub fn warn(self: @This(), comptime fstring: []const u8, fargs: anytype) !void {
        try self.log(.Warn, fstring, fargs);
    }

    pub fn err(self: *@This(), comptime fstring: []const u8, fargs: anytype) !void {
        self.saw_error = true;
        try self.log(.Error, fstring, fargs);
    }

    fn success(self: @This(), comptime fstring: []const u8, fargs: anytype) !void {
        try self.log(.Success, fstring, fargs);
    }

    fn log(self: @This(), comptime level: Level, comptime fstring: []const u8, fargs: anytype) !void {
        const writer = switch (level) {
            .Info, .Warn, .Success => self.stdout,
            .Error => self.stderr,
        };

        const color = switch (self.color) {
            true => getColor(level),
            false => "",
        };
        const reset = switch (self.color) {
            true => "\x1b[0m",
            false => "",
        };
        const context = switch (self.current_ctx_stack.items.len) {
            0 => "",
            else => self.current_ctx_stack.items[self.current_ctx_stack.items.len - 1],
        };
        try writer.print("{s}[ syke:{s} ] {s} |{s} " ++ fstring ++ "\n", .{ color, context, @tagName(level), reset } ++ fargs);
    }

    pub fn contextFinish(self: *@This()) !void {
        if (self.saw_error) {
            try self.warn("Saw at least one error. Check previous logs", .{});
        } else {
            try self.success("Done", .{});
        }
        _ = self.current_ctx_stack.pop();
    }
};