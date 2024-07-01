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

pub const num_balls = 5;
pub const step_len_ns = 1_666_666;
pub const step_len_s: f32 = @as(f32, @floatFromInt(step_len_ns)) / 1_000_000_000;

const ball_radius = 0.025;

mutex: std.Thread.Mutex,
balls: [num_balls]Ball,
prng: std.rand.DefaultPrng,
chamber_mod: Chamber,
history: SimulationHistory,
num_steps_taken: u64,

pub fn init(alloc: Allocator, seed: usize, chamber_mod: Chamber) !Simulation {
    var prng = std.Random.DefaultPrng.init(seed);
    const balls = makeBalls(&prng);
    try chamber_mod.initChamber(num_balls);
    return .{
        .mutex = std.Thread.Mutex{},
        .num_steps_taken = 0,
        .prng = prng,
        .balls = balls,
        .history = SimulationHistory{
            .alloc = alloc,
        },
        .chamber_mod = chamber_mod,
    };
}

// History item data type

pub fn loadSnapshot(self: *Simulation, snapshot: SimulationSnapshot) !void {
    try self.chamber_mod.load(snapshot.chamber_save);

    self.balls = snapshot.balls;
    self.num_steps_taken = snapshot.num_steps_taken;
    self.prng = snapshot.prng;
}

pub fn deinit(self: *Simulation) void {
    self.history.deinit();
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

    if (self.num_steps_taken % 10 == 0) {
        self.history.push(self) catch |e| {
            std.log.err("failed to write history: {any}", .{e});
        };
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
    const max_speed = 3.0;
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

pub const SimulationSnapshot = struct {
    balls: [num_balls]Ball,
    num_steps_taken: u64,
    chamber_save: []const u8,
    prng: std.Random.DefaultPrng,
};

// NOTE sync with .save
pub const SimulationSave = struct {
    chamber_id: i64,
    steps: []SimulationSnapshot,
};

const SimulationHistory = struct {
    const num_elems = 600;
    alloc: Allocator,
    history: [num_elems]SimulationSnapshot = undefined,
    head: usize = 0,
    tail: usize = 0,

    const Iter = struct {
        history: *SimulationHistory,
        pos: usize,

        pub fn next(self: *@This()) ?*SimulationSnapshot {
            if (self.pos == self.history.history.len) {
                self.pos = 0;
            }

            if (self.pos == self.history.tail) {
                return null;
            }

            defer self.pos += 1;
            return &self.history.history[self.pos];
        }
    };

    pub fn push(self: *SimulationHistory, simulation: *Simulation) !void {
        self.history[self.tail] = .{
            .balls = simulation.balls,
            .num_steps_taken = simulation.num_steps_taken,
            .chamber_save = try simulation.chamber_mod.save(self.alloc),
            .prng = simulation.prng,
        };
        self.tail += 1;
        self.tail %= num_elems;
        if (self.tail == self.head) {
            self.alloc.free(self.history[self.head].chamber_save);
            self.head += 1;
            self.head %= num_elems;
        }
    }

    pub fn deinit(self: *SimulationHistory) void {
        var it = self.iter();
        while (it.next()) |val| {
            self.alloc.free(val.chamber_save);
        }
    }

    pub fn iter(self: *SimulationHistory) Iter {
        return .{
            .history = self,
            .pos = self.head,
        };
    }

    pub fn save(self: *SimulationHistory, chamber_db_id: i64, path: []const u8) !void {
        var output = try std.fs.cwd().createFile(path, .{});
        defer output.close();

        var buf_writer = std.io.bufferedWriter(output.writer());
        defer buf_writer.flush() catch {};

        var json_writer = std.json.writeStream(buf_writer.writer(), .{
            .whitespace = .indent_2,
        });

        try json_writer.beginObject();
        try json_writer.objectField("chamber_id");
        try json_writer.write(chamber_db_id);

        try json_writer.objectField("steps");
        try json_writer.beginArray();

        var it = self.iter();
        while (it.next()) |val| {
            try json_writer.write(val);
        }
        try json_writer.endArray();
        try json_writer.endObject();
    }
};
