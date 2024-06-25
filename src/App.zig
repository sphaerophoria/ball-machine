const std = @import("std");
const Allocator = std.mem.Allocator;
const Simulation = @import("Simulation.zig");
const wasm_chamber = @import("wasm_chamber.zig");

const ChamberPaths = std.ArrayListUnmanaged([]const u8);
const ChamberMods = std.ArrayListUnmanaged(wasm_chamber.WasmChamber);
const Simulations = std.ArrayListUnmanaged(Simulation);

const App = @This();

alloc: Allocator,
mutex: std.Thread.Mutex = .{},
wasm_loader: wasm_chamber.WasmLoader,
chamber_paths: ChamberPaths,
chamber_mods: ChamberMods,
simulations: Simulations,
db_path: []const u8,
shutdown: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
new_chamber_idx: usize = 0,

pub fn init(alloc: Allocator, chamber_paths_in: []const []const u8, db_path: []const u8) !App {
    var ret = try initEmpty(alloc, db_path, chamber_paths_in.len);
    errdefer ret.deinit();

    for (chamber_paths_in) |p| {
        const chamber_f = try std.fs.cwd().openFile(p, .{});
        defer chamber_f.close();
        const chamber_content = try chamber_f.readToEndAlloc(alloc, 1_000_000);
        defer alloc.free(chamber_content);

        try ret.appendChamber(chamber_content);
    }

    return ret;
}

pub fn initFromHistory(alloc: Allocator, chamber_path: []const u8, db_path: []const u8, history_path: []const u8, history_start_idx: usize) !App {
    var ret = try initEmpty(alloc, db_path, 1);
    // NOTE: do not need to worry about consistency of lists in ret because
    // failure results in ret never returning
    // This errdefer also does a lot of heavy lifting of freeing allocated
    // resources of things that make it into the lists
    errdefer ret.deinit();

    const chamber_f = try std.fs.cwd().openFile(chamber_path, .{});
    defer chamber_f.close();
    const chamber_content = try chamber_f.readToEndAlloc(alloc, 1_000_000);
    defer alloc.free(chamber_content);

    var chamber = try ret.wasm_loader.load(alloc, chamber_content);
    ret.chamber_mods.append(alloc, chamber) catch |e| {
        chamber.deinit();
        return e;
    };

    var simulation = try Simulation.initFromHistory(alloc, chamber, history_path, history_start_idx);
    ret.simulations.append(alloc, simulation) catch |e| {
        simulation.deinit();
        return e;
    };

    const duped_path = try alloc.dupe(u8, chamber_path);
    ret.chamber_paths.append(alloc, duped_path) catch |e| {
        alloc.free(duped_path);
        return e;
    };

    return ret;
}

fn initEmpty(alloc: Allocator, db_path: []const u8, capacity: usize) !App {
    try std.fs.cwd().makePath(db_path);

    var wasm_loader = try wasm_chamber.WasmLoader.init();
    errdefer wasm_loader.deinit();

    var chamber_mods = try ChamberMods.initCapacity(alloc, capacity);
    errdefer deinitChamberMods(alloc, &chamber_mods);

    var simulations = try Simulations.initCapacity(alloc, capacity);
    errdefer deinitSimulations(alloc, &simulations);

    var chamber_paths = try ChamberPaths.initCapacity(alloc, capacity);
    errdefer deinitChamberPaths(alloc, &chamber_paths);

    return App{
        .alloc = alloc,
        .wasm_loader = wasm_loader,
        .chamber_paths = chamber_paths,
        .chamber_mods = chamber_mods,
        .simulations = simulations,
        .db_path = db_path,
    };
}

pub fn deinit(self: *App) void {
    deinitChamberPaths(self.alloc, &self.chamber_paths);
    deinitChamberMods(self.alloc, &self.chamber_mods);
    deinitSimulations(self.alloc, &self.simulations);
    self.wasm_loader.deinit();
}

pub fn run(self: *App) !void {
    const start = try std.time.Instant.now();

    const initial_step = self.simulations.items[0].num_steps_taken;
    std.debug.assert(self.simulations.items.len == 1 or initial_step == 0);

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

pub fn appendChamber(self: *App, data: []const u8) !void {
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

    const fname = try std.fmt.allocPrint(self.alloc, "{s}/app_chamber_{d}.wasm", .{ self.db_path, self.new_chamber_idx });
    self.new_chamber_idx += 1;
    const f = try std.fs.cwd().createFile(fname, .{});
    defer f.close();
    try f.writeAll(data);

    try self.chamber_paths.append(self.alloc, fname);
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

fn deinitChamberPaths(alloc: Allocator, paths: *ChamberPaths) void {
    for (paths.items) |p| {
        alloc.free(p);
    }
    paths.deinit(alloc);
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
