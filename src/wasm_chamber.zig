const std = @import("std");
const physics = @import("physics.zig");
const Chamber = @import("Chamber.zig");
const Ball = physics.Ball;
const Allocator = std.mem.Allocator;

const c = @cImport({
    @cInclude("wasm.h");
    @cInclude("wasmtime.h");
});

pub const WasmLoader = struct {
    engine: *c.wasm_engine_t,

    pub fn init() !WasmLoader {
        const engine = c.wasm_engine_new() orelse {
            return error.InitFailure;
        };

        return .{
            .engine = engine,
        };
    }

    pub fn deinit(self: *WasmLoader) void {
        c.wasm_engine_delete(self.engine);
    }

    pub fn load(self: *WasmLoader, alloc: Allocator, data: []const u8) !WasmChamber {
        const store = c.wasmtime_store_new(self.engine, null, null) orelse {
            return error.InitFailure;
        };
        const context = c.wasmtime_store_context(store) orelse {
            return error.InitFailure;
        };
        const module = try makeModuleFromData(data, self.engine);
        defer c.wasmtime_module_delete(module);
        const memory: *c.wasmtime_memory_t = try alloc.create(c.wasmtime_memory_t);
        errdefer alloc.destroy(memory);

        var instance = try makeInstance(context, module, memory);
        memory.* = try loadWasmMemory(context, &instance);
        const init_fn = try loadWasmFn("init", context, &instance);
        const save_memory_fn = try loadWasmFn("saveMemory", context, &instance);
        const balls_memory_fn = try loadWasmFn("ballsMemory", context, &instance);
        const canvas_memory_fn = try loadWasmFn("canvasMemory", context, &instance);
        _ = canvas_memory_fn;
        const step_fn = try loadWasmFn("step", context, &instance);
        const save_fn = try loadWasmFn("save", context, &instance);
        const save_size_fn = try loadWasmFn("saveSize", context, &instance);
        const load_fn = try loadWasmFn("load", context, &instance);

        return .{
            .alloc = alloc,
            .store = store,
            .context = context,
            .instance = instance,
            .memory = memory,
            .init_fn = init_fn,
            .save_memory_fn = save_memory_fn,
            .balls_memory_fn = balls_memory_fn,
            .step_fn = step_fn,
            .save_fn = save_fn,
            .save_size_fn = save_size_fn,
            .load_fn = load_fn,
        };
    }
};

pub const WasmChamber = struct {
    alloc: Allocator,
    store: *c.wasmtime_store_t,
    context: *c.wasmtime_context_t,
    instance: c.wasmtime_instance_t,
    memory: *c.wasmtime_memory_t,
    init_fn: c.wasmtime_func_t,
    step_fn: c.wasmtime_func_t,
    save_fn: c.wasmtime_func_t,
    save_memory_fn: c.wasmtime_func_t,
    save_size_fn: c.wasmtime_func_t,
    balls_memory_fn: c.wasmtime_func_t,
    load_fn: c.wasmtime_func_t,

    pub fn deinit(self: *WasmChamber) void {
        self.alloc.destroy(self.memory);
        c.wasmtime_store_delete(self.store);
    }

    pub fn chamber(self: *WasmChamber) Chamber {
        const global = struct {
            var vtable = Chamber.Vtable{
                .initChamber = initChamber,
                .load = load,
                .save = save,
                .step = step,
            };
        };

        return .{
            .data = self,
            .vtable = &global.vtable,
        };
    }

    fn initChamber(ctx: ?*anyopaque, max_balls: usize) !void {
        const self: *WasmChamber = @ptrCast(@alignCast(ctx));

        try wasmCall(void, self.context, &self.init_fn, .{ max_balls, 0 });
    }

    fn load(ctx: ?*anyopaque, data: []const u8) !void {
        const self: *WasmChamber = @ptrCast(@alignCast(ctx));

        const wasm_ptr = try self.saveMemory();
        const wasm_offs = std.math.cast(usize, wasm_ptr) orelse {
            return error.InvalidOffset;
        };

        const wasm_data = try getWasmSlice(self.context, self.memory, wasm_offs, data.len);
        @memcpy(wasm_data, data);

        try wasmCall(void, self.context, &self.load_fn, .{});
    }

    pub fn saveSize(self: *WasmChamber) !i32 {
        return wasmCall(i32, self.context, &self.save_size_fn, .{});
    }

    fn saveMemory(self: *WasmChamber) !i32 {
        return wasmCall(i32, self.context, &self.save_memory_fn, .{});
    }

    fn save(ctx: ?*anyopaque, alloc: Allocator) ![]const u8 {
        const self: *WasmChamber = @ptrCast(@alignCast(ctx));
        var trap: ?*c.wasm_trap_t = null;

        const err =
            c.wasmtime_func_call(self.context, &self.save_fn, null, 0, null, 0, &trap);

        if (err != null or trap != null) {
            return error.InternalError;
        }

        const save_data = try self.saveMemory();
        const offs = std.math.cast(usize, save_data) orelse {
            return error.InvalidOffset;
        };
        const save_size: usize = std.math.cast(usize, try self.saveSize()) orelse {
            return error.InternalError;
        };
        const save_data_slice = try getWasmSlice(self.context, self.memory, offs, save_size);

        return alloc.dupe(u8, save_data_slice);
    }

    fn ballsMemory(self: *WasmChamber) !i32 {
        return wasmCall(i32, self.context, &self.balls_memory_fn, .{});
    }

    fn step(ctx: ?*anyopaque, balls: []Ball, delta: f32) !void {
        const self: *WasmChamber = @ptrCast(@alignCast(ctx));

        const balls_ptr = try self.ballsMemory();

        const offs: usize = @intCast(balls_ptr);
        const wasm_balls_data = try getWasmSlice(self.context, self.memory, offs, balls.len * @sizeOf(Ball));
        const wasm_balls: []Ball = @alignCast(std.mem.bytesAsSlice(Ball, wasm_balls_data));
        @memcpy(wasm_balls[0..balls.len], balls);

        try wasmCall(void, self.context, &self.step_fn, .{ balls.len, delta });

        @memcpy(balls, wasm_balls[0..balls.len]);
    }
};

