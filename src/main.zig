const std = @import("std");
const resources = @import("resources");
const Allocator = std.mem.Allocator;

const ball_start_x = 0.3;
const ball_start_y = 0.7;
const ball_radius = 0.03;

fn embeddedLookup(path: []const u8) ![]const u8 {
    const path_rel = path[1..];
    for (resources.resources) |elem| {
        if (std.mem.eql(u8, elem.path, path_rel)) {
            return elem.data;
        }
    }
    std.log.err("No file {s} embedded in application", .{path});
    return error.InvalidPath;
}

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

pub fn getResource(alloc: Allocator, root: []const u8, path: []const u8) !std.fs.File {
    var dir = try std.fs.cwd().openDir(root, .{});
    defer dir.close();

    const real_path = try dir.realpathAlloc(alloc, path[1..]);
    defer alloc.free(real_path);

    const root_real_path = try std.fs.realpathAlloc(alloc, root);
    defer alloc.free(root_real_path);

    if (!std.mem.startsWith(u8, real_path, root_real_path)) {
        return error.InvalidPath;
    }

    return std.fs.openFileAbsolute(real_path, .{});
}

pub fn handleConnection(alloc: Allocator, www_root: ?[]const u8, connection: std.net.Server.Connection, ball: *const Ball, collision_objects: []const Surface) !void {
    var read_buffer: [4096]u8 = undefined;
    var http_server = std.http.Server.init(connection, &read_buffer);

    var req = try http_server.receiveHead();

    if (std.mem.eql(u8, req.head.target, "/simulation_state")) {
        const ResponseJson = struct {
            ball: Ball,
            collision_objects: []const Surface,
        };
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
        try std.json.stringify(ResponseJson{ .ball = ball.*, .collision_objects = collision_objects }, .{}, response.writer());
        try response.end();
        return;
    }

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

    if (www_root) |root| {
        if (getResource(alloc, root, req.head.target)) |f| {
            var fifo = std.fifo.LinearFifo(u8, .{ .Static = 4096 }).init();
            try fifo.pump(f.reader(), response.writer());
            try response.end();
            return;
        } else |_| {
            std.log.err("{s} not found in resource dir, falling back to embedded", .{req.head.target});
        }
    }

    const content = try embeddedLookup(req.head.target);
    try response.writer().writeAll(content);
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

    fn add(a: Vec2, b: Vec2) Vec2 {
        return .{
            .x = a.x + b.x,
            .y = a.y + b.y,
        };
    }

    fn mul(self: Vec2, val: f32) Vec2 {
        return .{
            .x = self.x * val,
            .y = self.y * val,
        };
    }

    fn dot(a: Vec2, b: Vec2) f32 {
        return a.x * b.x + a.y * b.y;
    }

    fn normalized(self: Vec2) Vec2 {
        return self.mul(1.0 / self.length());
    }
};

const Ball = struct { pos: Pos2, r: f32, velocity: Vec2 };

const Surface = struct {
    // Assumed normal points up if a is left of b, down if b is left of a
    a: Pos2,
    b: Pos2,

    // Find intersection point between an object at point P, given that it
    // moved with velocity v
    fn intersectionPoint(self: *const Surface, p: Pos2, v: Vec2) Pos2 {
        //                          b
        //         \       | v  _-^
        //          \      | _-^
        //          n\    _-^
        //            \_-^ |
        //          _-^\   |
        //       _-^    \  | res
        //  a _-^      l \o|
        //     ^^^^----___\|
        //                 p
        //
        // (note that n is perpendicular to a/b)
        //
        // * Use projection of ap onto n, that gives us line l
        // * With n and v we can find angle o
        // * With angle o and l, we can find res
        //

        const ap = self.a.sub(p);
        const n = self.normal();
        const v_norm_neg = v.mul(-1.0 / v.length());
        const cos_o = n.dot(v_norm_neg);

        const l = ap.dot(n);
        const intersection_dist = l / cos_o;

        const adjustment = v_norm_neg.mul(intersection_dist);
        return p.add(adjustment);
    }

    fn normal(self: *const Surface) Vec2 {
        var v = self.b.sub(self.a);
        v = v.mul(1.0 / v.length());

        return .{
            .x = -v.y,
            .y = v.x,
        };
    }
};

