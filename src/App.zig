const std = @import("std");
const Allocator = std.mem.Allocator;
const Simulation = @import("Simulation.zig");
const wasm_chamber = @import("wasm_chamber.zig");
const Db = @import("Db.zig");

const ChamberIds = std.ArrayListUnmanaged(i64);
const ChamberMods = std.ArrayListUnmanaged(wasm_chamber.WasmChamber);
const Simulations = std.ArrayListUnmanaged(Simulation);

const App = @This();

alloc: Allocator,
mutex: std.Thread.Mutex = .{},
wasm_loader: wasm_chamber.WasmLoader,
chamber_ids: ChamberIds,
chamber_mods: ChamberMods,
simulations: Simulations,
shutdown: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
new_chamber_idx: usize = 0,

pub fn init(alloc: Allocator, chambers: []const Db.Chamber) !App {
    var ret = try initEmpty(alloc, chambers.len);
    errdefer ret.deinit();

    for (chambers) |db_chamber| {
        try ret.appendChamber(db_chamber.id, db_chamber.data);
    }

    return ret;
}

pub fn initFromHistory(alloc: Allocator, history_path: []const u8, history_start_idx: usize, chambers: []const Db.Chamber) !App {
    var ret = try initEmpty(alloc, chambers.len);
    errdefer ret.deinit();

    const f = try std.fs.cwd().openFile(history_path, .{});
    var json_reader = std.json.reader(alloc, f.reader());
    defer json_reader.deinit();

    const parsed = try std.json.parseFromTokenSource(Simulation.SimulationSave, alloc, &json_reader, .{});
    defer parsed.deinit();

    if (history_start_idx >= parsed.value.steps.len) {
        return error.InvalidStartIdx;
    }

    for (chambers) |db_chamber| {
        try ret.appendChamber(db_chamber.id, db_chamber.data);
        const added_simulation = &ret.simulations.items[ret.simulations.items.len - 1];
        added_simulation.num_steps_taken = parsed.value.steps[history_start_idx].num_steps_taken;
        if (parsed.value.chamber_id == db_chamber.id) {
            try added_simulation.loadSnapshot(parsed.value.steps[history_start_idx]);
        }
    }

    return ret;
}

fn initEmpty(alloc: Allocator, capacity: usize) !App {
    var wasm_loader = try wasm_chamber.WasmLoader.init();
    errdefer wasm_loader.deinit();

    var chamber_mods = try ChamberMods.initCapacity(alloc, capacity);
    errdefer deinitChamberMods(alloc, &chamber_mods);

    var simulations = try Simulations.initCapacity(alloc, capacity);
    errdefer deinitSimulations(alloc, &simulations);

    var chamber_ids = try ChamberIds.initCapacity(alloc, capacity);
    errdefer chamber_ids.deinit(alloc);

    return App{
        .alloc = alloc,
        .wasm_loader = wasm_loader,
        .chamber_ids = chamber_ids,
        .chamber_mods = chamber_mods,
        .simulations = simulations,
    };
}

pub fn deinit(self: *App) void {
    self.chamber_ids.deinit(self.alloc);
    deinitChamberMods(self.alloc, &self.chamber_mods);
    deinitSimulations(self.alloc, &self.simulations);
    self.wasm_loader.deinit();
}

pub fn run(self: *App) !void {
    const start = try std.time.Instant.now();

    const initial_step = if (self.simulations.items.len > 0) self.simulations.items[0].num_steps_taken else 0;

    while (!self.shutdown.load(.unordered)) {
        std.time.sleep(1_666_666);

        const now = try std.time.Instant.now();
        const elapsed_time_ns = now.since(start);

        const desired_num_steps_taken = initial_step + elapsed_time_ns / Simulation.step_len_ns;

        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.simulations.items) |*ctx| {
            while (ctx.num_steps_taken < desired_num_steps_taken) {
                ctx.step();
            }
        }
    }
}

pub fn appendChamber(self: *App, db_id: i64, data: []const u8) !void {
    self.mutex.lock();
    defer self.mutex.unlock();

    var chamber = try self.wasm_loader.load(self.alloc, data);
    errdefer chamber.deinit();

    var simulation = try initSimulation(self.alloc, chamber);
    errdefer simulation.deinit();

    if (self.simulations.items.len > 0) {
        simulation.num_steps_taken = self.simulations.items[0].num_steps_taken;
    }

    try self.chamber_mods.append(self.alloc, chamber);
    errdefer {
        _ = self.chamber_mods.pop();
    }

    try self.simulations.append(self.alloc, simulation);
    errdefer {
        _ = self.simulations.pop();
    }

    try self.chamber_ids.append(self.alloc, db_id);
}

fn deinitSimulations(alloc: Allocator, simulations: *Simulations) void {
    for (simulations.items) |*simulation| {
        simulation.deinit();
    }
    simulations.deinit(alloc);
}

fn deinitChamberMods(alloc: Allocator, chambers: *ChamberMods) void {
    for (chambers.items) |*chamber| {
        chamber.deinit();
    }
    chambers.deinit(alloc);
}

fn loadChamber(alloc: Allocator, wasm_loader: *wasm_chamber.WasmLoader, path: []const u8) !wasm_chamber.WasmChamber {
    const chamber_f = try std.fs.cwd().openFile(path, .{});
    defer chamber_f.close();
    const chamber_content = try chamber_f.readToEndAlloc(alloc, 1_000_000);
    defer alloc.free(chamber_content);

    var chamber = try wasm_loader.load(alloc, chamber_content);
    errdefer chamber.deinit();

    return chamber;
}

fn initSimulation(alloc: Allocator, mod: wasm_chamber.WasmChamber) !Simulation {
    var seed: usize = undefined;
    try std.posix.getrandom(std.mem.asBytes(&seed));

    return try Simulation.init(alloc, seed, mod);
}
