const std = @import("std");
const physics = @import("physics.zig");
const Chamber = @import("Chamber.zig");
const Ball = physics.Ball;
const Allocator = std.mem.Allocator;

const c = @cImport({
    @cInclude("wasm.h");
    @cInclude("wasmtime.h");
});

pub const Diagnostics = struct {
    alloc: Allocator,
    msg: []const u8 = &.{},

    pub fn deinit(self: *Diagnostics) void {
        self.alloc.free(self.msg);
    }

    fn setErr(self: *Diagnostics, comptime fmt: []const u8, args: anytype) void {
        self.alloc.free(self.msg);
        self.msg = std.fmt.allocPrint(self.alloc, fmt, args) catch {
            std.log.err("Failed to set failure message", .{});
            return;
        };
    }

    fn setWasmErr(self: *Diagnostics, msg: c.wasm_byte_vec_t) void {
        self.alloc.free(self.msg);
        self.msg = self.alloc.dupe(u8, msg.data[0..msg.size]) catch {
            std.log.err("Failed to dupe failure message", .{});
            return;
        };
    }
};

const WasmError = error{
    EngineInit,
    InitWithLimits,
    LoadStore,
    LoadContext,
    MakeModule,
    ChamberError,
    AddFuel,
    InvalidArg,
    NoExportedMemory,
} || Allocator.Error;

