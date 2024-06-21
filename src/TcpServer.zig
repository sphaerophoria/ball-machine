const std = @import("std");
const Allocator = std.mem.Allocator;
const EventLoop = @import("EventLoop.zig");

const TcpServer = @This();

pub const ConnectionSpawner = struct {
    const SpawnFn = fn (?*anyopaque, std.net.Stream) anyerror!EventLoop.EventHandler;

    data: ?*anyopaque,
    spawn_fn: *const SpawnFn,

    pub fn spawn(self: *const ConnectionSpawner, stream: std.net.Stream) !EventLoop.EventHandler {
        return self.spawn_fn(self.data, stream);
    }
};

event_loop: *EventLoop,
server: std.net.Server,
spawner: ConnectionSpawner,

pub fn init(
    address: std.net.Address,
    spawner: ConnectionSpawner,
    event_loop: *EventLoop,
) !TcpServer {
    var tcp_server = try address.listen(.{
        .reuse_port = true,
        .reuse_address = true,
    });
    errdefer tcp_server.deinit();

    try setNonblock(tcp_server.stream);

    return .{
        .spawner = spawner,
        .server = tcp_server,
        .event_loop = event_loop,
    };
}

pub fn deinit(self: *TcpServer) void {
    self.server.deinit();
}

pub fn handler(self: *TcpServer) EventLoop.EventHandler {
    const callback = struct {
        fn f(data: ?*anyopaque) EventLoop.HandlerAction {
            return TcpServer.acceptTcpConnection(@ptrCast(@alignCast(data))) catch |e| {
                std.log.err("Failed to create http connection: {any}", .{e});
                return .none;
            };
        }
    }.f;

    return .{
        .data = self,
        .callback = callback,
        .deinit = null,
    };
}

fn acceptTcpConnection(self: *TcpServer) anyerror!EventLoop.HandlerAction {
    var connection = self.server.accept() catch {
        return .deinit;
    };

    try setNonblock(connection.stream);

    const conn_handler = self.spawner.spawn(connection.stream) catch |e| {
        connection.stream.close();
        return e;
    };

    errdefer {
        if (conn_handler.deinit) |f| {
            f(conn_handler.data);
        }
    }

    try self.event_loop.register(connection.stream.handle, conn_handler);
    return .none;
}

fn setNonblock(conn: std.net.Stream) !void {
    var flags = try std.posix.fcntl(conn.handle, std.posix.F.GETFL, 0);
    var flags_s: *std.posix.O = @ptrCast(&flags);
    flags_s.NONBLOCK = true;
    _ = try std.posix.fcntl(conn.handle, std.posix.F.SETFL, flags);
}
