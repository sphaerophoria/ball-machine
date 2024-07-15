const std = @import("std");
const physics = @import("physics");
const Ball = physics.Ball;
const Surface = physics.Surface;
const Allocator = std.mem.Allocator;
const Pos2 = physics.Pos2;
const Vec2 = physics.Vec2;
const graphics = @import("graphics.zig");

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
    const this_frame_data = chamber_pixels[0 .. canvas_width * canvas_height];
    @memset(this_frame_data, 0xffffffff);

    const surface = state.surface();
    const graphics_canvas: graphics.Canvas = .{
        .data = this_frame_data,
        .width = canvas_width,
    };
    graphics.renderLine(surface.a, surface.b, &graphics_canvas, graphics.colorTexturer(0xff000000));
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