pub const WasmLoader = struct {
    engine: *c.wasm_engine_t,
    init_fuel_limit: u64 = 0,
    step_fuel_limit: u64 = 0,
    render_fuel_limit: u64 = 0,
    memory_limit: i64 = -1,

    pub fn init() WasmError!WasmLoader {
        const engine = c.wasm_engine_new() orelse {
            return WasmError.EngineInit;
        };

        return .{
            .engine = engine,
        };
    }

    pub fn initWithLimits(init_fuel_limit: u64, step_fuel_limit: u64, render_fuel_limit: u64, memory_limit: i64) WasmError!WasmLoader {
        const config = c.wasm_config_new();
        c.wasmtime_config_consume_fuel_set(config, true);
        const engine = c.wasm_engine_new_with_config(config) orelse {
            return WasmError.InitWithLimits;
        };

        return .{
            .engine = engine,
            .init_fuel_limit = init_fuel_limit,
            .step_fuel_limit = step_fuel_limit,
            .render_fuel_limit = render_fuel_limit,
            .memory_limit = memory_limit,
        };
    }

    pub fn deinit(self: *WasmLoader) void {
        c.wasm_engine_delete(self.engine);
    }

    pub fn load(self: *WasmLoader, alloc: Allocator, data: []const u8, diagnostics: ?*Diagnostics) WasmError!WasmChamber {
        const store = c.wasmtime_store_new(self.engine, null, null) orelse {
            return WasmError.LoadStore;
        };
        errdefer c.wasmtime_store_delete(store);

        const context = c.wasmtime_store_context(store) orelse {
            return WasmError.LoadContext;
        };

        c.wasmtime_store_limiter(store, self.memory_limit, -1, -1, -1, -1);

        const module = try makeModuleFromData(data, self.engine, diagnostics);
        defer c.wasmtime_module_delete(module);
        const memory: *c.wasmtime_memory_t = try alloc.create(c.wasmtime_memory_t);
        errdefer alloc.destroy(memory);

        var instance = try makeInstance(context, module, memory, diagnostics);
        memory.* = try loadWasmMemory(context, &instance);
        const init_fn = try loadWasmFn("init", context, &instance, diagnostics);
        const save_memory_fn = try loadWasmFn("saveMemory", context, &instance, diagnostics);
        const balls_memory_fn = try loadWasmFn("ballsMemory", context, &instance, diagnostics);
        const canvas_memory_fn = try loadWasmFn("canvasMemory", context, &instance, diagnostics);
        _ = canvas_memory_fn;
        const step_fn = try loadWasmFn("step", context, &instance, diagnostics);
        const save_fn = try loadWasmFn("save", context, &instance, diagnostics);
        const save_size_fn = try loadWasmFn("saveSize", context, &instance, diagnostics);
        const load_fn = try loadWasmFn("load", context, &instance, diagnostics);
        const render_fn = try loadWasmFn("render", context, &instance, diagnostics);

        return .{
            .alloc = alloc,
            .diagnostics = diagnostics,
            .store = store,
            .context = context,
            .instance = instance,
            .memory = memory,
            .init_fn = init_fn,
            .save_memory_fn = save_memory_fn,
            .balls_memory_fn = balls_memory_fn,
            .step_fn = step_fn,
            .render_fn = render_fn,
            .save_fn = save_fn,
            .save_size_fn = save_size_fn,
            .load_fn = load_fn,
            .init_fuel_limit = self.init_fuel_limit,
            .step_fuel_limit = self.step_fuel_limit,
            .render_fuel_limit = self.render_fuel_limit,
        };
    }
};
pub const WasmChamber = struct {
    alloc: Allocator,
    diagnostics: ?*Diagnostics,
    store: *c.wasmtime_store_t,
    context: *c.wasmtime_context_t,
    instance: c.wasmtime_instance_t,
    memory: *c.wasmtime_memory_t,
    init_fn: c.wasmtime_func_t,
    step_fn: c.wasmtime_func_t,
    render_fn: c.wasmtime_func_t,
    save_fn: c.wasmtime_func_t,
    save_memory_fn: c.wasmtime_func_t,
    save_size_fn: c.wasmtime_func_t,
    balls_memory_fn: c.wasmtime_func_t,
    load_fn: c.wasmtime_func_t,
    init_fuel_limit: u64 = 0,
    step_fuel_limit: u64 = 0,
    render_fuel_limit: u64 = 0,

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

    fn initChamber(ctx: ?*anyopaque, max_balls: usize, max_canvas_pixels: usize) WasmError!void {
        const self: *WasmChamber = @ptrCast(@alignCast(ctx));

        try self.addFuel(self.init_fuel_limit);
        try wasmCall(void, self.context, &self.init_fn, self.diagnostics, .{ max_balls, max_canvas_pixels });
    }

    fn load(ctx: ?*anyopaque, data: []const u8) WasmError!void {
        const self: *WasmChamber = @ptrCast(@alignCast(ctx));

        try self.addFuel(self.step_fuel_limit);

        const wasm_ptr = try self.saveMemory();
        const wasm_offs = std.math.cast(usize, wasm_ptr) orelse {
            if (self.diagnostics) |d| {
                d.setErr("save memory {d} is not a valid usize", .{wasm_ptr});
            }
            return WasmError.ChamberError;
        };

        const wasm_data = try getWasmSlice(self.context, self.memory, wasm_offs, data.len, self.diagnostics);
        @memcpy(wasm_data, data);

        try wasmCall(void, self.context, &self.load_fn, self.diagnostics, .{});
    }

    pub fn saveSize(self: *WasmChamber) WasmError!i32 {
        return wasmCall(i32, self.context, &self.save_size_fn, self.diagnostics, .{});
    }

    fn saveMemory(self: *WasmChamber) WasmError!i32 {
        return wasmCall(i32, self.context, &self.save_memory_fn, self.diagnostics, .{});
    }

    fn save(ctx: ?*anyopaque, alloc: Allocator) WasmError![]const u8 {
        const self: *WasmChamber = @ptrCast(@alignCast(ctx));
        try self.addFuel(self.step_fuel_limit);

        try wasmCall(void, self.context, &self.save_fn, self.diagnostics, .{});

        const save_data = try self.saveMemory();
        const offs = std.math.cast(usize, save_data) orelse {
            if (self.diagnostics) |d| {
                d.setErr("Save data ptr {d} is not a valid usize", .{save_data});
            }
            return WasmError.ChamberError;
        };
        const save_sizei = try self.saveSize();
        const save_size: usize = std.math.cast(usize, save_sizei) orelse {
            if (self.diagnostics) |d| {
                d.setErr("Save size {d} is not a valid usize", .{save_sizei});
            }
            return WasmError.ChamberError;
        };
        const save_data_slice = try getWasmSlice(self.context, self.memory, offs, save_size, self.diagnostics);

        return alloc.dupe(u8, save_data_slice);
    }

    fn ballsMemory(self: *WasmChamber) WasmError!i32 {
        return wasmCall(i32, self.context, &self.balls_memory_fn, self.diagnostics, .{});
    }

    fn step(ctx: ?*anyopaque, balls: []Ball, delta: f32) WasmError!void {
        const self: *WasmChamber = @ptrCast(@alignCast(ctx));

        try self.addFuel(self.step_fuel_limit);

        const balls_ptr = try self.ballsMemory();

        const offs: usize = @intCast(balls_ptr);
        const wasm_balls_data = try getWasmSlice(self.context, self.memory, offs, balls.len * @sizeOf(Ball), self.diagnostics);
        const wasm_balls: []Ball = @alignCast(std.mem.bytesAsSlice(Ball, wasm_balls_data));
        @memcpy(wasm_balls[0..balls.len], balls);

        try wasmCall(void, self.context, &self.step_fn, self.diagnostics, .{ balls.len, delta });

        @memcpy(balls, wasm_balls[0..balls.len]);
    }

    pub fn render(self: *WasmChamber, width: usize, height: usize) WasmError!void {
        try self.addFuel(self.render_fuel_limit);
        try wasmCall(void, self.context, &self.render_fn, self.diagnostics, .{ width, height });
    }

    fn addFuel(self: *WasmChamber, limit: u64) WasmError!void {
        if (limit == 0) {
            return;
        }

        if (c.wasmtime_context_set_fuel(self.context, limit) != null) {
            return WasmError.AddFuel;
        }
    }
};

