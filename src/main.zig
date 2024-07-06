const std = @import("std");
const builtin = @import("builtin");
const userinfo = @import("userinfo.zig");
const Allocator = std.mem.Allocator;
const TcpServer = @import("TcpServer.zig");
const Server = @import("Server.zig");
const EventLoop = @import("EventLoop.zig");
const App = @import("App.zig");
const Db = @import("Db.zig");
const TimerEvent = @import("TimerEvent.zig");

const Args = struct {
    alloc: Allocator,
    www_root: ?[]const u8,
    port: u16,
    client_id: []const u8,
    client_secret: []const u8,
    server_url: []const u8,
    db: []const u8,
    it: std.process.ArgIterator,

    const Option = enum {
        @"--www-root",
        @"--port",
        @"--client-id",
        @"--client-secret",
        @"--db",
        @"--server-url",
        @"--help",
    };

    pub fn parse(alloc: Allocator) !Args {
        var it = try std.process.argsWithAllocator(alloc);
        const process_name = it.next() orelse "ball-machine";

        var www_root: ?[]const u8 = null;
        var port: ?u16 = null;
        var client_id: ?[]const u8 = null;
        var client_secret: ?[]const u8 = null;
        var server_url: ?[]const u8 = null;
        var db: ?[]const u8 = null;

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
                .@"--db" => {
                    db = it.next() orelse {
                        print("--db provided with no argument\n", .{});
                        help(process_name);
                    };
                },
                .@"--server-url" => {
                    server_url = it.next() orelse {
                        print("--server-url provided with no argument\n", .{});
                        help(process_name);
                    };
                },
                .@"--help" => {
                    help(process_name);
                },
            }
        }

        return .{
            .alloc = alloc,
            .www_root = www_root,
            .port = port orelse {
                print("--port not provied\n", .{});
                help(process_name);
            },
            .client_id = client_id orelse {
                print("--client-id not provided\n", .{});
                help(process_name);
            },
            .client_secret = client_secret orelse {
                print("--client-id not provided\n", .{});
                help(process_name);
            },
            .db = db orelse {
                print("--db not provided\n", .{});
                help(process_name);
            },
            .server_url = server_url orelse {
                print("--server-url not provided", .{});
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
                .@"--client-id" => {
                    print("client id of twitch application", .{});
                },
                .@"--client-secret" => {
                    print("client secret of twitch application", .{});
                },
                .@"--db" => {
                    print("folder where data goes", .{});
                },
                .@"--server-url" => {
                    print("Server url, must match twitch's registered URL, and be correct", .{});
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

const AppRunner = struct {
    inner: TimerEvent,
    app: *App,

    fn init(app: *App) !AppRunner {
        var inner = try TimerEvent.init();
        try inner.setInterval(1_666_666);
        return .{
            .inner = inner,
            .app = app,
        };
    }

    fn deinit(self: *AppRunner) void {
        self.inner.deinit();
    }

    fn handler(self: *AppRunner) EventLoop.EventHandler {
        _ = self.poll();
        return .{
            .data = self,
            .callback = EventLoop.EventHandler.makeCallback(AppRunner, poll),
            .deinit = null,
        };
    }

    fn poll(self: *AppRunner) EventLoop.HandlerAction {
        const num_triggers = self.inner.poll() catch {
            std.log.err("Timer failed", .{});
            return .server_shutdown;
        };

        if (num_triggers == 0) {
            return .none;
        }

        self.app.step() catch {
            std.log.err("App failed", .{});
            return .server_shutdown;
        };

        return .none;
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        if (gpa.deinit() != .ok) {
            std.process.exit(1);
        }
    }

    const alloc = gpa.allocator();

    var signal_handler = try SignalHandler.init();
    defer signal_handler.deinit();

    var args = try Args.parse(alloc);
    defer args.deinit();

    const addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, args.port);

    var db = try Db.init(args.db);
    defer db.deinit();

    var db_chambers = try db.getChambers(alloc);
    defer db_chambers.deinit(alloc);

    var app = try App.init(alloc, db_chambers.items);
    defer app.deinit();

    var event_loop = try EventLoop.init(alloc);
    defer event_loop.deinit();

    try event_loop.register(signal_handler.fd, signal_handler.handler());

    var app_runner = try AppRunner.init(&app);
    defer app_runner.deinit();

    try event_loop.register(app_runner.inner.fd, app_runner.handler());

    const twitch_jwk =
        \\{"keys":[{"alg":"RS256","e":"AQAB","kid":"1","kty":"RSA","n":"6lq9MQ-q6hcxr7kOUp-tHlHtdcDsVLwVIw13iXUCvuDOeCi0VSuxCCUY6UmMjy53dX00ih2E4Y4UvlrmmurK0eG26b-HMNNAvCGsVXHU3RcRhVoHDaOwHwU72j7bpHn9XbP3Q3jebX6KIfNbei2MiR0Wyb8RZHE-aZhRYO8_-k9G2GycTpvc-2GBsP8VHLUKKfAs2B6sW3q3ymU6M0L-cFXkZ9fHkn9ejs-sqZPhMJxtBPBxoUIUQFTgv4VXTSv914f_YkNw-EjuwbgwXMvpyr06EyfImxHoxsZkFYB-qBYHtaMxTnFsZBr6fn8Ha2JqT1hoP7Z5r5wxDu3GQhKkHw","use":"sig"}]}
    ;

    const jwt_keys = try userinfo.JsonWebKeys.parse(alloc, twitch_jwk);
    defer jwt_keys.deinit(alloc);

    var sim_server = try Server.init(
        alloc,
        args.www_root,
        &app,
        std.mem.trim(u8, args.client_id, &std.ascii.whitespace),
        std.mem.trim(u8, args.client_secret, &std.ascii.whitespace),
        jwt_keys.items,
        args.server_url,
        &event_loop,
        &db,
    );
    defer sim_server.deinit();

    var tcp_server = try TcpServer.init(addr, sim_server.spawner(), &event_loop);
    defer tcp_server.deinit();
    try event_loop.register(tcp_server.server.stream.handle, tcp_server.handler());

    try event_loop.run();
}

test {
    std.testing.refAllDeclsRecursive(@This());
}
