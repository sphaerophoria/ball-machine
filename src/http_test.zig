const std = @import("std");
const http = @import("http.zig");
const Atomic = std.atomic.Value;
const Allocator = std.mem.Allocator;
const TcpServer = @import("TcpServer.zig");
const EventLoop = @import("EventLoop.zig");

const Connection = struct {
    const RefCount = Atomic(u8);

    server: *Server,
    event_fd: ?i32,
    inner: http.HttpConnection,
    ref_count: RefCount,

    fn init(server: *Server, stream: std.net.Stream) !*Connection {
        var inner = try http.HttpConnection.init(server.alloc, stream);
        errdefer inner.deinit();
        const ret = try server.alloc.create(Connection);
        ret.* = .{
            .inner = inner,
            .event_fd = null,
            .server = server,
            .ref_count = RefCount.init(1),
        };
        return ret;
    }

    fn deinit(self: *Connection) void {
        var val = self.ref_count.load(.monotonic);
        while (true) {
            const new_val = val - 1;
            const ret = self.ref_count.cmpxchgWeak(val, new_val, .monotonic, .monotonic);
            if (ret != null) {
                val = ret.?;
            } else {
                val = new_val;
                break;
            }
        }

        if (val != 0) {
            return;
        }

        // FIXME: Close fd and remove from list
        if (self.event_fd) |fd| {
            std.posix.close(fd);
        }
        self.inner.deinit();
        self.server.alloc.destroy(self);
    }

    fn poll(self: *Connection) EventLoop.HandlerAction {
        std.debug.print("poll\n", .{});
        defer std.debug.print("exit\n", .{});
        var do_deinit = false;
        while (true) {
            const action = self.inner.poll();
            switch (action) {
                .none => {
                    if (do_deinit) {
                        return .deinit;
                    }
                    return .none;
                },
                .feed => {
                    const response = self.generateResponse() catch |e| {
                        std.log.err("Failed to generate response: {any}", .{e});
                        return .deinit;
                    } orelse {
                        return .none;
                    };

                    std.debug.print("Response set\n", .{});
                    self.inner.setResponse(response);
                    if (self.event_fd != null) {
                        do_deinit = true;
                    }
                },
                .deinit => return .deinit,
            }
        }
    }

    fn handler(self: *Connection) EventLoop.EventHandler {
        const callback_fn = struct {
            fn f(data: ?*anyopaque) EventLoop.HandlerAction {
                const conn: *Connection = @ptrCast(@alignCast(data));
                return conn.poll();
            }
        }.f;

        const deinit_fn = struct {
            fn f(data: ?*anyopaque) void {
                const conn: *Connection = @ptrCast(@alignCast(data));
                conn.deinit();
            }
        }.f;

        return .{
            .data = self,
            .callback = callback_fn,
            .deinit = deinit_fn,
        };
    }

    fn generateResponse(self: *Connection) !?http.Writer {
        if (self.server.enter_pressed.load(.monotonic)) {
            std.debug.print("Enter was pressed\n", .{});

            const header = http.Header{
                .status = std.http.Status.ok,
                .content_type = .@"text/html",
                .content_length = Server.index_html.len,
            };

            return try http.Writer.init(self.server.alloc, header, Server.index_html, false);
        }

        if (self.event_fd == null) {
            std.debug.print("Registering eventfd\n", .{});
            // Register with event loop
            self.event_fd = try std.posix.eventfd(0, 0);
            errdefer {
                std.posix.close(self.event_fd.?);
                self.event_fd = null;
            }

            self.ref();
            errdefer self.deinit();

            // FIXME: remove  from list on failure
            try self.server.event_fd_list.addFd(self.event_fd.?);
            try self.server.event_loop.register(self.event_fd.?, self.handler());
        }

        std.debug.print("Deferrring\n", .{});
        return null;
    }

    pub fn ref(self: *Connection) void {
        _ = self.ref_count.fetchAdd(1, .monotonic);
    }
};

const Server = struct {
    alloc: Allocator,
    event_fd_list: *EventFdList,
    event_loop: *EventLoop,
    enter_pressed: *std.atomic.Value(bool),

    const index_html =
        \\<!doctype html>
        \\<head>
        \\</head>
        \\<body>
        \\  Hello world
        \\</body>
    ;

    pub fn spawner(self: *Server) TcpServer.ConnectionSpawner {
        const spawn_fn = struct {
            fn f(data: ?*anyopaque, stream: std.net.Stream) anyerror!EventLoop.EventHandler {
                const self_: *Server = @ptrCast(@alignCast(data));
                return self_.spawn(stream);
            }
        }.f;

        return .{
            .data = self,
            .spawn_fn = spawn_fn,
        };
    }

    fn spawn(self: *Server, stream: std.net.Stream) !EventLoop.EventHandler {
        const connection = try Connection.init(self, stream);
        return connection.handler();
    }
};

const EventFdList = struct {
    mutex: std.Thread.Mutex = .{},
    fds: std.ArrayList(i32),

    fn init(alloc: Allocator) EventFdList {
        return .{
            .fds = std.ArrayList(i32).init(alloc),
        };
    }

    fn deinit(self: *EventFdList) void {
        self.fds.deinit();
    }

    fn addFd(self: *EventFdList, fd: i32) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.fds.append(fd);
    }

    fn signal(self: *EventFdList) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.fds.items) |fd| {
            _ = try std.posix.write(fd, &[8]u8{ 1, 0, 0, 0, 0, 0, 0, 0 });
        }
    }
};

fn waitForEnter(pressed: *std.atomic.Value(bool), eventfds: *EventFdList) !void {
    var buf: [1]u8 = undefined;
    _ = try std.io.getStdIn().read(&buf);
    pressed.store(true, .monotonic);
    try eventfds.signal();
}

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

    var event_fd_list = EventFdList.init(alloc);
    defer event_fd_list.deinit();

    var enter_pressed = std.atomic.Value(bool).init(false);
    (try std.Thread.spawn(.{}, waitForEnter, .{ &enter_pressed, &event_fd_list })).detach();

    var event_loop = try EventLoop.init(alloc);
    defer event_loop.deinit();

    try event_loop.register(signal_handler.fd, signal_handler.handler());

    var response_server = Server{
        .alloc = alloc,
        .event_fd_list = &event_fd_list,
        .event_loop = &event_loop,
        .enter_pressed = &enter_pressed,
    };
    const addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 8000);
    var tcp_server = try TcpServer.init(addr, response_server.spawner(), &event_loop);
    defer tcp_server.deinit();
    try event_loop.register(tcp_server.server.stream.handle, tcp_server.handler());
    std.debug.print("running event loop\n", .{});
    try event_loop.run();

    std.debug.print("bye bye\n", .{});
}
