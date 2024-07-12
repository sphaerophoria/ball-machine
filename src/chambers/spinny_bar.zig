const std = @import("std");
const physics = @import("physics");
const Ball = physics.Ball;
const Surface = physics.Surface;
const Allocator = std.mem.Allocator;
const Pos2 = physics.Pos2;
const Vec2 = physics.Vec2;

const center = Pos2{
    .x = 0.5,
    .y = 0.35,
};

const State = struct {
    angle: f32 = 0,

    fn surface(self: *State) Surface {
        const c = @cos(self.angle);
        const s = @sin(self.angle);

        const scale = 0.15 * @abs(c) + 0.3;

        const a = Pos2{
            .x = center.x + c * scale,
            .y = center.y + s * scale,
        };

        const b = Pos2{
            .x = center.x - c * scale,
            .y = center.y - s * scale,
        };

        return .{
            .a = a,
            .b = b,
        };
    }
};

var state: State = .{};
var balls: []Ball = undefined;
var chamber_pixels: []u32 = undefined;
var save_data: f32 = undefined;

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
    return @sizeOf(@TypeOf(save_data));
}

pub export fn save() void {
    save_data = state.angle;
}

pub export fn load() void {
    state.angle = save_data;
}

pub export fn step(num_balls: usize, delta: f32) void {
    const rotation_this_frame = 1.5 * std.math.pi * delta;
    state.angle += rotation_this_frame;
    state.angle = @mod(state.angle, std.math.pi * 2.0);

    for (balls) |*ball| {
        physics.applyGravity(ball, delta);
    }

    const surface = state.surface();
    const inverse_surface: Surface = .{
        .a = surface.b,
        .b = surface.a,
    };

    const surfaces = &[_]Surface{ surface, inverse_surface };
    for (surfaces) |obj| {
        for (0..num_balls) |i| {
            const ball = &balls[i];

            const obj_normal = obj.normal();

            const ball_collision_point_offs = obj_normal.mul(-ball.r);
            const ball_collision_point = ball.pos.add(ball_collision_point_offs);

            const surface_collision_point_movement = SpinnyBarCalculator.collisionPointMovement(ball.*, rotation_this_frame, obj);
            const surface_collision_point_velocity = surface_collision_point_movement.mul(1.0 / delta);

            const resolution = obj.collisionResolution(ball_collision_point, ball.velocity.mul(delta).add(surface_collision_point_movement.mul(-1)));
            if (resolution) |r| {
                physics.applyCollision(ball, r, obj_normal, surface_collision_point_velocity, delta, 1.5);
            }

            obj.pushIfColliding(ball, physics.Vec2.zero, delta, 0.001);
        }
    }
}

pub export fn render(canvas_width: usize, canvas_height: usize) void {
    @memset(chamber_pixels, 0xffffffff);

    const surface = state.surface();
    renderLine(surface.a, surface.b, canvas_width, canvas_height, chamber_pixels);
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

const SpinnyBarCalculator = struct {
    fn collisionPoint(ball: Ball, surface: Surface) Pos2 {
        const n = surface.normal();
        //     p
        //     o
        //     |\
        //    n|  \ pb
        //     |    \
        // a__________\ b
        //
        //  projecting pb onto n gives us where on ab we would collide if we were to collide
        const pb = surface.b.sub(ball.pos);
        const surface_offset_from_ball = n.mul(pb.dot(n));
        return ball.pos.add(surface_offset_from_ball);
    }

    fn collisionPointMovementDir(collision_point_offs: Vec2) Vec2 {
        // The movement direction is just perpendicular to the center offset
        //
        //           ^
        //           |
        // -----o-----
        // |
        // v
        //
        return (Vec2{
            .x = -collision_point_offs.y,
            .y = collision_point_offs.x,
        }).normalized();
    }

    fn collisionPointMovementAmount(collision_point_offs: Vec2, rotation_this_frame: f32) f32 {
        const collision_point_dist = collision_point_offs.length();
        const full_rotation_dist = std.math.pi * 2 * collision_point_dist;
        return rotation_this_frame * full_rotation_dist;
    }

    fn collisionPointMovement(ball: Ball, rotation_this_frame: f32, surface: Surface) Vec2 {
        const collision_point_offs = collisionPoint(ball, surface).sub(center);
        const movement_amount = collisionPointMovementAmount(collision_point_offs, rotation_this_frame);
        return collisionPointMovementDir(collision_point_offs).mul(movement_amount);
    }
};
