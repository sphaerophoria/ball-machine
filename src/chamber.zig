const std = @import("std");
const physics = @import("physics.zig");
const Ball = physics.Ball;
const Surface = physics.Surface;
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const Direction = enum(u8) {
    right,
    left,

    pub fn flip(self: *Direction) void {
        if (self.* == .right) {
            self.* = .left;
        } else {
            self.* = .right;
        }
    }
};

const num_platforms = 4;
const platform_ys: [num_platforms]f32 = .{ 0.1, 0.25, 0.4, 0.55 };
const platform_height_norm = 0.03;
const platform_width_norm = 0.3;

pub const State = struct {
    platform_locs: [num_platforms]f32 = .{ 0.5, 0.2, 0.4, 0.7 },
    directions: [num_platforms]Direction = .{ .right, .left, .right, .left },
};

const plugin_alloc = blk: {
    if (builtin.target.isWasm()) {
        break :blk std.heap.wasm_allocator;
    } else {
        const s = struct {
            var gpa = std.heap.GeneralPurposeAllocator(.{}){};
        };
        break :blk s.gpa.allocator();
    }
};

extern fn logWasm(s: [*]const u8, len: usize) void;

fn print(comptime fmt: []const u8, args: anytype) void {
    const to_print = std.fmt.allocPrint(plugin_alloc, fmt, args) catch {
        @panic("");
    };
    defer plugin_alloc.free(to_print);

    logWasm(to_print.ptr, to_print.len);
}

pub export fn init() ?*State {
    const ret = plugin_alloc.create(State) catch {
        return null;
    };

    ret.* = .{};
    return ret;
}

pub export fn deinit(state: *State) void {
    plugin_alloc.destroy(state);
}

const save_size = 20;
pub fn save(state: *State) [save_size]u8 {
    var ret: [save_size]u8 = undefined;
    for (0..state.platform_locs.len) |i| {
        const start = i * 4;
        const end = start + 4;
        @memcpy(ret[start..end], std.mem.asBytes(&state.platform_locs[i]));
        ret[16 + i] = @intFromEnum(state.directions[i]);
    }
    return ret;
}

pub export fn load(save_buf: *[]const u8) ?*State {
    const ret = plugin_alloc.create(State) catch {
        return null;
    };

    if (save_buf.*.len != save_size) {
        return null;
    }

    // FIXME: endianness
    var platform_locs: [num_platforms]f32 = undefined;
    var directions: [num_platforms]Direction = undefined;
    for (0..num_platforms) |i| {
        const start = i * 4;
        const end = start + 4;
        platform_locs[i] = std.mem.bytesToValue(f32, save_buf.*[start..end]);
        directions[i] = @enumFromInt(save_buf.*[16 + i]);
    }

    ret.* = .{
        .platform_locs = platform_locs,
        .directions = directions,
    };
    return ret;
}

pub export fn logState(state: *State) void {
    if (builtin.target.isWasm()) {
        print("{any}\n", .{state.*});
    }
}

pub export fn step(state: *State, ball: *Ball, delta: f32) void {
    const speed = 1.0;
    for (0..num_platforms) |i| {
        var movement = speed * delta;

        switch (state.directions[i]) {
            .left => {
                movement *= -1;
            },
            .right => {},
        }

        const obj = Surface{
            .a = .{
                .x = state.platform_locs[i] - platform_width_norm / 2.0,
                .y = platform_ys[i],
            },
            .b = .{
                .x = state.platform_locs[i] + platform_width_norm / 2.0,
                .y = platform_ys[i],
            },
        };

        const obj_normal = obj.normal();
        const ball_collision_point_offs = obj_normal.mul(-ball.r);
        const ball_collision_point = ball.pos.add(ball_collision_point_offs);

        const resolution = obj.collisionResolution(ball_collision_point, ball.velocity.mul(delta));
        if (resolution) |r| {
            ball.velocity.x += (movement / delta - ball.velocity.x) * 0.3;
            physics.applyCollision(ball, r, obj_normal, delta);
        }
        state.platform_locs[i] += movement;
        state.platform_locs[i] = @mod(state.platform_locs[i], 2.0);

        if (state.platform_locs[i] >= 1.0) {
            state.directions[i].flip();
            state.platform_locs[i] = 2.0 - state.platform_locs[i];
        }
    }
}

pub export fn alloc(size: usize) ?*[]u8 {
    const ret_slice = plugin_alloc.alloc(u8, size) catch {
        return null;
    };

    const ret = plugin_alloc.create([]u8) catch {
        return null;
    };
    ret.* = ret_slice;
    return ret;
}

pub export fn free(data: *[]u8) void {
    plugin_alloc.free(data.*);
    plugin_alloc.destroy(data);
}

pub export fn slicePtr(p: *[]u8) [*]u8 {
    return p.ptr;
}

pub export fn sliceLen(p: *[]u8) usize {
    return p.len;
}

pub export fn render(state: *State, pixel_data: *[]u8, canvas_width: usize, canvas_height: usize) void {
    const canvas_width_f: f32 = @floatFromInt(canvas_width);
    const canvas_height_f: f32 = @floatFromInt(canvas_height);
    const num_y_px: usize = @intFromFloat(platform_height_norm * canvas_width_f);

    for (0..num_platforms) |i| {
        const pixel_data_u32: []u32 = @alignCast(std.mem.bytesAsSlice(u32, pixel_data.*));
        var platform_x_start_norm = state.platform_locs[i] - platform_width_norm / 2.0;
        var platform_x_end_norm = platform_x_start_norm + platform_width_norm;
        platform_x_start_norm = @max(0.0, platform_x_start_norm);
        platform_x_end_norm = @min(1.0, platform_x_end_norm);

        const platform_x_start_px: usize = @intFromFloat(platform_x_start_norm * canvas_width_f);
        const platform_x_end_px: usize = @intFromFloat(platform_x_end_norm * canvas_width_f);

        const y_px_start: usize = @intFromFloat(canvas_height_f - platform_ys[i] * canvas_width_f);

        for (0..num_y_px) |y_offs| {
            const y_px = y_px_start + y_offs;
            const pixel_row_start = y_px * canvas_width;

            for (platform_x_start_px..platform_x_end_px) |x| {
                pixel_data_u32[pixel_row_start + x] = 0xff000000;
            }
        }
    }
}
