const std = @import("std");
const physics = @import("physics.zig");
const Ball = physics.Ball;
const Allocator = std.mem.Allocator;

const c = @cImport({
    @cInclude("wasm.h");
    @cInclude("wasmtime.h");
});

pub const WasmLoader = struct {
    engine: *c.wasm_engine_t,
    store: *c.wasmtime_store_t,
    context: *c.wasmtime_context_t,

    pub fn init() !WasmLoader {
        const engine = c.wasm_engine_new() orelse {
            return error.InitFailure;
        };
        const store = c.wasmtime_store_new(engine, null, null) orelse {
            return error.InitFailure;
        };
        const context = c.wasmtime_store_context(store) orelse {
            return error.InitFailure;
        };

        return .{
            .engine = engine,
            .store = store,
            .context = context,
        };
    }

    pub fn deinit(self: *WasmLoader) void {
        c.wasmtime_store_delete(self.store);
        c.wasm_engine_delete(self.engine);
    }

    pub fn load(self: *WasmLoader, alloc: Allocator, data: []const u8) !WasmChamber {
        const module = try makeModuleFromData(data, self.engine);
        defer c.wasmtime_module_delete(module);
        const memory: *c.wasmtime_memory_t = try alloc.create(c.wasmtime_memory_t);
        errdefer alloc.destroy(memory);

        var instance = try makeInstance(self.context, module, memory);
        memory.* = try loadWasmMemory(self.context, &instance);
        const init_fn = try loadWasmFn("init", self.context, &instance);
        const log_state_fn = try loadWasmFn("logState", self.context, &instance);
        const alloc_fn = try loadWasmFn("alloc", self.context, &instance);
        const free_fn = try loadWasmFn("free", self.context, &instance);
        const step_fn = try loadWasmFn("step", self.context, &instance);
        const save_fn = try loadWasmFn("save", self.context, &instance);
        const save_size_fn = try loadWasmFn("saveSize", self.context, &instance);
        const load_fn = try loadWasmFn("load", self.context, &instance);
        const deinit_fn = try loadWasmFn("deinit", self.context, &instance);

        return .{
            .alloc = alloc,
            .context = self.context,
            .instance = instance,
            .memory = memory,
            .init_fn = init_fn,
            .log_state_fn = log_state_fn,
            .alloc_fn = alloc_fn,
            .free_fn = free_fn,
            .step_fn = step_fn,
            .save_fn = save_fn,
            .save_size_fn = save_size_fn,
            .load_fn = load_fn,
            .deinit_fn = deinit_fn,
        };
    }
};
pub const WasmChamber = struct {
    alloc: Allocator,
    context: *c.wasmtime_context_t,
    instance: c.wasmtime_instance_t,
    memory: *c.wasmtime_memory_t,
    init_fn: c.wasmtime_func_t,
    log_state_fn: c.wasmtime_func_t,
    alloc_fn: c.wasmtime_func_t,
    free_fn: c.wasmtime_func_t,
    step_fn: c.wasmtime_func_t,
    save_fn: c.wasmtime_func_t,
    save_size_fn: c.wasmtime_func_t,
    load_fn: c.wasmtime_func_t,
    deinit_fn: c.wasmtime_func_t,

    pub fn deinit(self: *WasmChamber) void {
        self.alloc.destroy(self.memory);
    }

    pub fn initChamber(self: *WasmChamber) !i32 {
        var result: c.wasmtime_val_t = undefined;
        var trap: ?*c.wasm_trap_t = null;

        const err =
            c.wasmtime_func_call(self.context, &self.init_fn, null, 0, &result, 1, &trap);

        if (err != null or trap != null) {
            return error.InternalError;
        }

        return result.of.i32;
    }

    pub fn load(self: *WasmChamber, data: []const u8) !i32 {
        var result: c.wasmtime_val_t = undefined;
        var trap: ?*c.wasm_trap_t = null;

        const wasm_ptr = try self.allocWasm(data.len, 1);
        const wasm_offs = std.math.cast(usize, wasm_ptr) orelse {
            return error.InvalidOffset;
        };

        defer self.freeWasm(wasm_ptr) catch {
            std.log.err("Failed to free wasm memory", .{});
        };

        const p = c.wasmtime_memory_data(self.context, self.memory);
        @memcpy((p + wasm_offs)[0..data.len], data);

        var input: c.wasmtime_val_t = undefined;
        input.kind = c.WASMTIME_I32;
        input.of.i32 = wasm_ptr;

        const err =
            c.wasmtime_func_call(self.context, &self.load_fn, &input, 1, &result, 1, &trap);

        if (err != null or trap != null) {
            return error.InternalError;
        }

        return result.of.i32;
    }

    pub fn deinitChamber(self: *WasmChamber, state: i32) !void {
        var trap: ?*c.wasm_trap_t = null;

        var input: c.wasmtime_val_t = undefined;
        input.kind = c.WASMTIME_I32;
        input.of.i32 = state;
        const err =
            c.wasmtime_func_call(self.context, &self.deinit_fn, &input, 1, null, 0, &trap);

        if (err != null or trap != null) {
            return error.InternalError;
        }
    }

    pub fn logState(self: *WasmChamber, state: i32) !void {
        var trap: ?*c.wasm_trap_t = null;

        var input: c.wasmtime_val_t = undefined;
        input.kind = c.WASMTIME_I32;
        input.of.i32 = state;
        const err =
            c.wasmtime_func_call(self.context, &self.log_state_fn, &input, 1, null, 0, &trap);

        if (err != null or trap != null) {
            return error.InternalError;
        }
    }

    pub fn allocWasm(self: *WasmChamber, size: usize, alignment: usize) !i32 {
        var trap: ?*c.wasm_trap_t = null;

        var inputs: [2]c.wasmtime_val_t = undefined;
        inputs[0].kind = c.WASMTIME_I32;
        inputs[0].of.i32 = std.math.cast(i32, size) orelse {
            return error.InvalidSize;
        };

        inputs[1].kind = c.WASMTIME_I32;
        inputs[1].of.i32 = std.math.cast(i32, alignment) orelse {
            return error.InvalidAlignment;
        };

        var result: c.wasmtime_val_t = undefined;

        const err =
            c.wasmtime_func_call(self.context, &self.alloc_fn, &inputs, inputs.len, &result, 1, &trap);

        if (err != null or trap != null) {
            return error.InternalError;
        }

        if (result.kind != c.WASMTIME_I32) {
            return error.InvalidResponse;
        }

        return result.of.i32;
    }

    pub fn freeWasm(self: *WasmChamber, ptr: i32) !void {
        var trap: ?*c.wasm_trap_t = null;

        var input: c.wasmtime_val_t = undefined;
        input.kind = c.WASMTIME_I32;
        input.of.i32 = ptr;

        const err =
            c.wasmtime_func_call(self.context, &self.free_fn, &input, 1, null, 0, &trap);

        if (err != null or trap != null) {
            return error.InternalError;
        }
    }

    pub fn saveSize(self: *WasmChamber) !i32 {
        var trap: ?*c.wasm_trap_t = null;

        var result: c.wasmtime_val_t = undefined;

        const err =
            c.wasmtime_func_call(self.context, &self.save_size_fn, null, 0, &result, 1, &trap);

        if (err != null or trap != null) {
            return error.InternalError;
        }

        if (result.kind != c.WASMTIME_I32) {
            return error.InvalidResult;
        }

        return result.of.i32;
    }

    pub fn save(self: *WasmChamber, alloc: Allocator, state: i32) ![]const u8 {
        var trap: ?*c.wasm_trap_t = null;

        const save_size: usize = std.math.cast(usize, try self.saveSize()) orelse {
            return error.InternalError;
        };
        const save_data = try self.allocWasm(save_size, 1);
        defer self.freeWasm(save_data) catch {
            std.log.err("Failed to free save data", .{});
        };

        var inputs: [2]c.wasmtime_val_t = undefined;
        inputs[0].kind = c.WASMTIME_I32;
        inputs[0].of.i32 = state;

        inputs[1].kind = c.WASMTIME_I32;
        inputs[1].of.i32 = save_data;

        const err =
            c.wasmtime_func_call(self.context, &self.save_fn, &inputs, inputs.len, null, 0, &trap);

        if (err != null or trap != null) {
            return error.InternalError;
        }

        const p = c.wasmtime_memory_data(self.context, self.memory);
        const offs = std.math.cast(usize, save_data) orelse {
            return error.InvalidOffset;
        };
        const save_data_slice: [*]u8 = @ptrCast(@alignCast(p + offs));

        return alloc.dupe(u8, save_data_slice[0..save_size]);
    }

    pub fn step(self: *WasmChamber, state: i32, balls: []Ball, delta: f32) !void {
        var trap: ?*c.wasm_trap_t = null;

        const balls_ptr = try self.allocWasm(balls.len * @sizeOf(Ball), @alignOf(Ball));
        defer self.freeWasm(balls_ptr) catch {
            std.log.err("Failed to free balls ptr", .{});
        };

        const p = c.wasmtime_memory_data(self.context, self.memory);
        const offs: usize = @intCast(balls_ptr);
        const wasm_balls: [*]Ball = @ptrCast(@alignCast(p + offs));
        @memcpy(wasm_balls[0..balls.len], balls);

        var inputs: [4]c.wasmtime_val_t = undefined;
        inputs[0].kind = c.WASMTIME_I32;
        inputs[0].of.i32 = state;

        inputs[1].kind = c.WASMTIME_I32;
        inputs[1].of.i32 = balls_ptr;

        inputs[2].kind = c.WASMTIME_I32;
        inputs[2].of.i32 = @intCast(balls.len);

        inputs[3].kind = c.WASMTIME_F32;
        inputs[3].of.f32 = delta;

        const err =
            c.wasmtime_func_call(self.context, &self.step_fn, &inputs, 4, null, 0, &trap);

        if (err != null or trap != null) {
            return error.InternalError;
        }

        @memcpy(balls, wasm_balls[0..balls.len]);
    }
};

