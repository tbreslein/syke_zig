const std = @import("std");
const Lua = @import("ziglua").Lua;
const Allocator = std.mem.Allocator;

pub const Config = struct {
    symlinks: []Symlink = undefined,

    pub const Symlink = struct {
        source: []const u8 = "",
        target: []const u8 = "",
        force: bool = false,
    };
};

pub fn parseFromLua(comptime t: type, allocator: Allocator, lua: *Lua) !t {
    // IDEA: using @embed, I can probably define the structure of Config in a
    // separate file that I can parse into both lua and zig to have a single
    // definition for Config that is used by both languages. That would be so
    // sick...
    var x = t{};
    inline for (std.meta.fields(t)) |field| {
        _ = lua.getField(-1, field.name);
        defer lua.pop(1);
        switch (field.type) {
            []const u8 => @field(x, field.name) = try lua.toString(-1),
            bool => @field(x, field.name) = lua.toBoolean(-1),

            else => {
                // this might be an array...
                if (@typeName(field.type)[0] == '[' and @typeName(field.type)[1] == ']') {
                    const elem_type: type = std.meta.Elem(field.type);
                    _ = lua.len(-1);
                    const n: usize = @intCast(try lua.toInteger(-1));
                    lua.pop(1);

                    const arr = try allocator.alloc(elem_type, n);
                    for (0..n) |i| {
                        _ = lua.getIndex(-1, @intCast(i + 1));
                        defer lua.pop(1);
                        arr[i] = try parseFromLua(elem_type, allocator, lua);
                    }
                    @field(x, field.name) = arr;
                } else {
                    @panic("foo");
                }
            },
        }
    }
    return x;
}
