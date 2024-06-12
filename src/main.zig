const std = @import("std");
const builtin = @import("builtin");
const resources = @import("resources");
const Allocator = std.mem.Allocator;
const wasm_chamber = @import("wasm_chamber.zig");
const physics = @import("physics.zig");
const Pos2 = physics.Pos2;
const Vec2 = physics.Vec2;
const Ball = physics.Ball;
const Surface = physics.Surface;

const ball_start_x = 0.5;
const ball_start_y = 0.7;
const ball_radius = 0.025;

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
        @".wasm",
    };

    inline for (std.meta.fields(Extension)) |field| {
        if (std.mem.endsWith(u8, path, field.name)) {
            const enumVal: Extension = @enumFromInt(field.value);
            switch (enumVal) {
                .@".js" => return "text/javascript",
                .@".html" => return "text/html",
                .@".wasm" => return "application/wasm",
            }
        }
    }

    return error.Unimplemented;
}

pub fn getResourcePathAlloc(alloc: Allocator, root: []const u8, path: []const u8) ![]const u8 {
    var dir = try std.fs.cwd().openDir(root, .{});
    defer dir.close();

    const real_path = try dir.realpathAlloc(alloc, path[1..]);
    errdefer alloc.free(real_path);

    const root_real_path = try std.fs.realpathAlloc(alloc, root);
    defer alloc.free(root_real_path);

    if (!std.mem.startsWith(u8, real_path, root_real_path)) {
        return error.InvalidPath;
    }

    return real_path;
}

fn respondWithFileContents(req: *std.http.Server.Request, path: []const u8) !void {
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

    const f = try std.fs.cwd().openFile(path, .{});
    var fifo = std.fifo.LinearFifo(u8, .{ .Static = 4096 }).init();
    try fifo.pump(f.reader(), response.writer());
    try response.end();
    return;
}

