const std = @import("std");

const TimerEvent = @This();

fd: std.posix.fd_t,

pub fn init() !TimerEvent {
    const fd = try std.posix.timerfd_create(std.posix.CLOCK.MONOTONIC, std.os.linux.TFD{
        .NONBLOCK = true,
    });

    return .{
        .fd = fd,
    };
}

pub fn deinit(self: *TimerEvent) void {
    std.posix.close(self.fd);
}

pub fn setInterval(self: *TimerEvent, interval_ns: u64) !void {
    const val = std.os.linux.itimerspec{ .it_value = .{
        .tv_sec = @intCast(interval_ns / std.time.ns_per_s),
        .tv_nsec = @intCast(interval_ns % std.time.ns_per_s),
    }, .it_interval = .{
        .tv_sec = @intCast(interval_ns / std.time.ns_per_s),
        .tv_nsec = @intCast(interval_ns % std.time.ns_per_s),
    } };
    try std.posix.timerfd_settime(self.fd, std.os.linux.TFD.TIMER{}, &val, null);
}

pub fn poll(self: *TimerEvent) !usize {
    var ret: u64 = 0;
    _ = std.posix.read(self.fd, std.mem.asBytes(&ret)) catch |e| {
        if (e == error.WouldBlock) {
            return 0;
        }

        return e;
    };

    return ret;
}
