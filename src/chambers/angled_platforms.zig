const std = @import("std");
const physics = @import("physics");
const graphics = @import("graphics.zig");
const Ball = physics.Ball;
const Surface = physics.Surface;
const Allocator = std.mem.Allocator;

const State = struct {};

const platforms: []const Surface = &[_]Surface{
    Surface{
        .a = .{ .x = 0.55, .y = 0.50 },
        .b = .{ .x = 0.9, .y = 0.65 },
    },
    Surface{
        .a = .{ .x = 0.1, .y = 0.5 },
        .b = .{ .x = 0.45, .y = 0.35 },
    },
    Surface{
        .a = .{ .x = 0.55, .y = 0.20 },
        .b = .{ .x = 0.9, .y = 0.35 },
    },
    Surface{
        .a = .{ .x = 0.1, .y = 0.2 },
        .b = .{ .x = 0.45, .y = 0.05 },
    },
};

var balls: []Ball = undefined;
var chamber_pixels: []u32 = undefined;
var last_render_width: usize = 0;
var last_render_height: usize = 0;

pub export fn init(max_balls: usize, max_chamber_pixels: usize) void {
    physics.assertBallLayout();
    balls = std.heap.wasm_allocator.alloc(Ball, max_balls) catch {
        return;
    };

    chamber_pixels = std.heap.wasm_allocator.alloc(u32, max_chamber_pixels) catch {
        return;
    };
}

pub export fn saveMemory() ?*void {
    return null;
}

pub export fn ballsMemory() ?*void {
    return @ptrCast(balls.ptr);
}

pub export fn canvasMemory() ?*void {
    return @ptrCast(chamber_pixels.ptr);
}

pub export fn saveSize() usize {
    return 0;
}

pub export fn save() void {}

pub export fn load() void {}

pub export fn step(num_balls: usize, delta: f32) void {
    for (0..num_balls) |i| {
        const ball = &balls[i];
        physics.applyGravity(ball, delta);
    }

    for (platforms) |platform| {
        for (0..num_balls) |i| {
            const ball = &balls[i];

            const obj_normal = platform.normal();
            const ball_collision_point_offs = obj_normal.mul(-ball.r);
            const ball_collision_point = ball.pos.add(ball_collision_point_offs);

            const resolution = platform.collisionResolution(ball_collision_point, ball.velocity.mul(delta));
            if (resolution) |r| {
                physics.applyCollision(ball, r, obj_normal, physics.Vec2.zero, delta, 0.9);
            }
        }
    }
}

pub export fn render(canvas_width: usize, canvas_height: usize) void {
    const this_chamber_pixels = chamber_pixels[0 .. canvas_width * canvas_height];
    if (canvas_width != last_render_width or canvas_height != last_render_height) {
        @memset(this_chamber_pixels, 0xffffffff);
    }

    const graphics_canvas = graphics.Canvas{
        .data = this_chamber_pixels,
        .width = canvas_width,
    };
    for (platforms) |platform| {
        graphics.renderLine(platform.a, platform.b, &graphics_canvas, graphics.colorTexturer(0xff000000));
    }
}
