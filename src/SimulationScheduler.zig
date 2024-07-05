const Simulation = @import("Simulation.zig");

const SimulationScheduler = @This();

adjustment: i64 = 0,
speed: f32 = 1.0,

pub fn shouldStep(self: *SimulationScheduler, now: f32, num_steps_taken: u64) bool {
    const desired_num_steps_taken = desiredStepsTaken(now, self.speed);
    var effective_steps_taken: i64 = @intCast(num_steps_taken);
    effective_steps_taken += self.adjustment;
    return effective_steps_taken < desired_num_steps_taken;
}

pub fn setSpeed(self: *SimulationScheduler, now: f32, ratio: f32, num_steps_taken: u64) void {
    self.adjustment = @intCast(desiredStepsTaken(now, ratio));
    self.adjustment -= @intCast(num_steps_taken);
    self.speed = ratio;
}

fn desiredStepsTaken(now: f32, speed: f32) u64 {
    return @intFromFloat(now / Simulation.step_len_s * speed);
}
