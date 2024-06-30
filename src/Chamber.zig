const std = @import("std");
const Allocator = std.mem.Allocator;
const physics = @import("physics.zig");
const Ball = physics.Ball;

pub const Vtable = struct {
    initChamber: *const fn (self: ?*anyopaque, max_balls: usize) anyerror!void,
    load: *const fn (self: ?*anyopaque, data: []const u8) anyerror!void,
    save: *const fn (self: ?*anyopaque, alloc: Allocator) anyerror![]const u8,
    step: *const fn (self: ?*anyopaque, balls: []Ball, delta: f32) anyerror!void,
};

const Chamber = @This();

data: ?*anyopaque,
vtable: *const Vtable,

pub fn initChamber(self: Chamber, max_balls: usize) !void {
    return self.vtable.initChamber(self.data, max_balls);
}

pub fn load(self: Chamber, data: []const u8) !void {
    return self.vtable.load(self.data, data);
}

pub fn save(self: Chamber, alloc: Allocator) ![]const u8 {
    return self.vtable.save(self.data, alloc);
}

pub fn step(self: Chamber, balls: []Ball, delta: f32) !void {
    return self.vtable.step(self.data, balls, delta);
}
