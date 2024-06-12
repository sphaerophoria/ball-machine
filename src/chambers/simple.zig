const std = @import("std");
const physics = @import("physics");
const plugin_alloc = @import("plugin_alloc.zig");
const Ball = physics.Ball;
const Surface = physics.Surface;
const Allocator = std.mem.Allocator;

const State = struct {};

const platform = Surface{
    .a = .{
        .x = 0.1,
        .y = 0.1,
    },
    .b = .{
        .x = 0.9,
        .y = 0.4,
    },
};

pub export fn init() ?*State {
    // Force exported plugin_alloc functions to be referenced
    _ = plugin_alloc;
    return null;
}

pub export fn deinit(state: *State) void {
    _ = state;
}

pub export fn saveSize() usize {
    return 0;
}

pub export fn save(state: *State, out_p: [*]u8) void {
    _ = state;
    _ = out_p;
}

pub export fn load(save_buf_p: [*]const u8) ?*State {
    _ = save_buf_p;
    return null;
}

pub export fn step(state: *State, balls_p: [*]Ball, num_balls: usize, delta: f32) void {
    _ = state;
    const balls = balls_p[0..num_balls];

    for (balls) |*ball| {
        const obj_normal = platform.normal();
        const ball_collision_point_offs = obj_normal.mul(-ball.r);
        const ball_collision_point = ball.pos.add(ball_collision_point_offs);

        const resolution = platform.collisionResolution(ball_collision_point, ball.velocity.mul(delta));
        if (resolution) |r| {
            physics.applyCollision(ball, r, obj_normal, delta);
        }
    }
}

pub export fn render(state: *State, pixel_data_p: [*]u8, canvas_width: usize, canvas_height: usize) void {
    _ = state;

    const canvas_width_f: f32 = @floatFromInt(canvas_width);
    const canvas_height_f: f32 = @floatFromInt(canvas_height);
    const x_start_px: usize = @intFromFloat(platform.a.x * canvas_width_f);
    const x_end_px: usize = @intFromFloat(platform.b.x * canvas_width_f);
    const x_dist_px: f32 = (platform.b.x - platform.a.x) * canvas_width_f;

    const y_start_px = canvas_height_f - platform.a.y * canvas_width_f;
    const y_end_px = canvas_height_f - platform.b.y * canvas_width_f;
    const y_dist_px: f32 = y_end_px - y_start_px;

    const pixel_data = plugin_alloc.ptrToSlice(pixel_data_p);
    const pixel_data_u32 = std.mem.bytesAsSlice(u32, pixel_data);

    for (x_start_px..x_end_px) |x| {
        const interp: f32 = @as(f32, @floatFromInt(x - x_start_px)) / x_dist_px;
        const y_f = y_start_px + y_dist_px * interp;
        const y: usize = @intFromFloat(y_f);

        for (y -| 2..y + 2) |i| {
            pixel_data_u32[i * canvas_width + x] = 0xff000000;
        }
    }
}
