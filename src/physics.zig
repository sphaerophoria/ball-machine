const std = @import("std");
const builtin = @import("builtin");

pub const Ball = struct {
    pos: Pos2,
    r: f32,
    velocity: Vec2,
};

pub fn assertBallLayout() void {
    std.debug.assert(@alignOf(Ball) == 4);
    std.debug.assert(@sizeOf(Ball) == 20);

    const ball: Ball = undefined;
    std.debug.assert(@offsetOf(Ball, "pos") == 0);
    std.debug.assert(@intFromPtr(&ball.pos.x) - @intFromPtr(&ball.pos) == 0);
    std.debug.assert(@intFromPtr(&ball.pos.y) - @intFromPtr(&ball.pos) == 4);

    std.debug.assert(@offsetOf(Ball, "r") == 8);

    std.debug.assert(@offsetOf(Ball, "velocity") == 12);
    std.debug.assert(@intFromPtr(&ball.velocity.x) - @intFromPtr(&ball.velocity) == 0);
    std.debug.assert(@intFromPtr(&ball.velocity.y) - @intFromPtr(&ball.velocity) == 4);
}

pub const Pos2 = struct {
    x: f32,
    y: f32,

    pub fn add(p: Pos2, v: Vec2) Pos2 {
        return .{
            .x = p.x + v.x,
            .y = p.y + v.y,
        };
    }

    pub fn sub(a: Pos2, b: Pos2) Vec2 {
        return .{
            .x = a.x - b.x,
            .y = a.y - b.y,
        };
    }
};

pub const Vec2 = struct {
    x: f32,
    y: f32,

    pub fn length_2(self: Vec2) f32 {
        return self.x * self.x + self.y * self.y;
    }

    pub fn length(self: Vec2) f32 {
        return @sqrt(self.length_2());
    }

    pub fn add(a: Vec2, b: Vec2) Vec2 {
        return .{
            .x = a.x + b.x,
            .y = a.y + b.y,
        };
    }

    pub fn sub(a: Vec2, b: Vec2) Vec2 {
        return .{
            .x = a.x - b.x,
            .y = a.y - b.y,
        };
    }

    pub fn mul(self: Vec2, val: f32) Vec2 {
        return .{
            .x = self.x * val,
            .y = self.y * val,
        };
    }

    pub fn dot(a: Vec2, b: Vec2) f32 {
        return a.x * b.x + a.y * b.y;
    }

    pub fn normalized(self: Vec2) Vec2 {
        return self.mul(1.0 / self.length());
    }
};

pub const Surface = struct {
    // Assumed normal points up if a is left of b, down if b is left of a
    a: Pos2,
    b: Pos2,

    // Given a point p that has traveled through vector v, what movement has to
    // be performed to undo the collision?
    pub fn collisionResolution(self: *const Surface, p: Pos2, v: Vec2) ?Vec2 {
        //                          b
        //         \       | v  _-^
        //          \      | _-^
        //          n\    _-^
        //            \_-^ |
        //          _-^\   |
        //       _-^    \  | res
        //  a _-^      l \o|
        //     ^^^^----___\|
        //                 p
        //
        // (note that n is perpendicular to a/b)
        //
        // * Use projection of ap onto n, that gives us line l
        // * With n and v we can find angle o
        // * With angle o and l, we can find res
        //

        const ap = self.a.sub(p);
        const n = self.normal();
        const l = ap.dot(n);

        // If l is negative, p is above the line. If p is above the line there
        // is no way that it could have gone through it in the opposite
        // direction of the normal
        if (l < 0) {
            return null;
        }

        const v_norm_neg = v.mul(-1.0 / v.length());
        const cos_o = n.dot(v_norm_neg);

        const intersection_dist = l / cos_o;

        const adjustment = v_norm_neg.mul(intersection_dist);
        const intersection_point = p.add(adjustment);

        const point_on_surface = pointWithinLineBounds(intersection_point, self.a, self.b);
        const path_start_pos = p.add(v.mul(-1));
        const point_on_movement_vec = pointWithinLineBounds(intersection_point, path_start_pos, p);
        const collided = point_on_surface and point_on_movement_vec;

        if (!collided) {
            return null;
        }

        return adjustment;
    }

    pub fn normal(self: *const Surface) Vec2 {
        var v = self.b.sub(self.a);
        v = v.mul(1.0 / v.length());

        return .{
            .x = -v.y,
            .y = v.x,
        };
    }
};

// Given a point p which is on an infinite line that goes through a and b, is p between a and b?
fn pointWithinLineBounds(p: Pos2, a: Pos2, b: Pos2) bool {
    // P is out of bounds if it's left of both a and b, or right of both a and
    // b. Therefore it's in bounds if it is on a different side of a and b
    const within_x_bounds = (a.x < p.x) != (b.x < p.x);
    const within_y_bounds = (a.y < p.y) != (b.y < p.y);

    // We check x intersection OR y intersection, because if there is a
    // very small range for one, then it may end up being a false negative.
    // We use the other axis to avoid precision issues.
    return within_x_bounds or within_y_bounds;
}

const ball_elasticity_multiplier = 0.90;

pub fn applyCollision(ball: *Ball, resolution: Vec2, obj_normal: Vec2, delta: f32) void {
    const vel_ground_proj_mag = ball.velocity.dot(obj_normal);
    const vel_adjustment = obj_normal.mul(-vel_ground_proj_mag * 2);

    ball.velocity = ball.velocity.add(vel_adjustment);
    const lost_velocity = (1.0 - ball_elasticity_multiplier) * (@abs(obj_normal.dot(ball.velocity.normalized())));
    ball.velocity = ball.velocity.mul(1.0 - lost_velocity);

    ball.pos = ball.pos.add(resolution);
    ball.pos = ball.pos.add(ball.velocity.mul(delta));
}

pub fn applyBallCollision(a: *Ball, b: *Ball) void {
    const n = b.pos.sub(a.pos).normalized();
    const vel_diff = a.velocity.sub(b.velocity);
    const change_in_velocity = n.mul(vel_diff.dot(n));

    a.velocity = a.velocity.sub(change_in_velocity).mul(ball_elasticity_multiplier);
    // NOTE: This only works because a and b have the same mass
    b.velocity = b.velocity.add(change_in_velocity).mul(ball_elasticity_multiplier);

    const balls_distance = a.pos.sub(b.pos).length();
    const overlap = a.r + b.r - balls_distance;
    if (overlap > 0) {
        b.pos = b.pos.add(n.mul(overlap / 2.0));
        a.pos = a.pos.add(n.mul(-overlap / 2.0));
    }
}
