const std = @import("std");
const Simulation = @import("Simulation.zig");
const Allocator = std.mem.Allocator;
const Chamber = @import("Chamber.zig");
const physics = @import("physics.zig");
const Ball = physics.Ball;

pub const std_options: std.Options = .{
    .logFn = myLog,
};

fn myLog(
    comptime message_level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    _ = scope;
    _ = message_level;
    print(format, args);
}

const c = struct {
    extern fn initChamber(max_balls: usize) bool;
    extern fn stepChamber(balls_ptr: ?*anyopaque, byte_len: usize, num_balls: usize, delta: f32) void;
    extern fn logWasm(s: [*]u8, len: usize) void;
};

fn print(comptime fmt: []const u8, args: anytype) void {
    const to_print = std.fmt.allocPrint(std.heap.wasm_allocator, fmt, args) catch {
        @panic("");
    };
    defer std.heap.wasm_allocator.free(to_print);

    c.logWasm(to_print.ptr, to_print.len);
}

fn initChamber(_: ?*anyopaque, max_balls: usize) anyerror!void {
    if (c.initChamber(max_balls) == false) {
        return error.InitFailed;
    }
}

fn stepChamber(_: ?*anyopaque, balls: []Ball, delta: f32) anyerror!void {
    c.stepChamber(balls.ptr, balls.len * @sizeOf(Ball), balls.len, delta);
}

fn loadChamber(_: ?*anyopaque, _: []const u8) anyerror!void {}
fn saveChamber(_: ?*anyopaque, _: Allocator) anyerror![]const u8 {
    return &.{};
}

const vtable: Chamber.Vtable = .{
    .initChamber = initChamber,
    .load = loadChamber,
    .save = saveChamber,
    .step = stepChamber,
};

const chamber = Chamber{
    .data = null,
    .vtable = &vtable,
};

var simulation: Simulation = undefined;

pub export fn init(seed: usize) void {
    simulation = Simulation.init(seed, chamber) catch {
        unreachable;
    };
}

pub export fn step_until(time_s: f32) void {
    const desired_num_steps_taken: u64 = @intFromFloat(time_s / Simulation.step_len_s);
    while (simulation.num_steps_taken < desired_num_steps_taken) {
        simulation.step();
    }
}

var state_buf: [4096]u8 = undefined;

pub export fn state() [*]u8 {
    @memset(&state_buf, 0);
    var io_writer = std.io.fixedBufferStream(&state_buf);

    var json_writer = std.json.writeStream(io_writer.writer(), .{});
    json_writer.write(simulation.balls) catch {};

    return &state_buf;
}

pub export fn reset() void {
    simulation.reset();
}
