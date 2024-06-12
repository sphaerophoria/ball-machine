const std = @import("std");
const builtin = @import("builtin");
const resources = @import("resources");
const Allocator = std.mem.Allocator;
const wasm_chamber = @import("wasm_chamber.zig");
const physics = @import("physics.zig");
const Simulation = @import("Simulation.zig");
const Ball = physics.Ball;

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

const UrlComponents = struct {
    id: usize,
    target: []const u8,
};

fn isTaggedRequest(target: []const u8) ?UrlComponents {
    if (target.len < 1 or target[0] != '/') {
        return null;
    }

    var end = std.mem.indexOfScalar(u8, target[1..], '/') orelse {
        return null;
    };
    end += 1;

    const id = std.fmt.parseInt(usize, target[1..end], 10) catch {
        return null;
    };

    return .{
        .id = id,
        .target = target[end..],
    };
}

pub fn handleConnection(alloc: Allocator, www_root: ?[]const u8, chamber_paths: []const []const u8, connection: std.net.Server.Connection, simulations: []Simulation) !void {
    var read_buffer: [4096]u8 = undefined;
    var http_server = std.http.Server.init(connection, &read_buffer);

    var req = try http_server.receiveHead();

    if (std.mem.eql(u8, req.head.target, "/num_simulations")) {
        var buf: [6]u8 = undefined;
        const num_sims_s = try std.fmt.bufPrint(&buf, "{d}", .{simulations.len});
        try req.respond(num_sims_s, .{
            .extra_headers = &.{.{
                .name = "Content-Type",
                .value = "application/json",
            }},
        });
        return;
    }

    if (isTaggedRequest(req.head.target)) |tagged_url| {
        if (tagged_url.id >= simulations.len) {
            return error.InvalidId;
        }
        const simulation = &simulations[tagged_url.id];
        const target = tagged_url.target;

        if (std.mem.eql(u8, target, "/simulation_state")) {
            const ResponseJson = struct {
                balls: [Simulation.num_balls]Ball,
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
        } else if (std.mem.eql(u8, target, "/save")) {
            simulation.mutex.lock();
            defer simulation.mutex.unlock();
            try simulation.history.save("history.json");
            try req.respond("", .{});
            return;
        } else if (std.mem.eql(u8, target, "/chamber.wasm")) {
            try respondWithFileContents(&req, chamber_paths[tagged_url.id]);
            return;
        }
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

pub fn runSimulation(simulations: []Simulation, shutdown: *std.atomic.Value(bool)) !void {
    const start = try std.time.Instant.now();

    const initial_step = simulations[0].num_steps_taken;
    std.debug.assert(simulations.len == 1 or initial_step == 0);

    while (!shutdown.load(.unordered)) {
        std.time.sleep(1_666_666);

        const now = try std.time.Instant.now();
        const elapsed_time_ns = now.since(start);

        const desired_num_steps_taken = initial_step + elapsed_time_ns / Simulation.step_len_ns;

        for (simulations) |*ctx| {
            while (ctx.num_steps_taken < desired_num_steps_taken) {
                ctx.step();
            }
        }
    }
}

fn signal_handler(_: c_int) align(1) callconv(.C) void {}

const Args = struct {
    alloc: Allocator,
    chambers: []const []const u8,
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
        var chambers = std.ArrayList([]const u8).init(alloc);
        errdefer chambers.deinit();

        while (it.next()) |arg| {
            const option = std.meta.stringToEnum(Option, arg) orelse {
                print("{s} is not a valid argument\n", .{arg});
                help(process_name);
            };
            switch (option) {
                .@"--chamber" => {
                    const chamber = it.next() orelse {
                        print("--chamber provided with no argument\n", .{});
                        help(process_name);
                    };
                    try chambers.append(chamber);
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

        if (chambers.items.len == 0) {
            print("--chamber not provied\n", .{});
            help(process_name);
        }

        if (chambers.items.len > 1 and history_file != null) {
            print("--load can only be used with a single chamber", .{});
            help(process_name);
        }

        return .{
            .alloc = alloc,
            .chambers = try chambers.toOwnedSlice(),
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
        self.alloc.free(self.chambers);
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
                    print("Which chamber to run, can be provided multiple times for multiple chambers", .{});
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

    var wasm_loader = try wasm_chamber.WasmLoader.init();
    defer wasm_loader.deinit();
    var chamber_mods = std.ArrayList(wasm_chamber.WasmChamber).init(alloc);
    defer {
        for (chamber_mods.items) |*chamber_mod| {
            chamber_mod.deinit();
        }
        chamber_mods.deinit();
    }

    for (args.chambers) |chamber_path| {
        const chamber_f = try std.fs.cwd().openFile(chamber_path, .{});
        defer chamber_f.close();
        const chamber_content = try chamber_f.readToEndAlloc(alloc, 1_000_000);
        defer alloc.free(chamber_content);

        var chamber = try wasm_loader.load(alloc, chamber_content);
        errdefer chamber.deinit();

        try chamber_mods.append(chamber);
    }

    var simulations = std.ArrayList(Simulation).init(alloc);
    defer {
        for (simulations.items) |*sim| {
            sim.deinit();
        }
        simulations.deinit();
    }

    for (chamber_mods.items) |chamber_mod| {
        if (args.history_file) |history_file_path| {
            std.debug.assert(chamber_mods.items.len == 1);
            var simulation_ctx = try Simulation.initFromHistory(alloc, chamber_mod, history_file_path, args.history_start_idx);
            errdefer simulation_ctx.deinit();

            try simulations.append(simulation_ctx);
        } else {
            var seed: usize = undefined;
            try std.posix.getrandom(std.mem.asBytes(&seed));

            var simulation_ctx = try Simulation.init(alloc, seed, chamber_mod);
            errdefer simulation_ctx.deinit();

            try simulations.append(simulation_ctx);
        }
    }

    var shutdown = std.atomic.Value(bool).init(false);
    const thread = try std.Thread.spawn(.{}, runSimulation, .{ simulations.items, &shutdown });
    defer thread.join();
    defer shutdown.store(true, .unordered);

    while (true) {
        var fds: [1]std.posix.pollfd = .{.{ .fd = tcp_server.stream.handle, .events = std.posix.POLL.IN, .revents = 0 }};
        _ = try std.posix.ppoll(&fds, null, null);
        const connection = try tcp_server.accept();
        defer connection.stream.close();

        handleConnection(alloc, args.www_root, args.chambers, connection, simulations.items) catch |e| {
            std.log.err("Failed to handle connection: {any}", .{e});
        };
    }
}
