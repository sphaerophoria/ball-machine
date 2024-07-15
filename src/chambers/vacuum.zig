const std = @import("std");
const graphics = @import("graphics.zig");
const physics = @import("physics");
const Pos2 = physics.Pos2;
const Ball = physics.Ball;

const c = @cImport({
    @cInclude("stb_image.h");
});

extern fn logWasm(s: [*]u8, len: usize) void;
fn print(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch unreachable;
    logWasm(s.ptr, s.len);
}

const platform = physics.Surface{
    .a = .{
        .x = 0.1,
        .y = 0.1,
    },
    .b = .{
        .x = 0.9,
        .y = 0.1,
    },
};

const vacuum_rect_width = 0.2;
const vacuum_rect_height = 0.3;
const vacuum_center_y = 0.25;
const image_data = @embedFile("image_data");

const State = struct {
    vacuum_center: f32 = 0.5,
    hose_end: Pos2 = .{
        .x = 0.8,
        .y = 0.3,
    },
    hose_end_rot: f32 = std.math.pi / 2.0,

    fn vacuumRect(self: *const State) graphics.Rect {
        return .{
            .center = .{
                .x = self.vacuum_center,
                .y = vacuum_center_y,
            },
            .width = vacuum_rect_width,
            .height = vacuum_rect_height,
            .rotation_rad = 0,
        };
    }
};

var balls: []Ball = undefined;
var canvas_memory: []u32 = undefined;
var state = State{};
var save_data: [4]f32 = undefined;
var texturer: Texturer = Texturer{};
const black = graphics.colorTexturer(0xff000000);

pub export fn init(max_balls: usize, max_chamber_pixels: usize) void {
    physics.assertBallLayout();
    balls = std.heap.wasm_allocator.alloc(Ball, max_balls) catch {
        return;
    };

    canvas_memory = std.heap.wasm_allocator.alloc(u32, max_chamber_pixels) catch {
        return;
    };
}

pub export fn saveMemory() [*]f32 {
    return &save_data;
}

pub export fn ballsMemory() ?*void {
    return @ptrCast(balls.ptr);
}

pub export fn canvasMemory() ?*void {
    return @ptrCast(canvas_memory.ptr);
}

pub export fn saveSize() usize {
    return save_data.len * @sizeOf(f32);
}

pub export fn save() void {
    save_data[0] = state.vacuum_center;
    save_data[1] = state.hose_end.x;
    save_data[2] = state.hose_end.y;
    save_data[3] = state.hose_end_rot;
}

pub export fn load() void {
    state.vacuum_center = save_data[0];
    state.hose_end.x = save_data[1];
    state.hose_end.y = save_data[2];
    state.hose_end_rot = save_data[3];
}

const Texturer = struct {
    const img: []const u8 = @embedFile("image_data");
    const width = 30;
    const height: f32 = img.len / 4 / width;

    pub fn get(self: *const Texturer, x: f32, y: f32, old_px: u32) u32 {
        _ = self;
        if (x < 0 or x >= 1.0 or y < 0 or y >= 1.0) {
            return old_px;
        }

        const x_u: usize = @intFromFloat(x * width);
        const y_u: usize = @intFromFloat(y * height);
        const pixel_idx = y_u * width + x_u;
        const start = pixel_idx * 4;
        const end = start + 4;

        const Pixel = packed struct {
            r: u8,
            g: u8,
            b: u8,
            a: u8,
        };
        const val = std.mem.bytesToValue(Pixel, img[start..end]);
        const old: Pixel = @as(*const Pixel, @ptrCast(&old_px)).*;
        const a: u16 = val.a;
        const old_a: u16 = 255 - a;

        var ret = Pixel{
            .r = @intCast(((a * val.r) >> 8) + ((old_a * old.r) >> 8)),
            .g = @intCast(((a * val.g) >> 8) + ((old_a * old.r) >> 8)),
            .b = @intCast(((a * val.b) >> 8) + ((old_a * old.r) >> 8)),
            .a = 0xff,
        };

        return @as(*const u32, @ptrCast(&ret)).*;
    }
};

