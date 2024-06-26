const std = @import("std");
const builtin = @import("builtin");
const resources = @import("resources");
const userinfo = @import("userinfo.zig");
const Allocator = std.mem.Allocator;
const wasm_chamber = @import("wasm_chamber.zig");
const physics = @import("physics.zig");
const Simulation = @import("Simulation.zig");
const TcpServer = @import("TcpServer.zig");
const Server = @import("Server.zig");
const EventLoop = @import("EventLoop.zig");

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

const Args = struct {
    alloc: Allocator,
    chambers: []const []const u8,
    www_root: ?[]const u8,
    port: u16,
    history_file: ?[]const u8,
    history_start_idx: usize,
    client_id: []const u8,
    client_secret: []const u8,
    it: std.process.ArgIterator,

    const Option = enum {
        @"--chamber",
        @"--www-root",
        @"--port",
        @"--load",
        @"--client-id",
        @"--client-secret",
        @"--help",
    };

    pub fn parse(alloc: Allocator) !Args {
        var it = try std.process.argsWithAllocator(alloc);
        const process_name = it.next() orelse "ball-machine";

        var www_root: ?[]const u8 = null;
        var port: ?u16 = null;
        var history_file: ?[]const u8 = null;
        var history_start_idx: usize = 0;
        var client_id: ?[]const u8 = null;
        var client_secret: ?[]const u8 = null;
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
                .@"--client-id" => {
                    client_id = it.next() orelse {
                        print("--client-id provided with no argument\n", .{});
                        help(process_name);
                    };
                },
                .@"--client-secret" => {
                    client_secret = it.next() orelse {
                        print("--client-secret provided with no argument\n", .{});
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
            .client_id = client_id orelse {
                print("--client-id not provided\n", .{});
                help(process_name);
            },
            .client_secret = client_secret orelse {
                print("--client-id not provided\n", .{});
                help(process_name);
            },
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
                .@"--client-id" => {
                    print("client id of twitch application", .{});
                },
                .@"--client-secret" => {
                    print("client secret of twitch application", .{});
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

const SignalHandler = struct {
    fd: i32,

    fn init() !SignalHandler {
        var sig_mask = std.posix.empty_sigset;
        std.os.linux.sigaddset(&sig_mask, std.posix.SIG.INT);
        std.posix.sigprocmask(std.posix.SIG.BLOCK, &sig_mask, null);
        const fd = try std.posix.signalfd(-1, &sig_mask, 0);

        return .{
            .fd = fd,
        };
    }

    fn deinit(self: *SignalHandler) void {
        std.posix.close(self.fd);
    }

    fn handler(_: *SignalHandler) EventLoop.EventHandler {
        return EventLoop.EventHandler{
            .data = null,
            .callback = struct {
                fn f(_: ?*anyopaque) EventLoop.HandlerAction {
                    return .server_shutdown;
                }
            }.f,
            .deinit = null,
        };
    }
};

pub fn main() !void {
    var signal_handler = try SignalHandler.init();
    defer signal_handler.deinit();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const alloc = gpa.allocator();

    var args = try Args.parse(alloc);
    defer args.deinit();

    const addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, args.port);

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

    var event_loop = try EventLoop.init(alloc);
    defer event_loop.deinit();

    try event_loop.register(signal_handler.fd, signal_handler.handler());

    const twitch_jwk =
        \\{"keys":[{"alg":"RS256","e":"AQAB","kid":"1","kty":"RSA","n":"6lq9MQ-q6hcxr7kOUp-tHlHtdcDsVLwVIw13iXUCvuDOeCi0VSuxCCUY6UmMjy53dX00ih2E4Y4UvlrmmurK0eG26b-HMNNAvCGsVXHU3RcRhVoHDaOwHwU72j7bpHn9XbP3Q3jebX6KIfNbei2MiR0Wyb8RZHE-aZhRYO8_-k9G2GycTpvc-2GBsP8VHLUKKfAs2B6sW3q3ymU6M0L-cFXkZ9fHkn9ejs-sqZPhMJxtBPBxoUIUQFTgv4VXTSv914f_YkNw-EjuwbgwXMvpyr06EyfImxHoxsZkFYB-qBYHtaMxTnFsZBr6fn8Ha2JqT1hoP7Z5r5wxDu3GQhKkHw","use":"sig"}]}
    ;

    const jwt_keys = try userinfo.JsonWebKeys.parse(alloc, twitch_jwk);
    defer jwt_keys.deinit(alloc);

    var sim_server = try Server.init(
        alloc,
        args.www_root,
        args.chambers,
        simulations.items,
        std.mem.trim(u8, args.client_id, &std.ascii.whitespace),
        std.mem.trim(u8, args.client_secret, &std.ascii.whitespace),
        jwt_keys.items,
        &event_loop,
    );
    defer sim_server.deinit();

    var tcp_server = try TcpServer.init(addr, sim_server.spawner(), &event_loop);
    defer tcp_server.deinit();
    try event_loop.register(tcp_server.server.stream.handle, tcp_server.handler());

    try event_loop.run();
}
