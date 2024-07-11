const std = @import("std");
const Allocator = std.mem.Allocator;
const Simulation = @import("Simulation.zig");
const wasm_chamber = @import("wasm_chamber.zig");
const Chamber = @import("Chamber.zig");
const Db = @import("Db.zig");
const physics = @import("physics.zig");
const circular_buffer = @import("circular_buffer.zig");
const Ball = physics.Ball;

const ChamberIds = std.ArrayListUnmanaged(Db.ChamberId);
const ChamberMods = std.ArrayListUnmanaged(*wasm_chamber.WasmChamber);

const ServerSimulation = @This();

fn deinitSnapshot(alloc: Allocator, snapshot: Snapshot) void {
    snapshot.deinit(alloc);
}

pub const SnapshotHistory = circular_buffer.CircularBuffer(Snapshot, Allocator, deinitSnapshot);

pub const Snapshot = struct {
    chamber_balls: []const []const Ball,
    chamber_states: []const []const u8,
    num_steps_taken: u64,

    fn deinit(self: *const Snapshot, alloc: Allocator) void {
        for (self.chamber_states) |val| {
            alloc.free(val);
        }
        alloc.free(self.chamber_states);
        for (self.chamber_balls) |balls| {
            alloc.free(balls);
        }
        alloc.free(self.chamber_balls);
    }
};

alloc: Allocator,
wasm_loader: wasm_chamber.WasmLoader,
chamber_ids: ChamberIds,
chamber_mods: ChamberMods,
simulation: Simulation,
new_chamber_idx: usize = 0,
history: SnapshotHistory,
start: std.time.Instant,

pub fn init(alloc: Allocator, chambers: []const Db.Chamber) !ServerSimulation {
    var ret = try initEmpty(alloc, chambers.len);
    errdefer ret.deinit();

    for (chambers) |db_chamber| {
        try ret.appendChamber(db_chamber.id, db_chamber.data);
    }

    return ret;
}

fn initEmpty(alloc: Allocator, capacity: usize) !ServerSimulation {
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

    var history = try SnapshotHistory.init(alloc, 15, alloc);
    errdefer history.deinit(alloc);

    return ServerSimulation{
        .alloc = alloc,
        .wasm_loader = wasm_loader,
        .chamber_ids = chamber_ids,
        .chamber_mods = chamber_mods,
        .simulation = simulation,
        .history = history,
        .start = try std.time.Instant.now(),
    };
}

pub fn deinit(self: *ServerSimulation) void {
    self.chamber_ids.deinit(self.alloc);
    deinitChamberMods(self.alloc, &self.chamber_mods);
    self.simulation.deinit();
    self.history.deinit(self.alloc);
    self.wasm_loader.deinit();
}

pub fn step(self: *ServerSimulation) !void {
    const now = try std.time.Instant.now();
    const elapsed_time_ns = now.since(self.start);

    const desired_num_steps_taken = elapsed_time_ns / Simulation.step_len_ns;

    while (self.simulation.num_steps_taken < desired_num_steps_taken) {
        try self.simulation.step();

        if (self.simulation.num_steps_taken % 10 == 0) {
            const snapshot = try takeSnapshot(self.alloc, &self.simulation);
            errdefer snapshot.deinit(self.alloc);

            try self.history.push(snapshot);
        }
    }
}

pub fn appendChamber(self: *ServerSimulation, chamber_id: Db.ChamberId, data: []const u8) !void {
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

    try self.chamber_ids.append(self.alloc, chamber_id);
    errdefer {
        _ = self.chamber_ids.pop();
    }
}

fn deinitPartiallyAllocatedDoubleSlice(alloc: Allocator, double_slice: anytype, initialized_items: usize) void {
    for (0..initialized_items) |i| {
        alloc.free(double_slice[i]);
    }
    alloc.free(double_slice);
}

fn takeSnapshot(alloc: Allocator, simulation: *Simulation) !Snapshot {
    const num_chambers = simulation.chambers.items.len;

    var num_written_chambers: usize = 0;

    const saves = try alloc.alloc([]const u8, num_chambers);
    errdefer deinitPartiallyAllocatedDoubleSlice(alloc, saves, num_written_chambers);

    const balls = try alloc.alloc([]const Ball, num_chambers);
    errdefer deinitPartiallyAllocatedDoubleSlice(alloc, balls, num_written_chambers);

    for (0..num_chambers) |i| {
        var chamber_balls = try simulation.getChamberBalls(alloc, i);
        defer chamber_balls.deinit(alloc);

        const balls_only = chamber_balls.items(.adjusted);

        balls[i] = try alloc.dupe(Ball, balls_only);
        errdefer alloc.free(balls[i]);

        saves[i] = try simulation.chambers.items[i].save(alloc);
        errdefer alloc.free(saves[i]);

        num_written_chambers = i;
    }

    return .{
        .chamber_balls = balls,
        .chamber_states = saves,
        .num_steps_taken = simulation.num_steps_taken,
    };
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
