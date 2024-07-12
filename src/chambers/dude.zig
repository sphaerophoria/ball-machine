const std = @import("std");
const physics = @import("physics");
const Ball = physics.Ball;
const Surface = physics.Surface;
const Allocator = std.mem.Allocator;
const animation = @import("animation");
const Pos2 = physics.Pos2;

const dude_y_offs: f32 = 0.1;
const dude_speed: f32 = 0.40;

const State = struct {
    t: f32 = 1.0,
    dude_x_offs: f32 = -0.4,

    fn getPhysicsSurface(self: *State) Surface {
        const top_y = 0.3 + platform.a.y;
        const x = 0.5 + self.dude_x_offs + 0.07;

        return .{
            .a = .{
                .x = x,
                .y = top_y,
            },
            .b = .{
                .x = x,
                .y = platform.a.y,
            },
        };
    }
};

const platform = Surface{
    .a = .{
        .x = 0.1,
        .y = 0.1,
    },
    .b = .{
        .x = 0.9,
        .y = 0.1,
    },
};

var balls: []Ball = undefined;
var chamber_pixels: []u32 = undefined;
var state = State{};
var save_data: [8]u8 = undefined;

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
    return @ptrCast(&save_data);
}

pub export fn ballsMemory() ?*void {
    return @ptrCast(balls.ptr);
}

pub export fn canvasMemory() ?*void {
    return @ptrCast(chamber_pixels.ptr);
}

pub export fn saveSize() usize {
    return save_data.len;
}

pub export fn save() void {
    @memcpy(save_data[0..4], std.mem.asBytes(&state.t));
    @memcpy(save_data[4..8], std.mem.asBytes(&state.dude_x_offs));
}

pub export fn load() void {
    state.t = std.mem.bytesAsValue(f32, save_data[0..4]).*;
    state.dude_x_offs = std.mem.bytesAsValue(f32, save_data[4..8]).*;
}

pub export fn step(num_balls: usize, delta: f32) void {
    state.t += delta * 60;
    state.dude_x_offs += dude_speed * delta;

    if (state.dude_x_offs > 0.4) {
        state.dude_x_offs = -0.4;
    }

    if (state.t > 30) {
        state.t = 1.0;
    }

    const surface = state.getPhysicsSurface();

    const dude_movement_speed = physics.Vec2{
        .x = dude_speed,
        .y = 0,
    };

    for (0..num_balls) |i| {
        const ball = &balls[i];
        physics.applyGravity(ball, delta);

        const obj_normal = platform.normal();
        const ball_collision_point_offs = obj_normal.mul(-ball.r);
        const ball_collision_point = ball.pos.add(ball_collision_point_offs);

        var resolution = platform.collisionResolution(ball_collision_point, ball.velocity.mul(delta));
        if (resolution) |r| {
            physics.applyCollision(ball, r, obj_normal, physics.Vec2.zero, delta, 0.9);
        }

        const surface_normal = surface.normal();
        const ball_surface_collision_offs = surface_normal.mul(-ball.r);
        const ball_surface_collision_point = ball.pos.add(ball_surface_collision_offs);
        var ball_dude_apparent_travel = ball.velocity.mul(delta);
        ball_dude_apparent_travel.x -= dude_speed * delta;
        resolution = surface.collisionResolution(ball_surface_collision_point, ball_dude_apparent_travel);
        if (resolution) |r| {
            physics.applyCollision(ball, r, obj_normal, dude_movement_speed, delta, 1.0);
        }
        surface.pushIfColliding(ball, dude_movement_speed, delta, 0.01);
    }
}

pub export fn render(canvas_width: usize, canvas_height: usize) void {
    @memset(chamber_pixels, 0xffffffff);

    for (animation.objects) |anim| {
        if (getBonePos(anim, state.t, state.dude_x_offs)) |bone| {
            renderLine(bone.a, bone.b, canvas_width, canvas_height, chamber_pixels);
        }
    }

    renderLine(platform.a, platform.b, canvas_width, canvas_height, chamber_pixels);
    //const surface = state.getPhysicsSurface();
    //renderLine(surface.a, surface.b, canvas_width, canvas_height, chamber_pixels);
}

