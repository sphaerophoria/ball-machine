const std = @import("std");

const ball_start_y = 0.7;
const ball_radius = 0.03;

pub fn pathToContentType(path: []const u8) ![]const u8 {
    const Extension = enum {
        @".js",
        @".html",
    };

    inline for (std.meta.fields(Extension)) |field| {
        if (std.mem.endsWith(u8, path, field.name)) {
            const enumVal: Extension = @enumFromInt(field.value);
            switch (enumVal) {
                .@".js" => return "text/javascript",
                .@".html" => return "text/html",
            }
        }
    }

    return error.Unimplemented;
}

pub fn getResource(path: []const u8) !std.fs.File {
    var dir = try std.fs.cwd().openDir("src/res", .{});
    defer dir.close();
    return dir.openFile(path[1..], .{});
}

pub fn handleConnection(connection: std.net.Server.Connection, ball: *const Ball) !void {
    var read_buffer: [4096]u8 = undefined;
    var http_server = std.http.Server.init(connection, &read_buffer);

    var req = try http_server.receiveHead();

    if (std.mem.eql(u8, req.head.target, "/ball")) {
        var send_buffer: [4096]u8 = undefined;
        var response = req.respondStreaming(.{
            .send_buffer = &send_buffer,
            .respond_options = .{
                .extra_headers = &.{.{
                    .name = "Content-Type",
                    .value = "application/json",
                }},
            },
        });
        try std.json.stringify(ball.*, .{}, response.writer());
        try response.end();
        return;
    }

    var f = try getResource(req.head.target);
    defer f.close();

    var send_buffer: [4096]u8 = undefined;
    var response = req.respondStreaming(.{
        .send_buffer = &send_buffer,
        .respond_options = .{
            .extra_headers = &.{.{
                .name = "Content-Type",
                .value = try pathToContentType(req.head.target),
            }},
        },
    });

    var fifo = std.fifo.LinearFifo(u8, .{ .Static = 4096 }).init();
    try fifo.pump(f.reader(), response.writer());

    try response.end();
}

const Pos2 = struct {
    x: f32,
    y: f32,

    fn add(p: Pos2, v: Vec2) Pos2 {
        return .{
            .x = p.x + v.x,
            .y = p.y + v.y,
        };
    }

    fn sub(a: Pos2, b: Pos2) Vec2 {
        return .{
            .x = a.x - b.x,
            .y = a.y - b.y,
        };
    }
};

const Vec2 = struct {
    x: f32,
    y: f32,

    fn length_2(self: Vec2) f32 {
        return self.x * self.x + self.y * self.y;
    }

    fn length(self: Vec2) f32 {
        return std.math.sqrt(self.length_2());
    }

    fn mul(self: Vec2, val: f32) Vec2 {
        return .{
            .x = self.x * val,
            .y = self.y * val,
        };
    }
};

const Ball = struct { pos: Pos2, r: f32, velocity: Vec2 };

const PositionHistory = struct {
    samples: [10]Pos2 = undefined,
    sample_idx: usize = 0,
    num_samples: usize = 0,

    fn pushSample(self: *PositionHistory, pos: Pos2) void {
        self.samples[self.sample_idx] = pos;

        self.sample_idx += 1;
        self.sample_idx %= self.samples.len;

        self.num_samples += 1;
        self.num_samples = @min(self.num_samples, self.samples.len);
    }

    fn maxMovement(self: *PositionHistory) ?f32 {
        if (self.num_samples < 2) {
            return null;
        }

        var max_len_2: f32 = 0.0;
        var last_idx = self.sample_idx;
        for (1..self.num_samples) |i| {
            const this_idx = (self.sample_idx + i) % self.samples.len;
            const a = self.samples[last_idx];
            const b = self.samples[this_idx];

            const movement = b.sub(a);
            const this_len_2 = movement.length_2();
            if (this_len_2 > max_len_2) {
                max_len_2 = this_len_2;
            }

            last_idx = this_idx;
        }

        return std.math.sqrt(max_len_2);
    }
};

const Simulation = struct {
    mutex: std.Thread.Mutex,
    ball: Ball,
    pos_history: PositionHistory,

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

    fn applyCollision(ball: *Ball) void {
        if (ball.pos.y < ball.r) {
            const distance_into_ground = ball.r - ball.pos.y;
            ball.pos.y = ball.r + distance_into_ground;
            ball.velocity.y *= -0.85;
        }
    }

    fn resetIfDead(self: *Simulation) void {
        self.pos_history.pushSample(self.ball.pos);

        const max_movement = self.pos_history.maxMovement();
        if (max_movement != null and max_movement.? < 0.00001) {
            self.ball.pos.y = ball_start_y;
            self.ball.velocity.x = 0;
            self.ball.velocity.y = 0;
        }
    }

    fn step(self: *Simulation, delta: f32) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        applyGravity(&self.ball, delta);
        clampSpeed(&self.ball);
        applyVelocity(&self.ball, delta);
        applyCollision(&self.ball);

        self.resetIfDead();
    }
};

pub fn runSimulation(ctx: *Simulation) !void {
    var last = try std.time.Instant.now();

    while (true) {
        std.time.sleep(1_666_666);
        const now = try std.time.Instant.now();
        const delta_ns: f32 = @floatFromInt(now.since(last));
        const delta_s = delta_ns / 1e9;
        ctx.step(delta_s);
        last = now;
    }
}

pub fn main() !void {
    const addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 8000);
    var tcp_server = try addr.listen(.{
        .reuse_address = true,
        .reuse_port = true,
    });

    var simulation_ctx = Simulation{ .mutex = std.Thread.Mutex{}, .pos_history = PositionHistory{}, .ball = Ball{
        .pos = .{
            .x = 0.5,
            .y = ball_start_y,
        },
        .r = ball_radius,
        .velocity = .{
            .x = 0,
            .y = 0,
        },
    } };

    const thread = try std.Thread.spawn(.{}, runSimulation, .{&simulation_ctx});
    defer thread.join();

    while (true) {
        const connection = try tcp_server.accept();
        defer connection.stream.close();

        simulation_ctx.mutex.lock();
        const ball = simulation_ctx.ball;
        simulation_ctx.mutex.unlock();
        handleConnection(connection, &ball) catch |e| {
            std.log.err("Failed to handle connection: {any}", .{e});
        };
    }
}
