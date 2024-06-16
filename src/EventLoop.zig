const builtin = @import("builtin");
const std = @import("std");
const Allocator = std.mem.Allocator;

const EventLoop = @This();

alloc: Allocator,
epollfd: i32,
handlers: ItemPool(EventHandlerPriv) = .{},
shutdown: bool = false,

pub fn init(alloc: Allocator) !EventLoop {
    const epollfd = try std.posix.epoll_create1(0);

    return .{
        .alloc = alloc,
        .epollfd = epollfd,
    };
}

pub fn deinit(self: *EventLoop) void {
    for (0..self.handlers.elems.items.len) |idx| {
        if (std.mem.indexOfScalar(usize, self.handlers.available.items, idx) == null) {
            const handler = self.handlers.get(idx);
            if (handler.handler.deinit) |f| {
                f(handler.handler.data);
            }
        }
    }
    self.handlers.deinit(self.alloc);
    std.posix.close(self.epollfd);
}

pub fn register(self: *EventLoop, fd: i32, handler: EventHandler) !void {
    const handler_id = try self.handlers.create(self.alloc);
    errdefer self.handlers.release(self.alloc, handler_id);

    self.handlers.get(handler_id).* = .{ .fd = fd, .handler = handler };

    var event = std.os.linux.epoll_event{
        .events = std.os.linux.EPOLL.IN | std.os.linux.EPOLL.OUT | std.os.linux.EPOLL.ET,
        .data = .{ .ptr = handler_id },
    };

    try std.posix.epoll_ctl(self.epollfd, std.os.linux.EPOLL.CTL_ADD, fd, &event);
}

pub fn run(self: *EventLoop) !void {
    while (!self.shutdown) {
        const num_events = 100;
        var events: [num_events]std.os.linux.epoll_event = undefined;
        const num_fds = std.posix.epoll_wait(self.epollfd, &events, -1);

        var to_remove: [num_events]usize = undefined;
        var num_to_remove: usize = 0;

        for (events[0..num_fds]) |event| {
            const handler_id = event.data.ptr;
            const handler = self.handlers.get(handler_id);

            const ret = handler.handler.callback(handler.handler.data);

            if (ret == .deinit) {
                to_remove[num_to_remove] = handler_id;
                num_to_remove += 1;
            }

            if (ret == .server_shutdown) {
                self.shutdown = true;
            }
        }

        var i = num_to_remove;
        while (i > 0) {
            i -= 1;
            const id = to_remove[i];
            const handler = self.handlers.get(id);

            try std.posix.epoll_ctl(self.epollfd, std.os.linux.EPOLL.CTL_DEL, handler.fd, null);

            if (handler.handler.deinit) |f| {
                f(handler.handler.data);
            }
            self.handlers.release(self.alloc, id);
        }
    }
}

pub const HandlerAction = enum {
    none,
    deinit,
    server_shutdown,
};

pub const EventHandler = struct {
    const Callback = *const fn (?*anyopaque) HandlerAction;
    data: ?*anyopaque,
    callback: Callback,
    deinit: ?*const fn (?*anyopaque) void,
};

fn ItemPool(comptime T: type) type {
    return struct {
        elems: std.ArrayListUnmanaged(T) = .{},
        available: std.ArrayListUnmanaged(usize) = .{},

        const Self = @This();

        pub fn deinit(self: *Self, alloc: Allocator) void {
            self.elems.deinit(alloc);
            self.available.deinit(alloc);
        }

        pub fn create(self: *Self, alloc: Allocator) !usize {
            if (self.available.popOrNull()) |idx| {
                return idx;
            } else {
                _ = try self.elems.addOne(alloc);
                return self.elems.items.len - 1;
            }
        }

        pub fn get(self: *Self, id: usize) *T {
            return &self.elems.items[id];
        }

        pub fn release(self: *Self, alloc: Allocator, id: usize) void {
            self.available.append(alloc, id) catch {
                std.log.err("Failed to restore {d} to pool\n", .{id});
            };

            @memset(std.mem.asBytes(&self.elems.items[id]), undefined);
        }
    };
}

const EventHandlerPriv = struct {
    fd: i32,
    handler: EventHandler,
};