fn getBonePos(anim: animation.Animation, t: f32, dude_x_offs: f32) ?animation.Bone {
    var before_opt: ?animation.Bone = null;
    var after_opt: ?animation.Bone = null;
    var before_t: f32 = -99.0;
    var after_t: f32 = 99.9;

    for (anim) |item| {
        if (item.t <= t and item.t > before_t) {
            before_opt = item.bone;
            before_t = item.t;
        }

        if (item.t > t and item.t < after_t) {
            after_opt = item.bone;
            after_t = item.t;
        }
    }

    const before = before_opt orelse {
        return null;
    };

    const after = after_opt orelse {
        return null;
    };

    var ret: animation.Bone = .{
        .a = interpolatePos(before_t, after_t, before.a, after.a, t),
        .b = interpolatePos(before_t, after_t, before.b, after.b, t),
    };

    ret.a.x += dude_x_offs;
    ret.b.x += dude_x_offs;
    ret.a.y -= dude_y_offs;
    ret.b.y -= dude_y_offs;

    return ret;
}

fn interpolate(start: f32, end: f32, start_val: f32, end_val: f32, t: f32) f32 {
    const t_norm = (t - start) / (end - start);
    return start_val + (end_val - start_val) * t_norm;
}

fn interpolatePos(start: f32, end: f32, start_val: Pos2, end_val: Pos2, t: f32) Pos2 {
    return .{
        .x = interpolate(start, end, start_val.x, end_val.x, t),
        .y = interpolate(start, end, start_val.y, end_val.y, t),
    };
}

fn to_y_px(norm: f32, chamber_width: usize, chamber_height: usize) i64 {
    const chamber_width_f: f32 = @floatFromInt(chamber_width);
    const floor_offs_px: usize = @intFromFloat(norm * chamber_width_f);
    return chamber_height - floor_offs_px;
}

fn to_x_px(norm: f32, chamber_width: usize) i64 {
    const chamber_width_f: f32 = @floatFromInt(chamber_width);
    return @intFromFloat(norm * chamber_width_f);
}

const LINE_WIDTH: usize = 4;

fn renderLineXMajor(start: Pos2, end: Pos2, chamber_width: usize, chamber_height: usize, canvas: []u32) void {
    const start_y_px = to_y_px(start.y, chamber_width, chamber_height);
    const end_y_px = to_y_px(end.y, chamber_width, chamber_height);
    const y_dist = end_y_px - start_y_px;

    const start_x_px = to_x_px(start.x, chamber_width);
    const end_x_px = to_x_px(end.x, chamber_width);
    const x_dist = end_x_px - start_x_px;

    const increment = std.math.sign(x_dist);
    std.debug.assert(increment != 0);

    var x = start_x_px;
    while (true) {
        const y_center: usize = @intCast(@divTrunc((x - start_x_px) * y_dist, x_dist) + start_y_px);
        for (@max(y_center - LINE_WIDTH, 0)..@min(y_center + LINE_WIDTH, chamber_height)) |y| {
            canvas[y * chamber_width + @as(usize, @intCast(x))] = 0xff000000;
        }

        x += increment;
        if (x == end_x_px) {
            break;
        }
    }
}

fn renderLineYMajor(start: Pos2, end: Pos2, chamber_width: usize, chamber_height: usize, canvas: []u32) void {
    const start_y_px = to_y_px(start.y, chamber_width, chamber_height);
    const end_y_px = to_y_px(end.y, chamber_width, chamber_height);
    const y_dist = end_y_px - start_y_px;

    const start_x_px = to_x_px(start.x, chamber_width);
    const end_x_px = to_x_px(end.x, chamber_width);
    const x_dist = end_x_px - start_x_px;

    const increment = std.math.sign(y_dist);
    std.debug.assert(increment != 0);

    var y = start_y_px;
    while (true) {
        const x_center: usize = @intCast(@divTrunc((y - start_y_px) * x_dist, y_dist) + start_x_px);
        for (@max(x_center - LINE_WIDTH, 0)..@min(x_center + LINE_WIDTH, chamber_width)) |x| {
            canvas[@as(usize, @intCast(y)) * chamber_width + x] = 0xff000000;
        }

        y += increment;
        if (y == end_y_px) {
            break;
        }
    }
}

fn renderLine(start: Pos2, end: Pos2, chamber_width: usize, chamber_height: usize, canvas: []u32) void {
    const x_dist = @abs(end.x - start.x);
    const y_dist = @abs(end.y - start.y);

    if (x_dist > y_dist) {
        renderLineXMajor(start, end, chamber_width, chamber_height, canvas);
    } else {
        renderLineYMajor(start, end, chamber_width, chamber_height, canvas);
    }
}