const Simulation = struct {
    mutex: std.Thread.Mutex,
    ball: Ball,
    prng: std.rand.DefaultPrng,
    collision_objects: [2]Surface,
    duration: f32,

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

    fn applyCollision(ball: *Ball, collision_objects: []const Surface, delta: f32) void {
        for (collision_objects) |obj| {
            const obj_normal = obj.normal();
            const ball_collision_point_offs = obj_normal.mul(-ball.r);
            const ball_collision_point = ball.pos.add(ball_collision_point_offs);

            const above_line = obj.a.sub(ball_collision_point).dot(obj_normal) < 0;
            if (above_line) {
                continue;
            }

            const ball_line_intersection_point = obj.intersectionPoint(ball_collision_point, ball.velocity);

            const collided = (obj.a.x < ball_line_intersection_point.x) != (obj.b.x < ball_line_intersection_point.x);

            if (collided) {
                const vel_ground_proj_mag = ball.velocity.dot(obj_normal);
                const vel_adjustment = obj_normal.mul(-vel_ground_proj_mag * 2);

                ball.velocity = ball.velocity.add(vel_adjustment);
                const lost_velocity = 0.15 * (@abs(obj_normal.dot(ball.velocity.normalized())));
                ball.velocity = ball.velocity.mul(1.0 - lost_velocity);

                ball.pos = ball_line_intersection_point.add(ball_collision_point_offs.mul(-1.0));
                ball.pos = ball.pos.add(ball.velocity.mul(delta));
            }
        }
    }

    fn resetAfterTimeout(self: *Simulation) void {
        if (self.duration > 5.0) {
            self.duration = 0.0;
            self.ball.pos.x = self.prng.random().float(f32);
            self.ball.pos.y = ball_start_y;
            self.ball.velocity.x = self.prng.random().float(f32);
            self.ball.velocity.y = 0;

            self.collision_objects = .{
                .{
                    .a = .{
                        .x = 0.0,
                        .y = self.prng.random().float(f32),
                    },
                    .b = .{
                        .x = 0.5,
                        .y = 0.0,
                    },
                },
                .{
                    .a = .{
                        .x = 0.5,
                        .y = 0.0,
                    },
                    .b = .{
                        .x = 1.0,
                        .y = self.prng.random().float(f32),
                    },
                },
            };
        }
    }

    fn step(self: *Simulation, delta: f32) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.duration += delta;

        applyGravity(&self.ball, delta);
        clampSpeed(&self.ball);
        applyVelocity(&self.ball, delta);
        applyCollision(&self.ball, &self.collision_objects, delta);
        self.resetAfterTimeout();
    }
};

pub fn runSimulation(ctx: *Simulation, shutdown: *std.atomic.Value(bool)) !void {
    var last = try std.time.Instant.now();

    while (!shutdown.load(.unordered)) {
        std.time.sleep(1_666_666);
        const now = try std.time.Instant.now();
        const delta_ns: f32 = @floatFromInt(now.since(last));
        const delta_s = delta_ns / 1e9;
        ctx.step(delta_s);
        last = now;
    }
}

fn signal_handler(_: c_int) align(1) callconv(.C) void {}

