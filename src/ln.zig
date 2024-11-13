const std = @import("std");
const Lua = @import("ziglua").Lua;

pub const Symlink = struct {
    source: []const u8,
    target: []const u8,

    pub fn execute(self: Symlink) void {
        std.debug.print("source: {s}\ntarget: {s}\n", .{ self.source, self.target });
    }

    pub fn fromLua(lua: *Lua) !Symlink {
        _ = lua.getField(-1, "source");
        const source = try lua.toString(-1);
        lua.pop(1);

        _ = lua.getField(-1, "target");
        const target = try lua.toString(-1);
        lua.pop(1);

        return Symlink{ .source = source, .target = target };
    }
};
