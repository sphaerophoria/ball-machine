const std = @import("std");
const builtin = @import("builtin");
const physics = @import("physics");
const Pos2 = physics.Pos2;
const Vec2 = physics.Vec2;

pub fn ColorTexturer(comptime color: u32) type {
    return struct {
        fn get(self: *const @This(), x: f32, y: f32, old_data: u32) u32 {
            _ = self;
            _ = x;
            _ = y;
            _ = old_data;
            return color;
        }
    };
}

pub fn colorTexturer(comptime color: u32) ColorTexturer(color) {
    return ColorTexturer(color){};
}

pub const Canvas = struct {
    width: usize,
    data: []u32,

    fn height(self: *const Canvas) usize {
        return self.data.len / self.width;
    }

    pub fn toYPx(self: *const Canvas, y_norm: f32) i64 {
        const chamber_width_f: f32 = @floatFromInt(self.width);
        const floor_offs_px: i64 = @intFromFloat(y_norm * chamber_width_f);
        return @as(i64, @intCast(self.height())) - floor_offs_px;
    }

    pub fn toXPx(self: *const Canvas, x_norm: f32) i64 {
        const chamber_width_f: f32 = @floatFromInt(self.width);
        return @intFromFloat(x_norm * chamber_width_f);
    }

    pub fn toPixelPos(self: *const Canvas, pos: Pos2) PixelPos {
        return .{
            .x = self.toXPx(pos.x),
            .y = self.toYPx(pos.y),
        };
    }
};

pub fn renderLine(start: Pos2, end: Pos2, canvas: *const Canvas, texturer: anytype) void {
    renderRotatedRect(lineToRect(start, end, 0.02), canvas, texturer);
}

extern fn logWasm(s: [*]u8, len: usize) void;
fn print(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch unreachable;
    logWasm(s.ptr, s.len);
}

pub fn renderCircle(pos: Pos2, radius: f32, canvas: *const Canvas, color: u32) void {
    const y_start_norm = pos.y - radius;
    const y_end_norm = pos.y + radius;

    // Normalized space is upside down
    const y_start_px = canvas.toYPx(y_end_norm);
    const y_end_px = canvas.toYPx(y_start_norm);
    const y_center_px = @divTrunc((y_end_px - y_start_px), 2) + y_start_px;

    const x_center_px = canvas.toXPx(pos.x);
    const r_px = canvas.toXPx(radius);
    const r_2_px = r_px * r_px;

    const chamber_height = canvas.height();

    var y = y_start_px;
    while (true) {
        defer y += 1;
        if (y >= y_end_px) {
            break;
        }

        if (y < 0 or y >= chamber_height) {
            continue;
        }
        const y_offs = y - y_center_px;
        const y_2_px = y_offs * y_offs;

        const x_2_px: u64 = @intCast(@abs(r_2_px - y_2_px));
        const x_offs_px: i64 = @intCast(std.math.sqrt(x_2_px));

        var x = x_center_px - x_offs_px;
        while (true) {
            if (x >= x_center_px + x_offs_px) {
                break;
            }
            defer x += 1;
            if (x < 0 or x >= canvas.width) {
                continue;
            }

            const y_u: usize = @intCast(y);
            const x_u: usize = @intCast(x);
            canvas.data[y_u * canvas.width + x_u] = color;
        }
    }
}

pub const Rect = struct {
    center: Pos2,
    width: f32,
    height: f32,
    rotation_rad: f32,
};

