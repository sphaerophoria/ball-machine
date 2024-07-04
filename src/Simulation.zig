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
pub const default_num_balls = 5;
pub const max_num_balls = 100;
pub const step_len_ns = 1_666_666;
pub const step_len_s: f32 = @as(f32, @floatFromInt(step_len_ns)) / 1_000_000_000;

const ball_radius = 0.025;

alloc: Allocator,
balls: std.ArrayListUnmanaged(Ball),
ball_chambers: std.ArrayListUnmanaged(usize),
prng: std.rand.DefaultPrng,
chambers: std.ArrayListUnmanaged(Chamber) = .{},
chambers_per_row: usize = 2,
num_steps_taken: u64,

pub fn init(alloc: Allocator, seed: usize) !Simulation {
    var prng = std.Random.DefaultPrng.init(seed);

    var balls = std.ArrayListUnmanaged(Ball){};
    errdefer balls.deinit(alloc);

    var ball_chambers = std.ArrayListUnmanaged(usize){};
    errdefer ball_chambers.deinit(alloc);

    try balls.resize(alloc, default_num_balls);
    try ball_chambers.resize(alloc, default_num_balls);
    randomizeBalls(&prng, balls.items, ball_chambers.items, 1);

    return .{
        .alloc = alloc,
        .num_steps_taken = 0,
        .prng = prng,
        .balls = balls,
        .ball_chambers = ball_chambers,
    };
}

pub fn deinit(self: *Simulation) void {
    self.chambers.deinit(self.alloc);
    self.balls.deinit(self.alloc);
    self.ball_chambers.deinit(self.alloc);
}

pub fn step(self: *Simulation) !void {
    self.num_steps_taken += 1;

    if (self.chambers.items.len == 0) {
        return;
    }

    for (0..self.balls.items.len) |i| {
        const ball = &self.balls.items[i];
        applyGravity(ball, step_len_s);
        clampSpeed(ball);
        applyVelocity(ball, step_len_s);
    }

    const max_idx = self.numChambers();

    for (0..max_idx) |chamber_idx| {
        var chamber_balls = try self.getChamberBalls(self.alloc, chamber_idx);
        defer chamber_balls.deinit(self.alloc);

        const chamber_balls_slice = chamber_balls.slice();

        if (chamber_idx < self.chambers.items.len) {
            try self.chambers.items[chamber_idx].step(chamber_balls_slice.items(.adjusted), step_len_s);
        }

        for (0..chamber_balls_slice.len) |k| {
            const ball = &chamber_balls_slice.items(.adjusted)[k];

            for (k + 1..chamber_balls_slice.len) |j| {
                const b = &chamber_balls_slice.items(.adjusted)[j];
                const center_dist = b.pos.sub(ball.pos).length();
                if (center_dist < ball.r + b.r) {
                    physics.applyBallCollision(ball, b);
                }
            }
        }

        for (0..chamber_balls_slice.len) |balls_view_idx| {
            const view = chamber_balls_slice.get(balls_view_idx);
            self.balls.items[view.ball_id] = getUnadjustedBall(view.adjusted, view.direction);
        }
    }

    self.applyWrap();
}

pub fn addChamber(self: *Simulation, chamber: Chamber) !void {
    try chamber.initChamber(max_num_balls);
    try self.chambers.append(self.alloc, chamber);
}

pub fn getChamberBalls(self: *const Simulation, alloc: Allocator, chamber_idx: usize) !ChamberBalls {
    var ret = ChamberBalls{};
    errdefer ret.deinit(alloc);

    const layout = self.chamberLayout();

    for (self.balls.items, 0..) |ball, ball_idx| {
        const ball_chamber_id = self.ball_chambers.items[ball_idx];

        const source_chamber = SourceDirection.fromBallAndChamber(ball, ball_chamber_id, chamber_idx, layout);

        var adjusted_ball = ball;
        switch (source_chamber) {
            .none => continue,
            .current => {},
            .left => BallAdjuster.reparentRight(&adjusted_ball),
            .right => BallAdjuster.reparentLeft(&adjusted_ball),
            .down => BallAdjuster.reparentUp(&adjusted_ball),
            .up => BallAdjuster.reparentDown(&adjusted_ball),
        }

        const ball_view = ChamberAdjustedBall{
            .adjusted = adjusted_ball,
            .ball_id = ball_idx,
            .direction = source_chamber,
        };
        try ret.append(alloc, ball_view);
    }

    return ret;
}

pub fn setNumBalls(self: *Simulation, num_balls: usize) !void {
    if (num_balls > max_num_balls) {
        return error.Invalid;
    }

    if (num_balls <= self.balls.items.len) {
        self.balls.shrinkRetainingCapacity(num_balls);
        self.ball_chambers.shrinkRetainingCapacity(num_balls);
        return;
    }

    const initial_len = self.balls.items.len;

    try self.balls.resize(self.alloc, num_balls);
    errdefer self.balls.shrinkRetainingCapacity(initial_len);

    try self.ball_chambers.resize(self.alloc, num_balls);
    errdefer self.balls.shrinkRetainingCapacity(initial_len);

    randomizeBalls(&self.prng, self.balls.items[initial_len..], self.ball_chambers.items[initial_len..], self.numChambers());
}

pub fn reset(self: *Simulation) void {
    randomizeBalls(&self.prng, self.balls.items, self.ball_chambers.items, self.numChambers());
}