pub fn handleConnection(alloc: Allocator, www_root: ?[]const u8, chamber_path: []const u8, connection: std.net.Server.Connection, simulation: *Simulation) !void {
    var read_buffer: [4096]u8 = undefined;
    var http_server = std.http.Server.init(connection, &read_buffer);

    var req = try http_server.receiveHead();

    if (std.mem.eql(u8, req.head.target, "/simulation_state")) {
        const ResponseJson = struct {
            balls: [num_balls]Ball,
            chamber_state: []const u8,
        };

        var chamber_save: []const u8 = &.{};
        defer alloc.free(chamber_save);

        const response_content = blk: {
            simulation.mutex.lock();
            defer simulation.mutex.unlock();

            chamber_save = try simulation.chamber_mod.save(alloc, simulation.chamber_state);

            break :blk ResponseJson{
                .balls = simulation.balls,
                .chamber_state = chamber_save,
            };
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
        try std.json.stringify(response_content, .{ .emit_strings_as_arrays = true }, response.writer());
        try response.end();
        return;
    } else if (std.mem.eql(u8, req.head.target, "/save")) {
        simulation.mutex.lock();
        defer simulation.mutex.unlock();
        try simulation.history.save("history.json");
        try req.respond("", .{});
        return;
    } else if (std.mem.eql(u8, req.head.target, "/chamber.wasm")) {
        try respondWithFileContents(&req, chamber_path);
        return;
    }

    if (www_root) |root| {
        if (getResourcePathAlloc(alloc, root, req.head.target)) |p| {
            defer alloc.free(p);
            try respondWithFileContents(&req, p);
            return;
        } else |_| {
            std.log.err("{s} not found in resource dir, falling back to embedded", .{req.head.target});
        }
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
    const content = try embeddedLookup(req.head.target);
    try response.writer().writeAll(content);
    try response.end();
}

const SimulationSnapshot = struct {
    balls: [num_balls]Ball,
    num_steps_taken: u64,
    chamber_save: []const u8,
    prng: std.Random.DefaultPrng,
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
            .chamber_save = try simulation.chamber_mod.save(self.alloc, simulation.chamber_state),
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

    pub fn save(self: *SimulationHistory, path: []const u8) !void {
        var output = try std.fs.cwd().createFile(path, .{});
        defer output.close();

        var buf_writer = std.io.bufferedWriter(output.writer());
        defer buf_writer.flush() catch {};

        var json_writer = std.json.writeStream(buf_writer.writer(), .{
            .whitespace = .indent_2,
        });
        try json_writer.beginArray();

        var it = self.iter();
        while (it.next()) |val| {
            try json_writer.write(val);
        }
        try json_writer.endArray();
    }
};

const Simulation = struct {
    mutex: std.Thread.Mutex,
    balls: [num_balls]Ball,
    prng: std.rand.DefaultPrng,
    chamber_mod: wasm_chamber.WasmChamber,
    chamber_state: i32,
    history: SimulationHistory,
    num_steps_taken: u64,

    const step_len_ns = 1_666_666;
    const step_len_s: f32 = @as(f32, @floatFromInt(step_len_ns)) / 1_000_000_000;

    fn deinit(self: *Simulation) void {
        self.history.deinit();
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

    fn step(self: *Simulation) void {
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

        self.chamber_mod.step(self.chamber_state, &self.balls, step_len_s) catch {
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

        if (self.num_steps_taken % 4800 == 0) {
            self.balls = makeBalls(&self.prng);
        }

        if (self.num_steps_taken % 10 == 0) {
            self.history.push(self) catch |e| {
                std.log.err("failed to write history: {any}", .{e});
            };
        }
    }
};

pub fn runSimulation(ctx: *Simulation, shutdown: *std.atomic.Value(bool)) !void {
    const start = try std.time.Instant.now();
    const initial_step = ctx.num_steps_taken;
    while (!shutdown.load(.unordered)) {
        std.time.sleep(1_666_666);

        const now = try std.time.Instant.now();
        const elapsed_time_ns = now.since(start);

        const desired_num_steps_taken = initial_step + elapsed_time_ns / Simulation.step_len_ns;

        while (ctx.num_steps_taken < desired_num_steps_taken) {
            ctx.step();
        }
    }
}

fn signal_handler(_: c_int) align(1) callconv(.C) void {}

const Args = struct {
    chamber: []const u8,
    www_root: ?[]const u8,
    port: u16,
    history_file: ?[]const u8,
    history_start_idx: usize,
    it: std.process.ArgIterator,

    const Option = enum {
        @"--chamber",
        @"--www-root",
        @"--port",
        @"--load",
        @"--help",
    };

    pub fn parse(alloc: Allocator) !Args {
        var it = try std.process.argsWithAllocator(alloc);
        const process_name = it.next() orelse "ball-machine";

        var www_root: ?[]const u8 = null;
        var port: ?u16 = null;
        var history_file: ?[]const u8 = null;
        var history_start_idx: usize = 0;
        var chamber: ?[]const u8 = null;

        while (it.next()) |arg| {
            const option = std.meta.stringToEnum(Option, arg) orelse {
                print("{s} is not a valid argument\n", .{arg});
                help(process_name);
            };
            switch (option) {
                .@"--chamber" => {
                    chamber = it.next() orelse {
                        print("--chamber provided with no argument\n", .{});
                        help(process_name);
                    };
                },
                .@"--www-root" => {
                    www_root = it.next();
                },
                .@"--load" => {
                    history_file = it.next() orelse {
                        print("--load provided with no history file\n", .{});
                        help(process_name);
                    };

                    const history_start_idx_s = it.next() orelse {
                        print("--load provided with no history idx\n", .{});
                        help(process_name);
                    };

                    history_start_idx = std.fmt.parseInt(usize, history_start_idx_s, 10) catch {
                        print("history start index is not a valid usize\n", .{});
                        help(process_name);
                    };
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
            .chamber = chamber orelse {
                print("--chamber not provied\n", .{});
                help(process_name);
            },
            .www_root = www_root,
            .port = port orelse {
                print("--port not provied\n", .{});
                help(process_name);
            },
            .history_file = history_file,
            .history_start_idx = history_start_idx,
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
                .@"--chamber" => {
                    print("Which chamber to run", .{});
                },
                .@"--www-root" => {
                    print("Optional, where to serve html from", .{});
                },
                .@"--load" => {
                    print("Optional (--load history.json idx), history file + index of where to start simulation", .{});
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

const num_balls = 5;

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

    var seed: usize = undefined;
    try std.posix.getrandom(std.mem.asBytes(&seed));
    var prng = std.Random.DefaultPrng.init(seed);
    const balls = makeBalls(&prng);

    var wasm_loader = try wasm_chamber.WasmLoader.init();
    defer wasm_loader.deinit();

    const chamber_f = try std.fs.cwd().openFile(args.chamber, .{});
    defer chamber_f.close();
    const chamber_content = try chamber_f.readToEndAlloc(alloc, 1_000_000);
    defer alloc.free(chamber_content);

    var chamber_mod = try wasm_loader.load(alloc, chamber_content);
    defer chamber_mod.deinit();

    const chamber_state = try chamber_mod.initChamber();

    var simulation_ctx = Simulation{
        .mutex = std.Thread.Mutex{},
        .num_steps_taken = 0,
        .prng = prng,
        .balls = balls,
        .history = SimulationHistory{
            .alloc = alloc,
        },
        .chamber_mod = chamber_mod,
        .chamber_state = chamber_state,
    };
    defer simulation_ctx.deinit();

    if (args.history_file) |history_file_path| {
        const f = try std.fs.cwd().openFile(history_file_path, .{});
        var json_reader = std.json.reader(alloc, f.reader());
        defer json_reader.deinit();

        const parsed = try std.json.parseFromTokenSource(std.json.Value, alloc, &json_reader, .{});
        defer parsed.deinit();

        if (parsed.value != .array) {
            return error.InvalidRecording;
        }

        if (args.history_start_idx >= parsed.value.array.items.len) {
            return error.InvalidStartIdx;
        }

        const val = parsed.value.array.items[args.history_start_idx];
        const parsed_snapshot = try std.json.parseFromValue(SimulationSnapshot, alloc, val, .{});
        defer parsed_snapshot.deinit();

        simulation_ctx.prng = parsed_snapshot.value.prng;
        simulation_ctx.balls = parsed_snapshot.value.balls;
        simulation_ctx.num_steps_taken = parsed_snapshot.value.num_steps_taken;
        try chamber_mod.deinitChamber(simulation_ctx.chamber_state);
        simulation_ctx.chamber_state = try chamber_mod.load(parsed_snapshot.value.chamber_save);
    }

    var shutdown = std.atomic.Value(bool).init(false);
    const thread = try std.Thread.spawn(.{}, runSimulation, .{ &simulation_ctx, &shutdown });
    defer thread.join();
    defer shutdown.store(true, .unordered);

    while (true) {
        var fds: [1]std.posix.pollfd = .{.{ .fd = tcp_server.stream.handle, .events = std.posix.POLL.IN, .revents = 0 }};
        _ = try std.posix.ppoll(&fds, null, null);
        const connection = try tcp_server.accept();
        defer connection.stream.close();

        handleConnection(alloc, args.www_root, args.chamber, connection, &simulation_ctx) catch |e| {
            std.log.err("Failed to handle connection: {any}", .{e});
        };
    }
}