fn logWasm(env: ?*anyopaque, caller: ?*c.wasmtime_caller_t, args: ?[*]const c.wasmtime_val_t, nargs: usize, results: ?[*]c.wasmtime_val_t, nresults: usize) callconv(.C) ?*c.wasm_trap_t {
    _ = nargs;
    _ = results;
    _ = nresults;

    const memory: *c.wasmtime_memory_t = @ptrCast(@alignCast(env));
    const context = c.wasmtime_caller_context(caller);
    const p = c.wasmtime_memory_data(context, memory);
    const offs: usize = @intCast(args.?[0].of.i32);
    const len: usize = @intCast(args.?[1].of.i32);

    std.debug.print("{s}\n", .{p[offs .. offs + len]});
    return null;
}

fn makeModuleFromData(data: []const u8, engine: ?*c.wasm_engine_t) !?*c.wasmtime_module_t {
    var module: ?*c.wasmtime_module_t = null;
    errdefer c.wasmtime_module_delete(module);

    const err = c.wasmtime_module_new(engine, data.ptr, data.len, &module);
    if (err != null) {
        return error.InitFailure;
    }

    return module;
}

fn makeInstance(context: *c.wasmtime_context_t, module: ?*c.wasmtime_module_t, memory: *c.wasmtime_memory_t) !c.wasmtime_instance_t {
    const callback_type = c.wasm_functype_new_2_0(c.wasm_valtype_new_i32(), c.wasm_valtype_new_i32());
    defer c.wasm_functype_delete(callback_type);
    var log_wasm_func: c.wasmtime_func_t = undefined;
    c.wasmtime_func_new(context, callback_type, &logWasm, memory, null, &log_wasm_func);

    var import: c.wasmtime_extern_t = undefined;

    import.kind = c.WASMTIME_EXTERN_FUNC;
    import.of = .{ .func = log_wasm_func };

    var instance: c.wasmtime_instance_t = undefined;
    var trap: ?*c.wasm_trap_t = null;

    const err = c.wasmtime_instance_new(context, module, &import, 1, &instance, &trap);
    if (err != null or trap != null) {
        return error.InitFailure;
    }
    return instance;
}

fn loadWasmMemory(context: *c.wasmtime_context_t, instance: *c.wasmtime_instance_t) !c.wasmtime_memory_t {
    const key = "memory";
    var item: c.wasmtime_extern_t = undefined;
    const ok = c.wasmtime_instance_export_get(context, instance, key.ptr, key.len, &item);

    if (!ok or item.kind != c.WASMTIME_EXTERN_MEMORY) {
        return error.InitFailure;
    }

    return item.of.memory;
}

fn loadWasmFn(key: []const u8, context: *c.wasmtime_context_t, instance: *c.wasmtime_instance_t) !c.wasmtime_func_t {
    var item: c.wasmtime_extern_t = undefined;
    const ok = c.wasmtime_instance_export_get(context, instance, key.ptr, key.len, &item);

    if (!ok or item.kind != c.WASMTIME_EXTERN_FUNC) {
        return error.InitFailure;
    }

    return item.of.func;
}