pub export fn step(num_balls: usize, delta: f32) void {
    var closest_ball_idx: usize = 0;
    var closest_ball_dist: f32 = std.math.floatMax(f32);

    for (0..num_balls) |i| {
        const ball = &balls[i];
        physics.applyGravity(ball, delta);

        const ball_dist = state.hose_end.sub(ball.pos).length_2();
        if (ball_dist < closest_ball_dist) {
            closest_ball_idx = i;
            closest_ball_dist = ball_dist;
        }

        const obj_normal = platform.normal();
        const ball_collision_point_offs = obj_normal.mul(-ball.r);
        const ball_collision_point = ball.pos.add(ball_collision_point_offs);

        const resolution = platform.collisionResolution(ball_collision_point, ball.velocity.mul(delta));
        if (resolution) |r| {
            physics.applyCollision(ball, r, obj_normal, physics.Vec2.zero, delta, 0.5);
            ball.velocity.x *= 0.8;
        }
    }

    if (num_balls == 0) {
        return;
    }
    const closest_ball_pos = balls[closest_ball_idx].pos;
    const max_speed = 0.7;
    const max_rot = 0.02;

    const max_dist_this_frame = max_speed * delta;

    const to_mouse_vec = closest_ball_pos.sub(state.hose_end);
    const dist_to_mouse = to_mouse_vec.length();
    if (dist_to_mouse < 0.01) {
        const closest_ball = &balls[closest_ball_idx];
        const hose_end_norm = physics.Vec2{
            .x = @cos(state.hose_end_rot),
            .y = @sin(state.hose_end_rot),
        };
        closest_ball.velocity = closest_ball.velocity.add(hose_end_norm.mul(4.0));
        return;
    }

    const max_roll_speed = 0.2;
    const mouse_to_vacuum_x = closest_ball_pos.x - state.vacuum_center - vacuum_rect_width / 2.0;
    if (@abs(mouse_to_vacuum_x) > 0.3) {
        state.vacuum_center += std.math.clamp(mouse_to_vacuum_x, -max_roll_speed * delta, max_roll_speed * delta);
    }

    const to_mouse_angle = std.math.atan2(to_mouse_vec.y, to_mouse_vec.x);
    var angle_change = @mod(to_mouse_angle - state.hose_end_rot, std.math.pi * 2);
    if (angle_change > std.math.pi) {
        angle_change = -(2 * std.math.pi - angle_change);
    }

    angle_change = std.math.clamp(angle_change, -max_rot * delta, max_rot);
    state.hose_end_rot += angle_change;

    if (dist_to_mouse < max_dist_this_frame) {
        state.hose_end = closest_ball_pos;
    } else {
        state.hose_end = state.hose_end.add(to_mouse_vec.mul(max_dist_this_frame / dist_to_mouse));
    }
}

const BezierTexturer = struct {
    pub fn get(self: *const @This(), x: f32, y: f32, old_px: u32) u32 {
        _ = self;
        if (x > 1.0 or x < 0.0 or y > 1.0 or y < 0) {
            return old_px;
        }

        const dark: bool = y > 0.9 or y < 0.1 or @sin(x * std.math.pi * 80) > 0.8;
        if (dark) {
            return 0xff000000;
        } else {
            return 0xff4d4d4d;
        }
    }
};

pub export fn render(canvas_width: usize, canvas_height: usize) void {
    const this_canvas_memory = canvas_memory[0 .. canvas_width * canvas_height];
    @memset(this_canvas_memory, 0xffffffff);

    const graphics_canvas = graphics.Canvas{ .width = canvas_width, .data = this_canvas_memory };

    graphics.renderLine(platform.a, platform.b, &graphics_canvas, black);

    graphics.renderRotatedRect(state.vacuumRect(), &graphics_canvas, texturer);

    const vacuum_center = Pos2{
        .x = state.vacuum_center,
        .y = vacuum_center_y,
    };
    const a = vacuum_center.add(.{
        .x = vacuum_rect_width / 2.2,
        .y = vacuum_rect_height / 5.0,
    });

    const ctrl = a.add(.{
        .x = vacuum_rect_width * 1.5,
        .y = 0,
    });

    const ctrl2_norm = physics.Vec2{
        .x = @cos(state.hose_end_rot),
        .y = @sin(state.hose_end_rot),
    };

    const ctrl2_pos = state.hose_end.add(ctrl2_norm.mul(-0.3));

    graphics.renderBezier(
        &[_]Pos2{ a, ctrl, ctrl2_pos, state.hose_end },
        0.05,
        &graphics_canvas,
        BezierTexturer{},
    );
}
