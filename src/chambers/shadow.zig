const std = @import("std");
const physics = @import("physics");
const graphics = @import("graphics.zig");
const Ball = physics.Ball;
const Surface = physics.Surface;
const Allocator = std.mem.Allocator;

const chamber_height = 0.7;
const State = struct {
    x_history: [25]u5 = undefined,
    y_history: [25]u5 = undefined,
    idx: u8 = 0,
    elapsed_time: f32 = 0,

    fn pushPosition(self: *State, pos: physics.Pos2) void {
        const len = self.x_history.len;
        self.x_history[self.idx % len] = @intFromFloat(std.math.clamp(pos.x, 0.0, 1.0) * std.math.maxInt(@TypeOf(self.x_history[0])));
        self.y_history[self.idx % len] = @intFromFloat(std.math.clamp(pos.y, 0.0, 1.0) / chamber_height * std.math.maxInt(@TypeOf(self.y_history[0])));
        self.idx = (self.idx + 1);
        if (self.idx > len * 2) {
            self.idx -= @intCast(len);
        }
    }
};

const platform = Surface{
    .a = .{ .x = 0.1, .y = 0.15 },
    .b = .{ .x = 0.9, .y = 0.15 },
};

var balls: []Ball = undefined;
var chamber_pixels: []u32 = undefined;
var state = State{};
var save_data: [saveSize()]u8 = undefined;

pub export fn init(max_balls: usize, max_chamber_pixels: usize) void {
    physics.assertBallLayout();
    balls = std.heap.wasm_allocator.alloc(Ball, max_balls) catch {
        return;
    };

    chamber_pixels = std.heap.wasm_allocator.alloc(u32, max_chamber_pixels) catch {
        return;
    };
}

pub export fn saveMemory() [*]u8 {
    return &save_data;
}

pub export fn ballsMemory() [*]Ball {
    return balls.ptr;
}

pub export fn canvasMemory() [*]u32 {
    return chamber_pixels.ptr;
}

pub export fn saveSize() usize {
    var len: usize = getRequiredBytesPacked(@TypeOf(state.x_history));
    len += getRequiredBytesPacked(@TypeOf(state.y_history));
    len += @sizeOf(@TypeOf(state.idx));
    len += @sizeOf(@TypeOf(state.elapsed_time));
    return len;
}

fn getRequiredBytesPacked(comptime T: type) usize {
    const info = @typeInfo(T);
    const DataPacked = std.PackedIntSlice(info.Array.child);
    return DataPacked.bytesRequired(info.Array.len);
}

fn savePacked(start_idx: usize, data: anytype) usize {
    const DataPacked = std.PackedIntSlice(@TypeOf(data[0]));
    const len = DataPacked.bytesRequired(data.len);
    var data_packed = DataPacked.init(save_data[start_idx .. start_idx + len], data.len);
    for (0..data.len) |i| {
        data_packed.set(i, data[i]);
    }
    return start_idx + len;
}

fn loadPacked(start_idx: usize, data: anytype) usize {
    const DataPacked = std.PackedIntSlice(@TypeOf(data[0]));
    const len = DataPacked.bytesRequired(data.len);
    var data_packed = DataPacked.init(save_data[start_idx .. start_idx + len], data.len);
    for (0..data.len) |i| {
        data[i] = data_packed.get(i);
    }
    return start_idx + len;
}

pub export fn save() void {
    var idx: usize = 0;

    idx = savePacked(idx, state.x_history);
    idx = savePacked(idx, state.y_history);

    const idx_out = std.mem.asBytes(&state.idx);
    @memcpy(save_data[idx .. idx + idx_out.len], idx_out);
    idx += idx_out.len;

    const elapsed_time_out = std.mem.asBytes(&state.elapsed_time);
    @memcpy(save_data[idx .. idx + elapsed_time_out.len], elapsed_time_out);
    idx += elapsed_time_out.len;
}

pub export fn load() void {
    var idx: usize = 0;

    idx = loadPacked(idx, &state.x_history);
    idx = loadPacked(idx, &state.y_history);

    const idx_out = std.mem.asBytes(&state.idx);
    @memcpy(idx_out, save_data[idx .. idx + idx_out.len]);
    idx += idx_out.len;

    const elapsed_time_out = std.mem.asBytes(&state.elapsed_time);
    @memcpy(elapsed_time_out, save_data[idx .. idx + elapsed_time_out.len]);
    idx += elapsed_time_out.len;
}

pub export fn step(num_balls: usize, delta: f32) void {
    state.elapsed_time += delta;
    const log_positions = state.elapsed_time > 0.08;
    if (log_positions) {
        state.elapsed_time = 0.0;
    }

    for (0..num_balls) |i| {
        const ball = &balls[i];
        physics.applyGravity(ball, delta);
        if (log_positions) {
            state.pushPosition(ball.pos);
        }

        const obj_normal = platform.normal();
        const ball_collision_point_offs = obj_normal.mul(-ball.r);
        const ball_collision_point = ball.pos.add(ball_collision_point_offs);

        const resolution = platform.collisionResolution(ball_collision_point, ball.velocity.mul(delta));
        if (resolution) |r| {
            physics.applyCollision(ball, r, obj_normal, physics.Vec2.zero, delta, 0.9);
        }
    }
}

const HistoryIt = struct {
    idx: usize,
    end: usize,

    fn init() HistoryIt {
        const len = state.x_history.len;
        if (state.idx < len) {
            return .{
                .idx = 0,
                .end = state.idx,
            };
        } else {
            return .{
                .idx = state.idx,
                .end = state.idx + len,
            };
        }
    }

    fn numItems(self: *const HistoryIt) usize {
        if (self.end > state.x_history.len) {
            return state.x_history.len;
        } else {
            return self.end;
        }
    }

    fn next(self: *HistoryIt) ?physics.Pos2 {
        if (self.idx == self.end) {
            return null;
        }
        defer self.idx += 1;

        const len = state.x_history.len;
        const x: f32 = @floatFromInt(state.x_history[self.idx % len]);
        const y: f32 = @floatFromInt(state.y_history[self.idx % len]);
        return .{
            .x = x / std.math.maxInt(@TypeOf(state.x_history[0])),
            .y = y * chamber_height / std.math.maxInt(@TypeOf(state.y_history[0])),
        };
    }
};

pub export fn render(canvas_width: usize, canvas_height: usize) void {
    const this_chamber_pixels = chamber_pixels[0 .. canvas_width * canvas_height];
    @memset(this_chamber_pixels, 0xffffffff);

    const graphics_canvas = graphics.Canvas{
        .data = this_chamber_pixels,
        .width = canvas_width,
    };

    var it = HistoryIt.init();
    const len = it.numItems();
    var i: usize = 0;
    while (it.next()) |pos| {
        const lum: u32 = @min(255, (len - i) * 3 + 100);
        const color = 0xff000000 | lum << 16 | lum << 8 | lum;
        graphics.renderCircle(pos, 0.025, &graphics_canvas, color);
        i += 1;
    }

    graphics.renderLine(platform.a, platform.b, &graphics_canvas, graphics.colorTexturer(0xff000000));
}
