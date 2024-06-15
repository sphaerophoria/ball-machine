//pub fn incrementVar(a: *i32, b: i32) void {
//    a.* += b;
//}

pub const Pos2 = extern struct {
    x: f32,
    y: f32,

    pub fn add(p: Pos2, v: f32) Pos2 {
        return .{
            .x = p.x + v,
            .y = p.y + v,
        };
    }
};