const Args = struct {
    www_root: ?[]const u8,
    port: u16,
    it: std.process.ArgIterator,

    const Option = enum {
        @"--www-root",
        @"--port",
        @"--help",
    };

    pub fn parse(alloc: Allocator) !Args {
        var it = try std.process.argsWithAllocator(alloc);
        const process_name = it.next() orelse "ball-machine";

        var www_root: ?[]const u8 = null;
        var port: ?u16 = null;

        while (it.next()) |arg| {
            const option = std.meta.stringToEnum(Option, arg) orelse {
                print("{s} is not a valid argument\n", .{arg});
                help(process_name);
            };
            switch (option) {
                .@"--www-root" => {
                    www_root = it.next();
                },
                .@"--port" => {
                    const port_s = it.next() orelse {
                        print("--port provided with no argument\n", .{});
                        help(process_name);
                    };
                    port = std.fmt.parseInt(u16, port_s, 10) catch {
                        print("--port argument is not a valid u16\n", .{});
                        help(process_name);
                    };
                },
                .@"--help" => {
                    help(process_name);
                },
            }
        }

        return .{
            .www_root = www_root,
            .port = port orelse {
                print("--port not provied\n", .{});
                help(process_name);
            },
            .it = it,
        };
    }

    pub fn deinit(self: *Args) void {
        self.it.deinit();
    }

    fn help(process_name: []const u8) noreturn {
        print(
            \\Usage: {s} [ARGS]
            \\
            \\Args:
            \\
        , .{process_name});

        inline for (std.meta.fields(Option)) |option| {
            print("{s}: ", .{option.name});
            const option_val: Option = @enumFromInt(option.value);
            switch (option_val) {
                .@"--www-root" => {
                    print("Optional, where to serve html from", .{});
                },
                .@"--port" => {
                    print("Which port to run the webserver on", .{});
                },
                .@"--help" => {
                    print("Show this help", .{});
                },
            }
            print("\n", .{});
        }
        std.process.exit(1);
    }

    fn print(comptime fmt: []const u8, args: anytype) void {
        const f = std.io.getStdErr();
        f.writer().print(fmt, args) catch {};
    }
};

pub fn main() !void {
    var sa = std.posix.Sigaction{
        .handler = .{
            .handler = &signal_handler,
        },
        .mask = std.posix.empty_sigset,
        .flags = 0,
    };

    try std.posix.sigaction(std.posix.SIG.INT, &sa, null);

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const alloc = gpa.allocator();

    var args = try Args.parse(alloc);
    defer args.deinit();

    const addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, args.port);
    var tcp_server = try addr.listen(.{
        .reuse_address = true,
        .reuse_port = true,
    });

    var simulation_ctx = Simulation{
        .mutex = std.Thread.Mutex{},
        .duration = 0.0,
        .ball = Ball{
            .pos = .{
                .x = ball_start_x,
                .y = ball_start_y,
            },
            .r = ball_radius,
            .velocity = .{
                .x = 0,
                .y = 0,
            },
        },
        .prng = std.rand.DefaultPrng.init(@intCast(std.time.timestamp())),
        .collision_objects = .{
            .{
                .a = .{
                    .x = 0.0,
                    .y = 0.5,
                },
                .b = .{
                    .x = 0.5,
                    .y = 0.0,
                },
            },
            .{
                .a = .{
                    .x = 0.5,
                    .y = 0.0,
                },
                .b = .{
                    .x = 1.0,
                    .y = 0.5,
                },
            },
        },
    };

    var shutdown = std.atomic.Value(bool).init(false);
    const thread = try std.Thread.spawn(.{}, runSimulation, .{ &simulation_ctx, &shutdown });
    defer thread.join();
    defer shutdown.store(true, .unordered);

    while (true) {
        var fds: [1]std.posix.pollfd = .{.{ .fd = tcp_server.stream.handle, .events = std.posix.POLL.IN, .revents = 0 }};
        _ = try std.posix.ppoll(&fds, null, null);
        const connection = try tcp_server.accept();
        defer connection.stream.close();

        simulation_ctx.mutex.lock();
        const ball = simulation_ctx.ball;
        const collision_objects = simulation_ctx.collision_objects;
        simulation_ctx.mutex.unlock();
        handleConnection(alloc, args.www_root, connection, &ball, &collision_objects) catch |e| {
            std.log.err("Failed to handle connection: {any}", .{e});
        };
    }
}
