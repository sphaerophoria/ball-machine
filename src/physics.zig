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

pub const Pos2 = extern struct {
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

pub const Vec2 = extern struct {
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

pub const Surface = extern struct {
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

    pub fn pushIfColliding(self: *const Surface, ball: *Ball, delta: f32) void {
        const n = self.normal();

        if (ball.velocity.dot(n) > 0) {
            return;
        }

        const pa = self.a.sub(ball.pos);
        const pb = self.b.sub(ball.pos);
        const ab = self.b.sub(self.a);

        const dpa = pa.dot(ab);
        const dpb = pb.dot(ab);

        const r_2 = ball.r * ball.r;
        const most_overlapping_point = blk: {
            if (dpa > 0 and dpb > 0) {
                if (pa.length_2() > r_2) {
                    return;
                }

                break :blk ball.pos.add(pa.normalized().mul(ball.r));
            } else if (dpa < 0 and dpb < 0) {
                if (pb.length_2() > r_2) {
                    return;
                }

                break :blk ball.pos.add(pb.normalized().mul(ball.r));
            } else {
                break :blk ball.pos.add(n.mul(-ball.r));
            }
        };

        const overlap_amount = self.b.sub(most_overlapping_point).dot(n);
        const max_push = 0.001;

        // In some cases the ball may be coming from under the surface. In
        // these cases we actually do not want to apply the push unless the
        // ball is very close to making it all the way through. Otherwise we
        // either do a bunch of continual small pushes, which makes the ball
        // movement slow and weird, or we snap the ball all the way through the
        // surface which is jarring. Limit the push to 1/4 the diameter of the ball
        const collision_zone = ball.r / 2.0;

        if (overlap_amount > 0.0 and overlap_amount < collision_zone) {
            const bn: Vec2 = .{
                .x = n.y,
                .y = n.x,
            };

            const preserved_velocity = bn.mul(ball.velocity.dot(bn));
            const push_amount = @min(overlap_amount, max_push);
            const frame_push = n.mul(push_amount);
            const push_velocity = frame_push.mul(1.01 / delta);
            ball.velocity = push_velocity.add(preserved_velocity);
            ball.pos = ball.pos.add(n.mul(overlap_amount));
        }
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

pub fn applyCollision(ball: *Ball, resolution: Vec2, obj_normal: Vec2, delta: f32, elasticity: f32) void {
    const vel_ground_proj_mag = ball.velocity.dot(obj_normal);
    var vel_adjustment = obj_normal.mul(-vel_ground_proj_mag);
    vel_adjustment = vel_adjustment.add(vel_adjustment.mul(elasticity));

    ball.velocity = ball.velocity.add(vel_adjustment);
    ball.pos = ball.pos.add(resolution);
    ball.pos = ball.pos.add(ball.velocity.mul(delta));
}

pub fn applyBallCollision(a: *Ball, b: *Ball) void {
    const ball_ball_elasticity = 0.9;
    const n = b.pos.sub(a.pos).normalized();
    const vel_diff = a.velocity.sub(b.velocity);
    const change_in_velocity = n.mul(vel_diff.dot(n));

    a.velocity = a.velocity.sub(change_in_velocity).mul(ball_ball_elasticity);
    // NOTE: This only works because a and b have the same mass
    b.velocity = b.velocity.add(change_in_velocity).mul(ball_ball_elasticity);

    const balls_distance = a.pos.sub(b.pos).length();
    const overlap = a.r + b.r - balls_distance;
    if (overlap > 0) {
        b.pos = b.pos.add(n.mul(overlap / 2.0));
        a.pos = a.pos.add(n.mul(-overlap / 2.0));
    }
}
