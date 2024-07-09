const std = @import("std");
const Simulation = @import("Simulation.zig");
const SimulationScheduler = @import("SimulationScheduler.zig");
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
    extern fn initChamber(max_balls: usize, max_pixels: usize) bool;
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

fn initChamber(_: ?*anyopaque, max_balls: usize, max_pixels: usize) anyerror!void {
    if (c.initChamber(max_balls, max_pixels) == false) {
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
var scheduler: SimulationScheduler = .{};
var last_time: f32 = 0.0;

pub export fn init(seed: usize, canvas_max_pixels: usize) void {
    simulation = Simulation.init(std.heap.wasm_allocator, seed, canvas_max_pixels) catch {
        unreachable;
    };

    simulation.chambers_per_row = 1;

    simulation.addChamber(chamber) catch {
        unreachable;
    };
}

pub export fn stepUntil(time_s: f32) void {
    last_time = time_s;
    while (scheduler.shouldStep(time_s, simulation.num_steps_taken)) {
        simulation.step() catch {
            unreachable;
        };
    }
}

var state_buf: [16384]u8 = undefined;

pub export fn state() [*]u8 {
    @memset(&state_buf, 0);
    var io_writer = std.io.fixedBufferStream(&state_buf);

    var json_writer = std.json.writeStream(io_writer.writer(), .{});
    json_writer.write(simulation.balls.items) catch {};

    return &state_buf;
}

pub export fn reset() void {
    simulation.reset();
}

pub export fn chamberHeight() f32 {
    return Simulation.chamber_height;
}

pub export fn setNumBalls(num_balls: usize) void {
    simulation.setNumBalls(num_balls) catch unreachable;
}

pub export fn numBalls() usize {
    return simulation.balls.items.len;
}

pub export fn setSpeed(ratio: f32) void {
    scheduler.setSpeed(last_time, ratio, simulation.num_steps_taken);
}
