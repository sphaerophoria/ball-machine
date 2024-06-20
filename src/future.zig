const std = @import("std");
const Atomic = std.atomic.Value;
const Allocator = std.mem.Allocator;

pub fn Promise(comptime T: type) type {
    return struct {
        const Self = @This();
        alloc: Allocator,
        val: T,
        ref_count: Atomic(u8),
        event: Event,

        pub fn init(alloc: Allocator) !*Self {
            const ret = try alloc.create(Self);
            errdefer alloc.destroy(ret);

            const event = try Event.init();
            ret.* = .{
                .alloc = alloc,
                .val = undefined,
                .ref_count = Atomic(u8).init(1),
                .event = event,
            };
            return ret;
        }

        pub fn unref(self: *Self) void {
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

            self.event.deinit();
            self.alloc.destroy(self);
        }

        pub fn set(self: *Self, val: T) void {
            self.val = val;
            self.event.notify() catch {};
        }

        pub fn future(self: *Self) Future(T) {
            self.ref();
            return .{
                .promise = self,
            };
        }

        fn ref(self: *Self) void {
            _ = self.ref_count.fetchAdd(1, .monotonic);
        }
    };
}

pub fn Future(comptime T: type) type {
    return struct {
        const Self = @This();
        promise: *Promise(T),

        pub fn deinit(self: *Self) void {
            self.promise.unref();
        }

        pub fn fd(self: *const Self) i32 {
            return self.promise.event.fd;
        }

        pub fn poll(self: *Self) !?T {
            if (try self.promise.event.poll()) {
                return self.promise.val;
            }

            return null;
        }
    };
}

const Event = struct {
    fd: i32,

    pub fn init() !Event {
        const fd = try std.posix.eventfd(0, std.os.linux.EFD.NONBLOCK);
        errdefer std.posix.close(fd);

        return .{
            .fd = fd,
        };
    }

    pub fn deinit(self: *Event) void {
        std.posix.close(self.fd);
    }

    pub fn notify(self: *Event) !void {
        const val: u64 = 1;
        _ = try std.posix.write(self.fd, std.mem.asBytes(&val));
    }

    pub fn poll(self: *Event) !bool {
        var val: u64 = undefined;
        _ = std.posix.read(self.fd, std.mem.asBytes(&val)) catch |e| {
            if (e == error.WouldBlock) {
                return false;
            }
            return e;
        };

        return true;
    }
};
