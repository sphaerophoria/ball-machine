const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Chamber = @import("Chamber.zig");
const physics = @import("physics.zig");
const Pos2 = physics.Pos2;
const Vec2 = physics.Vec2;
const Ball = physics.Ball;
const Surface = physics.Surface;
const Simulation = @This();

pub const chamber_height = 0.7;
pub const num_balls = 5;
pub const step_len_ns = 1_666_666;
pub const step_len_s: f32 = @as(f32, @floatFromInt(step_len_ns)) / 1_000_000_000;

const ball_radius = 0.025;

mutex: std.Thread.Mutex,
balls: [num_balls]Ball,
prng: std.rand.DefaultPrng,
chamber_mod: Chamber,
num_steps_taken: u64,

pub fn init(seed: usize, chamber_mod: Chamber) !Simulation {
    var prng = std.Random.DefaultPrng.init(seed);
    const balls = makeBalls(&prng);
    try chamber_mod.initChamber(num_balls);
    return .{
        .mutex = std.Thread.Mutex{},
        .num_steps_taken = 0,
        .prng = prng,
        .balls = balls,
        .chamber_mod = chamber_mod,
    };
}

pub fn step(self: *Simulation) void {
    self.mutex.lock();
    defer self.mutex.unlock();

    self.num_steps_taken += 1;

    for (0..self.balls.len) |i| {
        const ball = &self.balls[i];
        applyGravity(ball, step_len_s);
        clampSpeed(ball);
        applyVelocity(ball, step_len_s);
        applyWrap(ball);
    }

    self.chamber_mod.step(&self.balls, step_len_s) catch {
        std.log.err("chamber step failed", .{});
    };

    for (0..self.balls.len) |i| {
        const ball = &self.balls[i];

        for (i + 1..self.balls.len) |j| {
            const b = &self.balls[j];
            const center_dist = b.pos.sub(ball.pos).length();
            if (center_dist < ball.r + b.r) {
                physics.applyBallCollision(ball, b);
            }
        }
    }
}

pub fn reset(self: *Simulation) void {
    self.balls = makeBalls(&self.prng);
}

fn applyGravity(ball: *Ball, delta: f32) void {
    const G = -9.832;
    ball.velocity.y += G * delta;
}

fn clampSpeed(ball: *Ball) void {
    const max_speed = 2.5;
    const max_speed_2 = max_speed * max_speed;
    const ball_speed_2 = ball.velocity.length_2();
    if (ball_speed_2 > max_speed_2) {
        const ball_speed = std.math.sqrt(ball_speed_2);
        ball.velocity = ball.velocity.mul(max_speed / ball_speed);
    }
}

fn applyVelocity(ball: *Ball, delta: f32) void {
    ball.pos = ball.pos.add(ball.velocity.mul(delta));
}

fn applyWrap(ball: *Ball) void {
    ball.pos.x = @mod(ball.pos.x, 1.0);
    ball.pos.y = @mod(ball.pos.y, 1.0);
}

fn makeBalls(rng: *std.Random.DefaultPrng) [num_balls]Ball {
    var ret: [num_balls]Ball = undefined;
    var y: f32 = ball_radius * 4;
    for (0..num_balls) |i| {
        y += ball_radius * 8;
        ret[i] = .{
            .pos = .{
                .x = rng.random().float(f32) * (1.0 - ball_radius * 2) + ball_radius,
                .y = y,
            },
            .r = ball_radius,
            .velocity = .{
                .x = 0,
                .y = 0,
            },
        };
    }
    return ret;
}
