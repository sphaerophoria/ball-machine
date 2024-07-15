const std = @import("std");
const physics = @import("physics");
const graphics = @import("graphics.zig");
const Ball = physics.Ball;
const Surface = physics.Surface;
const Allocator = std.mem.Allocator;

const paddle_x_margin = 0.1;
const right_paddle_x = 1.0 - paddle_x_margin;
const left_paddle_x = paddle_x_margin;
const paddle_velocity = 0.001;
const paddle_height = 0.2;

const State = struct {
    rng: ?std.rand.DefaultPrng = null,
    right_paddle_y: f32 = 0.35,
    left_paddle_y: f32 = 0.35,

    fn ensureRngInitialized(self: *State, num_balls: usize) void {
        if (self.rng != null) {
            return;
        }

        var seed: u64 = 0;
        for (balls[0..num_balls]) |ball| {
            seed +%= @intFromFloat(@abs(ball.pos.x * 1000));
            seed +%= @intFromFloat(@abs(ball.pos.y * 1000));
            seed +%= @intFromFloat(@abs(ball.velocity.x * 1000));
            seed +%= @intFromFloat(@abs(ball.velocity.y * 1000));
        }

        self.rng = std.rand.DefaultPrng.init(seed);
    }

    fn rightPaddleSurface(self: *State) Surface {
        const paddle_vert_offs = paddle_height / 2.0;
        return .{
            .a = .{
                .x = right_paddle_x,
                .y = self.right_paddle_y - paddle_vert_offs,
            },
            .b = .{
                .x = right_paddle_x,
                .y = self.right_paddle_y + paddle_vert_offs,
            },
        };
    }

    fn leftPaddleSurface(self: *State) Surface {
        const paddle_vert_offs = paddle_height / 2.0;
        return .{
            .a = .{
                .x = left_paddle_x,
                .y = self.left_paddle_y + paddle_vert_offs,
            },
            .b = .{
                .x = left_paddle_x,
                .y = self.left_paddle_y - paddle_vert_offs,
            },
        };
    }
};

var balls: []Ball = undefined;
var chamber_pixels: []u32 = undefined;
var save_data: [2]f32 = undefined;
var state = State{};

pub export fn init(max_balls: usize, max_chamber_pixels: usize) void {
    physics.assertBallLayout();
    balls = std.heap.wasm_allocator.alloc(Ball, max_balls) catch {
        return;
    };

    chamber_pixels = std.heap.wasm_allocator.alloc(u32, max_chamber_pixels) catch {
        return;
    };
}

pub export fn saveMemory() ?[*]f32 {
    return &save_data;
}

pub export fn ballsMemory() ?*void {
    return @ptrCast(balls.ptr);
}

pub export fn canvasMemory() ?*void {
    return @ptrCast(chamber_pixels.ptr);
}

pub export fn saveSize() usize {
    return std.mem.sliceAsBytes(&save_data).len;
}

pub export fn save() void {
    save_data[0] = state.left_paddle_y;
    save_data[1] = state.right_paddle_y;
}

pub export fn load() void {
    state.left_paddle_y = save_data[0];
    state.right_paddle_y = save_data[1];
}

pub export fn step(num_balls: usize, delta: f32) void {
    state.ensureRngInitialized(num_balls);
    const min_velocity = 0.3;
    const min_velocity_2 = min_velocity * min_velocity;
    const random = state.rng.?.random();

    if (num_balls < 1) {
        return;
    }

    trackPaddle(1, num_balls, &state.right_paddle_y);
    trackPaddle(-1, num_balls, &state.left_paddle_y);

    const platforms = [2]Surface{ state.rightPaddleSurface(), state.leftPaddleSurface() };

    for (platforms) |platform| {
        for (balls[0..num_balls]) |*ball| {
            if (ball.velocity.length_2() < min_velocity_2) {
                ball.velocity.x = random.float(f32) - 0.5;
                ball.velocity.y = random.float(f32) - 0.5;
                ball.velocity = ball.velocity.normalized().mul(min_velocity);
            }

            const obj_normal = platform.normal();
            const ball_collision_point_offs = obj_normal.mul(-ball.r);
            const ball_collision_point = ball.pos.add(ball_collision_point_offs);

            const resolution = platform.collisionResolution(ball_collision_point, ball.velocity.mul(delta));
            if (resolution) |r| {
                physics.applyCollision(ball, r, obj_normal, physics.Vec2.zero, delta, 0.9);
            }

            platform.pushIfColliding(ball, physics.Vec2.zero, delta, 0.001);
        }
    }
}

pub export fn render(canvas_width: usize, canvas_height: usize) void {
    const this_frame_data = chamber_pixels[0 .. canvas_width * canvas_height];
    @memset(this_frame_data, 0xffffffff);

    const graphics_canvas = graphics.Canvas{
        .data = this_frame_data,
        .width = canvas_width,
    };
    const right_paddle_surface = state.rightPaddleSurface();
    graphics.renderLine(right_paddle_surface.a, right_paddle_surface.b, &graphics_canvas, graphics.colorTexturer(0xff000000));

    const left_paddle_surface = state.leftPaddleSurface();
    graphics.renderLine(left_paddle_surface.a, left_paddle_surface.b, &graphics_canvas, graphics.colorTexturer(0xff000000));
}

const TrackingBallIt = struct {
    i: usize,
    num_balls: usize,
    dir: f32,

    fn next(self: *TrackingBallIt) ?*Ball {
        while (true) {
            if (self.i >= self.num_balls) {
                return null;
            }
            defer self.i += 1;

            const ball = &balls[self.i];
            if (ball.velocity.x * self.dir < 0) {
                continue;
            }
            return ball;
        }
    }
};

fn trackPaddle(comptime dir: comptime_int, num_balls: usize, paddle_y: *f32) void {
    var ball_it = TrackingBallIt{
        .i = 0,
        .num_balls = num_balls,
        .dir = dir,
    };
    const tracking_paddle_x = if (dir > 0) right_paddle_x else left_paddle_x;

    var tracking_ball = ball_it.next();
    while (ball_it.next()) |ball| {
        const current_dist = tracking_paddle_x - tracking_ball.?.pos.x;
        const new_dist = tracking_paddle_x - ball.pos.x;
        const is_past = new_dist * dir < 0;
        if (!is_past and @abs(new_dist) < @abs(current_dist)) {
            tracking_ball = ball;
        }
    }

    if (tracking_ball) |b| {
        const paddle_dir = std.math.sign(b.pos.y - paddle_y.*);
        paddle_y.* += paddle_velocity * paddle_dir;
    }
}