pub fn renderRotatedRect(rect: Rect, canvas: *const Canvas, texturer: anytype) void {
    const cx = @cos(rect.rotation_rad);
    const sx = @sin(rect.rotation_rad);
    const u = physics.Vec2{
        .x = cx,
        .y = sx,
    };

    const v = physics.Vec2{
        .x = -sx,
        .y = cx,
    };

    const u_scaled = u.mul(rect.width / 2.0);
    const v_scaled = v.mul(rect.height / 2.0);
    const u_scaled_neg = u_scaled.mul(-1.0);
    const v_scaled_neg = v_scaled.mul(-1.0);

    var corners = [4]Pos2{
        rect.center.add(u_scaled).add(v_scaled),
        rect.center.add(u_scaled).add(v_scaled_neg),
        rect.center.add(u_scaled_neg).add(v_scaled_neg),
        rect.center.add(u_scaled_neg).add(v_scaled),
    };

    const pointLessThan = struct {
        fn f(_: void, lhs: Pos2, rhs: Pos2) bool {
            return lhs.y < rhs.y;
        }
    }.f;

    const highest_elem = std.sort.argMax(Pos2, &corners, {}, pointLessThan).?;
    std.mem.rotate(Pos2, &corners, highest_elem);

    var it = ScanlineIter.init(
        &.{ canvas.toPixelPos(corners[0]), canvas.toPixelPos(corners[3]), canvas.toPixelPos(corners[2]) },
        &.{ canvas.toPixelPos(corners[0]), canvas.toPixelPos(corners[1]), canvas.toPixelPos(corners[2]) },
    );

    const uv_calc = RectUVCalc.init(canvas.toPixelPos(rect.center), canvas.toXPx(rect.width), canvas.toXPx(rect.height), rect.rotation_rad);

    const canvas_height = canvas.height();
    while (it.next()) |row| {
        if (row.y < 0 or row.y >= canvas_height) {
            continue;
        }

        var x = row.left;
        while (true) {
            if (x >= row.right) {
                break;
            }
            defer x += 1;
            if (x < 0 or x >= canvas.width) {
                continue;
            }

            const uv = uv_calc.calcUv(.{ .x = x, .y = row.y });
            const y_u: usize = @intCast(row.y);
            const x_u: usize = @intCast(x);
            const idx = y_u * canvas.width + x_u;
            canvas.data[idx] = texturer.get(uv.x, uv.y, canvas.data[idx]);
        }
    }
}

pub fn renderRect(rect: Rect, canvas: *const Canvas, texturer: anytype) void {
    const half_width = rect.width / 2.0;
    const half_height = rect.height / 2.0;
    const x_start = canvas.toXPx(rect.center.x - half_width);
    const x_end = canvas.toXPx(rect.center.x + half_width);
    const x_dist: f32 = @floatFromInt(x_end - x_start);

    const y_start = canvas.toYPx(rect.center.y + half_height);
    const y_end = canvas.toYPx(rect.center.y - half_height);
    const y_dist: f32 = @floatFromInt(y_end - y_start);

    const canvas_height = canvas.height();
    var y = y_start;
    while (true) {
        if (y >= y_end) {
            break;
        }
        defer y += 1;

        if (y < 0 or y >= canvas_height) {
            continue;
        }

        const y_u: usize = @intCast(y);

        var x = x_start;
        while (true) {
            if (x >= x_end) {
                break;
            }
            defer x += 1;

            if (x < 0 or x >= canvas.width) {
                continue;
            }

            const x_u: usize = @intCast(x);

            var x_norm: f32 = @floatFromInt(x - x_start);
            x_norm /= x_dist;

            var y_norm: f32 = @floatFromInt(y - y_start);
            y_norm /= y_dist;

            const idx = y_u * canvas.width + x_u;
            canvas.data[idx] = texturer.get(x_norm, y_norm, canvas.data[idx]);
        }
    }
}

fn interpolatePos(a: Pos2, b: Pos2, t: f32) Pos2 {
    return .{
        .x = std.math.lerp(a.x, b.x, t),
        .y = std.math.lerp(a.y, b.y, t),
    };
}

fn lerpBezierPoints(points: []const Pos2, t: f32) Pos2 {
    var lerped: [10]Pos2 = undefined;
    @memcpy(lerped[0..points.len], points);
    var num_points = points.len;

    while (num_points > 1) {
        for (0..num_points - 1) |i| {
            lerped[i] = interpolatePos(lerped[i], lerped[i + 1], t);
        }
        num_points -= 1;
    }

    return lerped[0];
}

pub fn renderBezier(control_points: []const Pos2, line_width: f32, canvas: *const Canvas, texturer: anytype) void {
    const num_points = 20;
    var points: [num_points]struct {
        pos: Pos2,
        t: f32,
    } = undefined;

    points[0] = .{
        .pos = control_points[0],
        .t = 0,
    };
    points[num_points - 1] = .{ .pos = control_points[control_points.len - 1], .t = 1.0 };

    for (1..num_points - 1) |i| {
        var t: f32 = @floatFromInt(i);
        t /= num_points;
        points[i] = .{
            .pos = lerpBezierPoints(control_points, t),
            .t = t,
        };
    }

    const UvModifier = struct {
        inner: @TypeOf(texturer),
        mul: f32,
        offs: f32,

        pub fn get(self: *const @This(), x: f32, y: f32, old_px: u32) u32 {
            return self.inner.get((x * self.mul) + self.offs, y, old_px);
        }
    };

    var traversed_width: f32 = 0.0;
    for (0..num_points - 1) |i| {
        var rect = lineToRect(points[i].pos, points[i + 1].pos, line_width);
        rect.width *= 1.2;
        const t_diff = points[i + 1].t - points[i].t;
        const uv_modifier = UvModifier{
            .inner = texturer,
            .mul = t_diff,
            .offs = points[i].t,
        };
        traversed_width += rect.width;
        renderRotatedRect(rect, canvas, uv_modifier);
    }
}