fn wasmCall(comptime Ret: type, context: *c.wasmtime_context_t, f: *c.wasmtime_func_t, diagnostics: ?*Diagnostics, args: anytype) WasmError!Ret {
    const fields = std.meta.fields(@TypeOf(args));

    var inputs: [fields.len]c.wasmtime_val_t = undefined;
    inline for (fields, 0..) |field, i| {
        switch (@typeInfo(field.type)) {
            .Int, .ComptimeInt => {
                inputs[i].kind = c.WASMTIME_I32;
                inputs[i].of.i32 = std.math.cast(i32, @field(args, field.name)) orelse {
                    if (diagnostics) |d| {
                        d.setErr("Wasm argument {d} is not a valid i32", .{@field(args, field.name)});
                    }
                    return WasmError.InvalidArg;
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
    defer {
        if (trap != null) {
            c.wasm_trap_delete(trap.?);
        }
    }

    const err = c.wasmtime_func_call(context, f, &inputs, inputs.len, &result, result_len, &trap);
    defer {
        if (err != null) {
            c.wasmtime_error_delete(err.?);
        }
    }

    try handleTrapErr(err, trap, diagnostics);

    switch (@typeInfo(Ret)) {
        .Void => {
            return;
        },
        .Int => {
            if (result.kind != c.WASMTIME_I32) {
                if (diagnostics) |d| {
                    d.setErr("Function did not return an i32", .{});
                }
                return WasmError.ChamberError;
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
    const data = getWasmSlice(context.?, memory, offs, len, null) catch {
        std.debug.print("Failed to load wasm data to log\n", .{});
        return null;
    };

    std.debug.print("{s}\n", .{data});
    return null;
}

fn getWasmSlice(context: *c.wasmtime_context_t, memory: *c.wasmtime_memory_t, offs: usize, len: usize, diagnostics: ?*Diagnostics) WasmError![]u8 {
    const p = c.wasmtime_memory_data(context, memory);
    const max = c.wasmtime_memory_data_size(context, memory);

    if (offs >= max or offs + len >= max) {
        if (diagnostics) |d| {
            d.setErr("Memory offs {d} is not within valid memory bounds", .{offs});
        }
        return WasmError.ChamberError;
    }

    return p[offs .. offs + len];
}

fn makeModuleFromData(data: []const u8, engine: ?*c.wasm_engine_t, diagnostics: ?*Diagnostics) WasmError!?*c.wasmtime_module_t {
    var module: ?*c.wasmtime_module_t = null;
    const err = c.wasmtime_module_new(engine, data.ptr, data.len, &module);
    if (err != null) {
        if (diagnostics) |d| {
            var message: c.wasm_name_t = undefined;
            c.wasmtime_error_message(err, &message);
            defer c.wasm_name_delete(&message);

            d.setWasmErr(message);
        }
        c.wasmtime_error_delete(err);
        return WasmError.MakeModule;
    }

    return module;
}

fn makeInstance(context: *c.wasmtime_context_t, module: ?*c.wasmtime_module_t, memory: *c.wasmtime_memory_t, diagnostics: ?*Diagnostics) WasmError!c.wasmtime_instance_t {
    const callback_type = c.wasm_functype_new_2_0(c.wasm_valtype_new_i32(), c.wasm_valtype_new_i32());
    defer c.wasm_functype_delete(callback_type);
    var log_wasm_func: c.wasmtime_func_t = undefined;
    c.wasmtime_func_new(context, callback_type, &logWasm, memory, null, &log_wasm_func);

    var instance: c.wasmtime_instance_t = undefined;
    var trap: ?*c.wasm_trap_t = null;
    defer {
        if (trap != null) {
            c.wasm_trap_delete(trap.?);
        }
    }

    var required_imports: c.wasm_importtype_vec_t = undefined;
    c.wasmtime_module_imports(module, &required_imports);
    defer c.wasm_importtype_vec_delete(&required_imports);

    var err: ?*c.wasmtime_error_t = null;
    defer {
        if (err != null) {
            c.wasmtime_error_delete(err.?);
        }
    }

    if (required_imports.size == 1) {
        var import: c.wasmtime_extern_t = undefined;
        import.kind = c.WASMTIME_EXTERN_FUNC;
        import.of = .{ .func = log_wasm_func };

        err = c.wasmtime_instance_new(context, module, &import, 1, &instance, &trap);
    } else {
        err = c.wasmtime_instance_new(context, module, null, 0, &instance, &trap);
    }

    try handleTrapErr(err, trap, diagnostics);

    return instance;
}

fn handleTrapErr(err: ?*c.wasmtime_error_t, trap: ?*c.wasm_trap_t, diagnostics: ?*Diagnostics) WasmError!void {
    if (diagnostics == null) {
        if (trap != null) {
            return WasmError.ChamberError;
        }

        if (err != null) {
            return WasmError.ChamberError;
        }

        return;
    }

    if (trap != null) {
        var message: c.wasm_byte_vec_t = undefined;
        defer c.wasm_byte_vec_delete(&message);
        c.wasm_trap_message(trap, &message);

        diagnostics.?.setWasmErr(message);
        return WasmError.ChamberError;
    }

    if (err != null) {
        var message: c.wasm_name_t = undefined;
        c.wasmtime_error_message(err, &message);
        defer c.wasm_name_delete(&message);

        diagnostics.?.setWasmErr(message);

        return WasmError.ChamberError;
    }
}

fn loadWasmMemory(context: *c.wasmtime_context_t, instance: *c.wasmtime_instance_t) WasmError!c.wasmtime_memory_t {
    const key = "memory";
    var item: c.wasmtime_extern_t = undefined;
    const ok = c.wasmtime_instance_export_get(context, instance, key.ptr, key.len, &item);

    if (!ok or item.kind != c.WASMTIME_EXTERN_MEMORY) {
        return WasmError.NoExportedMemory;
    }

    return item.of.memory;
}

fn loadWasmFn(key: []const u8, context: *c.wasmtime_context_t, instance: *c.wasmtime_instance_t, diagnostics: ?*Diagnostics) WasmError!c.wasmtime_func_t {
    var item: c.wasmtime_extern_t = undefined;
    const ok = c.wasmtime_instance_export_get(context, instance, key.ptr, key.len, &item);

    if (!ok or item.kind != c.WASMTIME_EXTERN_FUNC) {
        if (diagnostics) |d| {
            d.setErr("Failed to load fn {s}", .{key});
        }
        return WasmError.ChamberError;
    }

    return item.of.func;
}
