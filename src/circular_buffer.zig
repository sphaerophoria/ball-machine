const std = @import("std");
const Allocator = std.mem.Allocator;

pub fn Deinit(comptime Context: type, comptime T: type) type {
    return struct {
        context: Context,
        deinit_fn: fn (Context, T) void,

        fn deinit(self: Context, item: T) void {
            self.deinit_fn(self.context, item);
        }
    };
}

pub fn CircularBuffer(comptime T: type, comptime DeinitContext: type, comptime deinitItem: fn (DeinitContext, T) void) type {
    return struct {
        deinit_context: DeinitContext,
        history: []T,
        head: usize = 0,
        tail: usize = 0,

        const Self = @This();

        pub const Iter = struct {
            history: *Self,
            pos: usize,

            pub fn next(self: *@This()) ?T {
                if (self.pos == self.history.history.len) {
                    self.pos = 0;
                }

                if (self.pos == self.history.tail) {
                    return null;
                }

                defer self.pos += 1;
                return self.history.history[self.pos];
            }
        };

        pub fn init(alloc: Allocator, size: usize, deinit_context: DeinitContext) !Self {
            const history = try alloc.alloc(T, size + 1);
            return .{
                .deinit_context = deinit_context,
                .history = history,
            };
        }

        pub fn deinit(self: *Self, alloc: Allocator) void {
            var it = self.iter();
            while (it.next()) |val| {
                deinitItem(self.deinit_context, val);
            }
            alloc.free(self.history);
        }

        pub fn push(self: *Self, item: T) !void {
            self.history[self.tail] = item;
            self.tail += 1;
            self.tail %= self.history.len;
            if (self.tail == self.head) {
                deinitItem(self.deinit_context, self.history[self.head]);
                self.head += 1;
                self.head %= self.history.len;
            }
        }

        pub fn iter(self: *Self) Iter {
            return .{
                .history = self,
                .pos = self.head,
            };
        }
    };
}

fn testExpectedItems(expected: []const *i32, buf: anytype) !void {
    var it = buf.iter();
    for (expected) |val| {
        const next = it.next();
        try std.testing.expectEqual(next, val);
    }

    try std.testing.expectEqual(null, it.next());
}

test "sanity" {
    const alloc = std.testing.allocator;

    const deinit_fn = struct {
        fn f(inner_alloc: Allocator, item: *i32) void {
            inner_alloc.destroy(item);
        }
    }.f;

    const Buf = CircularBuffer(*i32, Allocator, deinit_fn);
    var buf = try Buf.init(alloc, 3, alloc);
    defer buf.deinit(alloc);

    const x = try alloc.create(i32);
    x.* = 1;
    try buf.push(x);

    try testExpectedItems(&.{x}, &buf);

    const y = try alloc.create(i32);
    y.* = 2;
    try buf.push(y);

    try testExpectedItems(&.{ x, y }, &buf);

    const z = try alloc.create(i32);
    z.* = 3;
    try buf.push(z);

    try testExpectedItems(&.{ x, y, z }, &buf);

    const w = try alloc.create(i32);
    w.* = 4;
    try buf.push(w);

    try testExpectedItems(&.{ y, z, w }, &buf);
}
