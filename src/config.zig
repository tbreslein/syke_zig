const std = @import("std");
const Symlink = @import("ln.zig").Symlink;
const Lua = @import("ziglua").Lua;
const Allocator = std.mem.Allocator;

pub const Config = struct {
    symlinks: []Symlink,
    allocator: Allocator,

    pub fn fromLua(allocator: Allocator, lua: *Lua) !Config {
        const symlinks = try getSymlinks(allocator, lua);
        return Config{ .symlinks = symlinks, .allocator = allocator };
    }

    pub fn getSymlinks(allocator: Allocator, lua: *Lua) ![]Symlink {
        _ = lua.getField(-1, "symlinks");
        defer lua.pop(1);

        if (!lua.isTable(-1)) {
            try std.io.getStdOut().writer().print("ERROR: unable to parse field `symlinks` into a table\n", .{});
            return error.LuaError;
        }
        _ = lua.len(-1);
        const n_symlinks: usize = @intCast(try lua.toInteger(-1));
        lua.pop(1);

        const symlinks = try allocator.alloc(Symlink, n_symlinks);

        for (0..n_symlinks) |i| {
            _ = lua.getIndex(-1, @intCast(i + 1));
            defer lua.pop(1);
            symlinks[i] = try Symlink.fromLua(lua);
        }
        return symlinks;
    }

    pub fn deinit(self: Config) void {
        self.allocator.free(self.symlinks);
    }
};