pub fn lineToRect(start: Pos2, end: Pos2, height: f32) Rect {
    const diff = end.sub(start);
    const rot = std.math.atan2(diff.y, diff.x);
    const center = start.add(end.sub(start).mul(0.5));
    const width = end.sub(start).length();

    return Rect{
        .center = center,
        .width = width,
        .height = height,
        .rotation_rad = rot,
    };
}

const PixelPos = struct {
    x: i64,
    y: i64,
};

const YLineCalc = struct {
    x_dist: i64,
    y_dist: i64,
    start_y: i64,
    start_x: i64,
    end_x: i64,

    fn init(start: PixelPos, end: PixelPos) YLineCalc {
        if (start.x > end.x) {
            return init(end, start);
        }
        return .{
            .x_dist = end.x - start.x,
            .y_dist = end.y - start.y,
            .start_y = start.y,
            .start_x = start.x,
            .end_x = end.x,
        };
    }

    fn leftXForY(self: YLineCalc, y: i64) i64 {
        // Integer math equivalent of
        // t = y_traveled / y_dist
        // t * x_dist
        if (self.y_dist == 0) {
            return self.start_x;
        }
        const t = y - self.start_y;
        const x_t = std.math.clamp(@divTrunc(t * self.x_dist, self.y_dist), 0, self.x_dist);
        return self.start_x + x_t;
    }

    fn rightXForY(self: YLineCalc, y: i64) i64 {
        if (self.y_dist == 0) {
            return self.end_x;
        }
        return self.leftXForY(y + 1);
    }
};

const ScanlineIter = struct {
    left: []const PixelPos,
    right: []const PixelPos,
    left_calc: YLineCalc,
    right_calc: YLineCalc,
    y: i64,

    const Output = struct {
        y: i64,
        left: i64,
        right: i64,
    };

    fn init(left: []const PixelPos, right: []const PixelPos) ScanlineIter {
        std.debug.assert(verticallySorted(left));
        std.debug.assert(verticallySorted(right));

        return .{
            .left = left,
            .right = right,
            .left_calc = YLineCalc.init(left[0], left[1]),
            .right_calc = YLineCalc.init(right[0], right[1]),
            .y = left[0].y,
        };
    }

    fn next(self: *ScanlineIter) ?Output {
        if (self.updateCalcs()) {
            return null;
        }

        defer self.y += 1;

        const left = self.left_calc.leftXForY(self.y);
        const right = self.right_calc.rightXForY(self.y);

        return .{
            .y = self.y,
            .left = left,
            .right = right,
        };
    }

    fn updateCalcs(self: *ScanlineIter) bool {
        if (self.left.len < 2 or self.right.len < 2) {
            return true;
        }

        if (self.y >= self.left[1].y) {
            self.left = self.left[1..];
            if (self.left.len < 2) {
                return true;
            }
            self.left_calc = YLineCalc.init(self.left[0], self.left[1]);
        }

        if (self.y >= self.right[1].y) {
            self.right = self.right[1..];
            if (self.right.len < 2) {
                return true;
            }
            self.right_calc = YLineCalc.init(self.right[0], self.right[1]);
        }

        return false;
    }

    fn verticallySorted(items: []const PixelPos) bool {
        return std.sort.isSorted(PixelPos, items, {}, struct {
            fn f(_: void, lhs: PixelPos, rhs: PixelPos) bool {
                return lhs.y < rhs.y;
            }
        }.f);
    }
};

const RectUVCalc = struct {
    center: PixelPos,
    width_px: f32,
    height_px: f32,
    u_norm: Vec2,

    fn init(center: PixelPos, width_px: i64, height_px: i64, rotation: f32) RectUVCalc {
        return .{
            .center = center,
            .width_px = @floatFromInt(width_px),
            .height_px = @floatFromInt(height_px),
            .u_norm = .{
                .x = @cos(-rotation),
                .y = @sin(-rotation),
            },
        };
    }

    fn calcUv(self: RectUVCalc, pos: PixelPos) Pos2 {
        const center_offs = Vec2{
            .x = @floatFromInt(pos.x - self.center.x),
            .y = @floatFromInt(pos.y - self.center.y),
        };
        const v_norm = Vec2{
            .x = -self.u_norm.y,
            .y = self.u_norm.x,
        };
        const u = center_offs.dot(self.u_norm) / self.width_px + 0.5;
        const v = center_offs.dot(v_norm) / self.height_px + 0.5;
        return .{
            .x = u,
            .y = v,
        };
    }
};
