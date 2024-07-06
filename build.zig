const std = @import("std");

fn setupWasmtime(b: *std.Build, opt: std.builtin.OptimizeMode) !std.Build.LazyPath {
    const tool_run = b.addSystemCommand(&.{"cargo"});
    tool_run.setCwd(b.path("deps/wasmtime/crates/c-api/artifact/"));
    tool_run.addArgs(&.{ "build", "--no-default-features" });

    var opt_path: []const u8 = undefined;
    switch (opt) {
        .ReleaseSafe,
        .ReleaseFast,
        .ReleaseSmall,
        => {
            tool_run.addArg("--release");
            opt_path = "release";
        },
        .Debug => {
            opt_path = "debug";
        },
    }

    const generated = try b.allocator.create(std.Build.GeneratedFile);
    generated.* = .{
        .step = &tool_run.step,
        .path = try b.build_root.join(b.allocator, &.{ "deps/wasmtime/target", opt_path, "libwasmtime.a" }),
    };

    const lib_path = std.Build.LazyPath{ .generated = .{
        .file = generated,
    } };

    return lib_path;
}

pub fn buildChamber(b: *std.Build, chambers_step: *std.Build.Step, name: []const u8, opt: std.builtin.OptimizeMode) !void {
    const path = try std.fmt.allocPrint(b.allocator, "src/chambers/{s}.zig", .{name});
    const chamber = b.addExecutable(.{
        .name = name,
        .root_source_file = b.path(path),
        .target = b.resolveTargetQuery(std.zig.CrossTarget.parse(
            .{ .arch_os_abi = "wasm32-freestanding" },
        ) catch unreachable),
        .optimize = opt,
    });
    chamber.root_module.addAnonymousImport("physics", .{ .root_source_file = b.path("src/physics.zig") });
    chamber.entry = .disabled;
    chamber.rdynamic = true;
    b.installArtifact(chamber);
    chambers_step.dependOn(&b.addInstallArtifact(chamber, .{}).step);
}

pub fn buildClientSideSim(b: *std.Build, opt: std.builtin.OptimizeMode) !std.Build.LazyPath {
    const sim = b.addExecutable(.{
        .name = "simulation",
        .root_source_file = b.path("src/simulation_wasm.zig"),
        .target = b.resolveTargetQuery(std.zig.CrossTarget.parse(
            .{ .arch_os_abi = "wasm32-freestanding" },
        ) catch unreachable),
        .optimize = opt,
    });
    sim.entry = .disabled;
    sim.rdynamic = true;
    return sim.getEmittedBin();
}

fn buildCChamber(b: *std.Build, chambers_step: *std.Build.Step, libphysics: *std.Build.Step.Compile, opt: std.builtin.OptimizeMode) !void {
    //zig cc -target wasm32-freestanding -Oz -I../libphysics -o plinko.wasm plinko.c walloc.c -Wl,--no-entry -Wl,--export=alloc -Wl,--export=init -Wl,--export=deinit -Wl,--export=free -Wl,--export=save -Wl,--export=load -Wl,--export=step -Wl,--export=render -Wl,--export=saveSize -lphysics -L ../../zig-out/lib/

    const chamber = b.addExecutable(.{
        .name = "plinko",
        .root_source_file = null,
        .target = b.resolveTargetQuery(std.zig.CrossTarget.parse(
            .{ .arch_os_abi = "wasm32-freestanding" },
        ) catch unreachable),
        .optimize = opt,
    });

    const files = [_][]const u8{"plinko.c"};
    chamber.addCSourceFiles(.{
        .root = b.path("src/chambers"),
        .files = &files,
    });
    chamber.addIncludePath(b.path("src/libphysics"));
    chamber.linkLibrary(libphysics);
    chamber.entry = .disabled;
    chamber.root_module.export_symbol_names = &.{ "init", "deinit", "saveMemory", "ballsMemory", "canvasMemory", "save", "load", "step", "render", "saveSize" };
    chamber.import_symbols = true;
    b.installArtifact(chamber);
    chambers_step.dependOn(&b.addInstallArtifact(chamber, .{}).step);
}

