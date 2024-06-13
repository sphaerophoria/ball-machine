const std = @import("std");

pub fn add(a: i32, b: i32) i32 {
    return a + b;
}

pub const A = struct {
    pub fn f(val: f32) void {
        std.debug.print("{d}\n", .{val});
    }
};

pub fn sub(a: i32, b: i32) i32 {
    return a - b;
}