fn wasmCall(comptime Ret: type, context: *c.wasmtime_context_t, f: *c.wasmtime_func_t, args: anytype) !Ret {
    const fields = std.meta.fields(@TypeOf(args));

    var inputs: [fields.len]c.wasmtime_val_t = undefined;
    inline for (fields, 0..) |field, i| {
        switch (@typeInfo(field.type)) {
            .Int, .ComptimeInt => {
                inputs[i].kind = c.WASMTIME_I32;
                inputs[i].of.i32 = std.math.cast(i32, @field(args, field.name)) orelse {
                    return error.InvalidCast;
                };
            },
            .Float, .ComptimeFloat => {
                inputs[i].kind = c.WASMTIME_F32;
                inputs[i].of.f32 = @field(args, field.name);
            },
            else => {
                @compileError("Arg of type " ++ @typeName(field.type) ++ " is not handled");
            },
        }
    }

    var result: c.wasmtime_val_t = undefined;
    var result_len: usize = 0;
    switch (@typeInfo(Ret)) {
        .Void => {},
        else => {
            result_len = 1;
        },
    }

    var trap: ?*c.wasm_trap_t = null;
    const err = c.wasmtime_func_call(context, f, &inputs, inputs.len, &result, result_len, &trap);
    if (trap != null) {
        var message: c.wasm_byte_vec_t = undefined;
        defer c.wasm_byte_vec_delete(&message);

        c.wasm_trap_message(trap, &message);
        std.log.err("wasm trap: {s}", .{message.data[0..message.size]});
        return error.InternalError;
    }

    if (err != null) {
        return error.InternalError;
    }

    switch (@typeInfo(Ret)) {
        .Void => {
            return;
        },
        .Int => {
            if (result.kind != c.WASMTIME_I32) {
                return error.InvalidResult;
            }

            return result.of.i32;
        },
        else => {
            @compileError("Return of type " ++ @typeName(Ret) ++ " is not handled");
        },
    }
}

fn logWasm(env: ?*anyopaque, caller: ?*c.wasmtime_caller_t, args: ?[*]const c.wasmtime_val_t, nargs: usize, results: ?[*]c.wasmtime_val_t, nresults: usize) callconv(.C) ?*c.wasm_trap_t {
    _ = nargs;
    _ = results;
    _ = nresults;

    const memory: *c.wasmtime_memory_t = @ptrCast(@alignCast(env));
    const context = c.wasmtime_caller_context(caller);
    const offs: usize = @intCast(args.?[0].of.i32);
    const len: usize = @intCast(args.?[1].of.i32);
    const data = getWasmSlice(context.?, memory, offs, len) catch {
        std.debug.print("Failed to load wasm data to log\n", .{});
        return null;
    };

    std.debug.print("{s}\n", .{data});
    return null;
}

fn getWasmSlice(context: *c.wasmtime_context_t, memory: *c.wasmtime_memory_t, offs: usize, len: usize) ![]u8 {
    const p = c.wasmtime_memory_data(context, memory);
    const max = c.wasmtime_memory_data_size(context, memory);

    if (offs >= max or offs + len >= max) {
        return error.InvalidMemory;
    }

    return p[offs .. offs + len];
}

fn makeModuleFromData(data: []const u8, engine: ?*c.wasm_engine_t) !?*c.wasmtime_module_t {
    var module: ?*c.wasmtime_module_t = null;
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

    var instance: c.wasmtime_instance_t = undefined;
    var trap: ?*c.wasm_trap_t = null;

    var required_imports: c.wasm_importtype_vec_t = undefined;
    c.wasmtime_module_imports(module, &required_imports);
    defer c.wasm_importtype_vec_delete(&required_imports);

    var err: ?*c.wasmtime_error_t = null;

    if (required_imports.size == 1) {
        var import: c.wasmtime_extern_t = undefined;
        import.kind = c.WASMTIME_EXTERN_FUNC;
        import.of = .{ .func = log_wasm_func };

        err = c.wasmtime_instance_new(context, module, &import, 1, &instance, &trap);
    } else {
        err = c.wasmtime_instance_new(context, module, null, 0, &instance, &trap);
    }

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
