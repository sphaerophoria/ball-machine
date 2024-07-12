const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const wasm_chamber = @import("wasm_chamber.zig");
const Simulation = @import("Simulation.zig");

const ChamberTester = @This();

loader: wasm_chamber.WasmLoader,

fn getStepFuelLimit() comptime_int {
    return switch (builtin.mode) {
        .Debug => 2_500_000,
        else => 800_000, // On my machine, somewhere between 200-400K is ~65us
    };
}

const step_fuel_limit = getStepFuelLimit();
const init_fuel_limit = step_fuel_limit * 500;
const render_fuel_limit = step_fuel_limit * 500;
const max_save_size = 30;
const canvas_width = 400;
const canvas_height = canvas_width * Simulation.chamber_height;
const canvas_max_pixels = canvas_width * canvas_height;

pub fn init() !ChamberTester {
    const loader = try wasm_chamber.WasmLoader.initWithLimits(
        init_fuel_limit,
        step_fuel_limit,
        render_fuel_limit,
        65536 * 10,
    );

    return .{
        .loader = loader,
    };
}

pub fn ensureValidChamber(self: *ChamberTester, alloc: Allocator, data: []const u8) !void {
    var chamber = try self.loader.load(alloc, data);
    defer chamber.deinit();

    var simulation = try Simulation.init(alloc, 0, canvas_max_pixels);
    defer simulation.deinit();

    const chamber_if = chamber.chamber();
    try simulation.addChamber(chamber_if);

    const save_size = try chamber.saveSize();
    if (save_size < 0 or save_size > max_save_size) {
        return error.SaveTooLarge;
    }

    try simulation.setNumBalls(100);
    simulation.setChambersPerRow(1);

    for (0..10000) |_| {
        try simulation.step();

        const save = try chamber_if.save(alloc);
        defer alloc.free(save);

        try chamber_if.load(save);
        try chamber.render(canvas_width, canvas_height);
    }
}