pub fn numChambers(self: *const Simulation) usize {
    const num_chambers = self.chambers.items.len;
    const col_idx = (num_chambers % self.chambers_per_row);
    const remaining_cols_in_row = self.chambers_per_row - col_idx;
    return num_chambers + (remaining_cols_in_row % self.chambers_per_row);
}

pub fn setChambersPerRow(self: *Simulation, num_chambers: usize) void {
    self.chambers_per_row = num_chambers;
}

fn chamberLayout(self: Simulation) ChamberLayout {
    return .{
        .chambers_per_row = self.chambers_per_row,
        .num_chambers = self.numChambers(),
    };
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

fn applyWrap(self: *Simulation) void {
    const layout = self.chamberLayout();
    for (self.balls.items, 0..) |*ball, i| {
        var ball_chamber: usize = self.ball_chambers.items[i];

        while (ball.pos.x > 1.0) {
            ball_chamber = layout.right(ball_chamber);
            ball.pos.x -= 1.0;
        }
        while (ball.pos.x < 0.0) {
            ball_chamber = layout.left(ball_chamber);
            ball.pos.x += 1.0;
        }

        while (ball.pos.y < 0.0) {
            ball_chamber = layout.down(ball_chamber);
            ball.pos.y += chamber_height;
        }

        while (ball.pos.y > chamber_height) {
            ball_chamber = layout.up(ball_chamber);
            ball.pos.y -= chamber_height;
        }

        self.ball_chambers.items[i] = ball_chamber;
    }
}

const SourceDirection = enum {
    none,
    current,
    left,
    right,
    up,
    down,

    fn fromBallAndChamber(ball: Ball, ball_chamber_id: usize, chamber_idx: usize, layout: ChamberLayout) SourceDirection {
        if (ball_chamber_id == chamber_idx) {
            return .current;
        }

        const is_touching_left_chamber = ball.pos.x < ball.r;
        if (is_touching_left_chamber and layout.left(ball_chamber_id) == chamber_idx) {
            return .right;
        }

        const is_touching_right_chamber = ball.pos.x + ball.r > 1.0;
        if (is_touching_right_chamber and layout.right(ball_chamber_id) == chamber_idx) {
            return .left;
        }

        const is_touching_top_chamber = ball.pos.y + ball.r > chamber_height;
        if (is_touching_top_chamber and layout.up(ball_chamber_id) == chamber_idx) {
            return .down;
        }

        const is_touching_bottom_chamber = ball.pos.y < ball.r;
        if (is_touching_bottom_chamber and layout.down(ball_chamber_id) == chamber_idx) {
            return .up;
        }

        return .none;
    }
};

// A ball that is at least partially in our chamber, with the ball moved into
// our chamber's coordinate system
const ChamberAdjustedBall = struct {
    // Position in our chamber
    adjusted: Ball,
    // ID in global balls list
    ball_id: usize,
    // Where did the ball come from, relative to our chamber
    direction: SourceDirection,
};

pub const ChamberBalls = std.MultiArrayList(ChamberAdjustedBall);

// NOTE: All math here may feel backwards. Just remember that if a ball is
// moving left one chamber, it has to keep it's absolute location. Our
// coordinate system is moving to the left, so the ball is effectively moving
// to the right
const BallAdjuster = struct {
    fn reparentRight(ball: *Ball) void {
        ball.pos.x -= 1.0;
    }

    fn reparentLeft(ball: *Ball) void {
        ball.pos.x += 1.0;
    }

    fn reparentUp(ball: *Ball) void {
        ball.pos.y -= chamber_height;
    }

    fn reparentDown(ball: *Ball) void {
        ball.pos.y += chamber_height;
    }
};

fn getUnadjustedBall(adjusted_ball: Ball, direction: SourceDirection) Ball {
    var unadjusted = adjusted_ball;
    switch (direction) {
        .none => unreachable,
        .current => {},
        .right => BallAdjuster.reparentRight(&unadjusted),
        .left => BallAdjuster.reparentLeft(&unadjusted),
        .up => BallAdjuster.reparentUp(&unadjusted),
        .down => BallAdjuster.reparentDown(&unadjusted),
    }
    return unadjusted;
}

const ChamberLayout = struct {
    chambers_per_row: usize,
    num_chambers: usize,

    pub fn left(self: ChamberLayout, id: usize) usize {
        if (id % self.chambers_per_row == 0) {
            return (id + self.chambers_per_row - 1) % self.num_chambers;
        } else {
            return id - 1;
        }
    }

    pub fn right(self: ChamberLayout, id: usize) usize {
        if ((id + 1) % self.chambers_per_row == 0) {
            return (id + 1 - self.chambers_per_row) % self.num_chambers;
        } else {
            return (id + 1) % self.num_chambers;
        }
    }

    pub fn up(self: ChamberLayout, id: usize) usize {
        // assume num_chambers % chambers_per_row == 0
        if (id < self.chambers_per_row) {
            const tmp = id + @max(self.num_chambers, self.chambers_per_row);
            return tmp - self.chambers_per_row;
        }
        return id - self.chambers_per_row;
    }

    pub fn down(self: ChamberLayout, id: usize) usize {
        return (id + self.chambers_per_row) % self.num_chambers;
    }
};

fn randomizeBalls(rng: *std.Random.DefaultPrng, balls: []Ball, chamber_ids: []usize, num_chambers: usize) void {
    var y: f32 = ball_radius * 4;
    for (balls) |*ball| {
        y += ball_radius * 8;
        ball.* = .{
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

    for (chamber_ids) |*chamber_id| {
        chamber_id.* = rng.random().intRangeAtMost(usize, 0, num_chambers - 1);
    }
}