fn buildRustChamber(b: *std.Build, libphysics: *std.Build.Step.InstallArtifact, opt: std.builtin.OptimizeMode) !void {
    const tool_run = b.addSystemCommand(&.{"cargo"});
    tool_run.setCwd(b.path("src/chambers/counter/"));
    tool_run.addArgs(&.{ "build", "--target=wasm32-unknown-unknown" });
    tool_run.step.dependOn(&libphysics.step);

    var opt_path: []const u8 = undefined;
    switch (opt) {
        .ReleaseSafe,
        .ReleaseFast,
        .ReleaseSmall,
        => {
            tool_run.addArg("--release");
            opt_path = "release";
        },
        .Debug => {
            opt_path = "debug";
        },
    }

    const generated = try b.allocator.create(std.Build.GeneratedFile);
    generated.* = .{
        .step = &tool_run.step,
        .path = try b.build_root.join(b.allocator, &.{ "src/chambers/counter/target/wasm32-unknown-unknown", opt_path, "counter.wasm" }),
    };

    const wasm_path = std.Build.LazyPath{ .generated = .{
        .file = generated,
    } };

    b.getInstallStep().dependOn(&b.addInstallBinFile(wasm_path, "counter.wasm").step);
}

fn addMainDependencies(b: *std.Build, exe: *std.Build.Step.Compile, wasmtime_lib: std.Build.LazyPath, output: std.Build.LazyPath, opt: std.builtin.OptimizeMode) void {
    exe.root_module.addAnonymousImport("resources", .{ .root_source_file = output });
    exe.addLibraryPath(wasmtime_lib.dirname());
    const link_mode: std.builtin.LinkMode = switch (opt) {
        // dynamic is faster, but harder to ship
        .Debug => .dynamic,
        else => .static,
    };
    exe.root_module.linkSystemLibrary("wasmtime", .{
        .preferred_link_mode = link_mode,
    });
    exe.addIncludePath(b.path("deps/wasmtime/crates/c-api/include"));
    exe.linkLibC();
    exe.linkLibCpp();
    exe.linkSystemLibrary("ssl");
    exe.linkSystemLibrary("crypto");
    exe.linkSystemLibrary("curl");
    exe.linkSystemLibrary("sqlite3");
}

pub fn build(b: *std.Build) !void {
    const test_step = b.step("test", "Run unit tests");
    const chambers = b.step("chambers", "Chambers only");

    const target = b.standardTargetOptions(.{});
    const opt = b.standardOptimizeOption(.{});

    const libphysics = b.addStaticLibrary(.{
        .name = "physics",
        .root_source_file = b.path("src/libphysics/physics_c_bindings.zig"),
        .target = b.resolveTargetQuery(std.zig.CrossTarget.parse(
            .{ .arch_os_abi = "wasm32-freestanding" },
        ) catch unreachable),
        .optimize = opt,
    });
    libphysics.root_module.addAnonymousImport("physics", .{ .root_source_file = b.path("src/physics.zig") });
    libphysics.addIncludePath(b.path("src/libphysics"));
    const libphysics_install = b.addInstallArtifact(libphysics, .{});
    b.getInstallStep().dependOn(&libphysics_install.step);
    b.installArtifact(libphysics);

    const generate_embedded_resources = b.addExecutable(.{
        .name = "generate_embedded_resources",
        .root_source_file = b.path("tools/generate_embedded_resources.zig"),
        .target = b.host,
    });

    try buildChamber(b, chambers, "simple", opt);
    try buildChamber(b, chambers, "platforms", opt);
    try buildChamber(b, chambers, "spinny_bar", opt);
    try buildCChamber(b, chambers, libphysics, opt);
    try buildRustChamber(b, libphysics_install, opt);
    const client_side_sim = try buildClientSideSim(b, opt);

    const generate_embedded_resources_step = b.addRunArtifact(generate_embedded_resources);
    const output = generate_embedded_resources_step.addOutputFileArg("resources.zig");
    _ = generate_embedded_resources_step.addDepFileOutputArg("deps.d");
    generate_embedded_resources_step.addDirectoryArg(b.path("src/res"));
    generate_embedded_resources_step.addFileArg(client_side_sim);

    const wasmtime_lib = try setupWasmtime(b, opt);

    const exe = b.addExecutable(.{
        .name = "ball-machine",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = opt,
    });
    addMainDependencies(b, exe, wasmtime_lib, output, opt);
    b.installArtifact(exe);

    const generate_test_db = b.addExecutable(.{
        .name = "generate_test_db",
        .root_source_file = b.path("test/generate_test_db.zig"),
        .target = target,
        .optimize = opt,
    });
    addMainDependencies(b, generate_test_db, wasmtime_lib, output, opt);
    generate_test_db.root_module.addAnonymousImport("Db", .{ .root_source_file = b.path("src/Db.zig") });
    b.installArtifact(generate_test_db);

    const unit_tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .test_runner = b.path("test/test_runner.zig"),
    });
    addMainDependencies(b, unit_tests, wasmtime_lib, output, opt);

    const run_unit_tests = b.addRunArtifact(unit_tests);
    test_step.dependOn(&run_unit_tests.step);
}
