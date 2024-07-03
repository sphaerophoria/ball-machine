const std = @import("std");
const Allocator = std.mem.Allocator;
const Simulation = @import("Simulation.zig");
const wasm_chamber = @import("wasm_chamber.zig");
const Chamber = @import("Chamber.zig");
const Db = @import("Db.zig");

const ChamberIds = std.ArrayListUnmanaged(i64);
const ChamberMods = std.ArrayListUnmanaged(*wasm_chamber.WasmChamber);

const App = @This();

alloc: Allocator,
wasm_loader: wasm_chamber.WasmLoader,
chamber_ids: ChamberIds,
chamber_mods: ChamberMods,
simulation: Simulation,
new_chamber_idx: usize = 0,
start: std.time.Instant,

pub fn init(alloc: Allocator, chambers: []const Db.Chamber) !App {
    var ret = try initEmpty(alloc, chambers.len);
    errdefer ret.deinit();

    for (chambers) |db_chamber| {
        try ret.appendChamber(db_chamber.id, db_chamber.data);
    }

    return ret;
}

fn initEmpty(alloc: Allocator, capacity: usize) !App {
    var wasm_loader = try wasm_chamber.WasmLoader.init();
    errdefer wasm_loader.deinit();

    var chamber_mods = try ChamberMods.initCapacity(alloc, capacity);
    errdefer deinitChamberMods(alloc, &chamber_mods);

    var seed: usize = undefined;
    try std.posix.getrandom(std.mem.asBytes(&seed));

    var simulation = try Simulation.init(alloc, seed);
    errdefer simulation.deinit();

    var chamber_ids = try ChamberIds.initCapacity(alloc, capacity);
    errdefer chamber_ids.deinit(alloc);

    return App{
        .alloc = alloc,
        .wasm_loader = wasm_loader,
        .chamber_ids = chamber_ids,
        .chamber_mods = chamber_mods,
        .simulation = simulation,
        .start = try std.time.Instant.now(),
    };
}

pub fn deinit(self: *App) void {
    self.chamber_ids.deinit(self.alloc);
    deinitChamberMods(self.alloc, &self.chamber_mods);
    self.simulation.deinit();
    self.wasm_loader.deinit();
}

pub fn step(self: *App) !void {
    const now = try std.time.Instant.now();
    const elapsed_time_ns = now.since(self.start);

    const desired_num_steps_taken = elapsed_time_ns / Simulation.step_len_ns;

    while (self.simulation.num_steps_taken < desired_num_steps_taken) {
        try self.simulation.step();
    }
}

pub fn appendChamber(self: *App, db_id: i64, data: []const u8) !void {
    const chamber = try self.alloc.create(wasm_chamber.WasmChamber);
    errdefer self.alloc.destroy(chamber);
    chamber.* = try self.wasm_loader.load(self.alloc, data);
    errdefer chamber.deinit();

    try self.chamber_mods.append(self.alloc, chamber);
    errdefer {
        _ = self.chamber_mods.pop();
    }

    try self.simulation.addChamber(self.chamber_mods.getLast().chamber());
    errdefer {
        _ = self.simulation.chambers.pop();
    }

    try self.chamber_ids.append(self.alloc, db_id);
    errdefer {
        _ = self.chamber_ids.pop();
    }
}

fn deinitChamberMods(alloc: Allocator, chambers: *ChamberMods) void {
    for (chambers.items) |chamber| {
        chamber.deinit();
        alloc.destroy(chamber);
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
