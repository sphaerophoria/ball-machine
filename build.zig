const std = @import("std");
const Build = std.Build;
const Step = Build.Step;

const BuildOptions = struct {
    embed_www: bool,
    target: Build.ResolvedTarget,
    opt: std.builtin.OptimizeMode,
    wasm_target: Build.ResolvedTarget,

    fn init(b: *Build) BuildOptions {
        return .{
            .embed_www = b.option(bool, "embed-www", "Embed src/res in exe") orelse true,
            .target = b.standardTargetOptions(.{}),
            .opt = b.standardOptimizeOption(.{}),
            .wasm_target = b.resolveTargetQuery(std.zig.CrossTarget.parse(
                .{ .arch_os_abi = "wasm32-freestanding" },
            ) catch unreachable),
        };
    }
};

const BuildSteps = struct {
    test_step: *Step,
    chambers: *Step,
    check: *Step,
    install: *Step,
    libphysics: *Step,

    fn init(b: *Build) BuildSteps {
        return .{
            .test_step = b.step("test", "Run unit tests"),
            .chambers = b.step("chambers", "Chambers only"),
            .check = b.step("check", "Quick check"),
            .install = b.getInstallStep(),
            .libphysics = b.step("libphysics", "Build physics lib"),
        };
    }
};

const Tools = struct {
    generate_embedded_resources: *Step.Run,
    resources_zig_source: Build.LazyPath,
    fake_resources: Build.LazyPath,

    fn init(b: *Build) Tools {
        const generate_embedded_resources = b.addExecutable(.{
            .name = "generate_embedded_resources",
            .root_source_file = b.path("tools/generate_embedded_resources.zig"),
            .target = b.host,
        });

        const generate_embedded_resources_step = b.addRunArtifact(generate_embedded_resources);
        const output = generate_embedded_resources_step.addOutputFileArg("resources.zig");
        _ = generate_embedded_resources_step.addDepFileOutputArg("deps.d");

        const fake_generate_embedded_resources_step = b.addRunArtifact(generate_embedded_resources);
        const fake_output = fake_generate_embedded_resources_step.addOutputFileArg("resources.zig");
        _ = fake_generate_embedded_resources_step.addDepFileOutputArg("deps.d");

        return .{
            .generate_embedded_resources = generate_embedded_resources_step,
            .resources_zig_source = output,
            .fake_resources = fake_output,
        };
    }

    fn embedFile(self: *Tools, path: Build.LazyPath) void {
        self.generate_embedded_resources.addFileArg(path);
    }

    fn embedDir(self: *Tools, path: Build.LazyPath) void {
        self.generate_embedded_resources.addDirectoryArg(path);
    }
};

const Modules = struct {
    physics: *Build.Module,
    resources: *Build.Module,
    fake_resources: *Build.Module,
    dude_animation: *Build.Module,

    fn init(b: *Build, tools: Tools) Modules {
        const physics = Build.Module.create(b, .{ .root_source_file = b.path("src/physics.zig") });

        const dude_animation = Build.Module.create(b, .{ .root_source_file = generateDudeAnimation(b) });
        dude_animation.addImport("physics", physics);

        return .{
            .physics = physics,
            .resources = Build.Module.create(b, .{ .root_source_file = tools.resources_zig_source }),
            .fake_resources = Build.Module.create(b, .{ .root_source_file = tools.fake_resources }),
            .dude_animation = dude_animation,
        };
    }

    fn linkPhysics(self: *Modules, item: *Step.Compile) void {
        item.root_module.addImport("physics", self.physics);
    }
};

const WasmLibs = struct {
    physics: *Step.Compile,
    physics_install: *Step.InstallArtifact,
    physics_include: Build.LazyPath,

    fn init(b: *Build, modules: *Modules, options: BuildOptions) WasmLibs {
        const physics_include = b.path("src/libphysics");
        const libphysics = Builder.wasmLib(b, options, "physics", "src/libphysics/physics_c_bindings.zig");
        libphysics.addIncludePath(physics_include);
        modules.linkPhysics(libphysics);

        const physics_install = b.addInstallArtifact(libphysics, .{});

        return .{
            .physics = libphysics,
            .physics_include = physics_include,
            .physics_install = physics_install,
        };
    }

    fn linkPhysics(self: *WasmLibs, item: *Step.Compile) void {
        item.linkLibrary(self.physics);
        item.addIncludePath(self.physics_include);
    }
};

const Libs = struct {
    wasmtime: Build.LazyPath,
    wasmtime_include: Build.LazyPath,
    link_mode: std.builtin.LinkMode,

    fn init(b: *Build, options: BuildOptions) Libs {
        const link_mode: std.builtin.LinkMode = switch (options.opt) {
            // dynamic is faster, but harder to ship
            .Debug => .dynamic,
            else => .static,
        };
        return .{
            .wasmtime = runCargo(b, options, "deps/wasmtime/", "libwasmtime.a", null, &.{ "--no-default-features", "-p", "wasmtime-c-api" }),
            .wasmtime_include = b.path("deps/wasmtime/crates/c-api/include"),
            .link_mode = link_mode,
        };
    }

    fn link(self: *Libs, exe: *Step.Compile, name: []const u8) void {
        exe.root_module.linkSystemLibrary(name, .{
            .preferred_link_mode = self.link_mode,
        });
    }
    fn linkAll(self: *Libs, exe: *Step.Compile) void {
        exe.addLibraryPath(self.wasmtime.dirname());
        exe.addIncludePath(self.wasmtime_include);
        exe.linkLibC();
        exe.linkLibCpp();
        self.link(exe, "wasmtime");
        self.link(exe, "ssl");
        self.link(exe, "crypto");
        self.link(exe, "curl");
        self.link(exe, "sqlite3");
    }
};

const Builder = struct {
    b: *Build,
    steps: BuildSteps,
    options: BuildOptions,
    modules: Modules,
    tools: Tools,
    wasm_libs: WasmLibs,
    libs: Libs,

    fn init(b: *Build) Builder {
        const options = BuildOptions.init(b);
        const tools = Tools.init(b);
        var modules = Modules.init(b, tools);

        const wasm_libs = WasmLibs.init(b, &modules, options);
        const libs = Libs.init(b, options);

        return .{
            .b = b,
            .steps = BuildSteps.init(b),
            .options = options,
            .modules = modules,
            .tools = tools,
            .wasm_libs = wasm_libs,
            .libs = libs,
        };
    }

    fn wasmLib(b: *Build, options: BuildOptions, name: []const u8, path: []const u8) *Step.Compile {
        return b.addStaticLibrary(.{
            .name = name,
            .root_source_file = b.path(path),
            .target = options.wasm_target,
            .optimize = options.opt,
        });
    }

    fn setWasmExeParams(exe: *Step.Compile) void {
        exe.entry = .disabled;
        exe.rdynamic = true;
        // Limit stack size to keep overall required memory usage lower
        exe.stack_size = 16384;
    }

    fn wasmExe(self: *Builder, name: []const u8, path: []const u8) *Step.Compile {
        const ret = self.b.addExecutable(.{
            .name = name,
            .root_source_file = self.b.path(path),
            .target = self.options.wasm_target,
            .optimize = self.options.opt,
        });
        setWasmExeParams(ret);
        return ret;
    }

    fn wasmExeC(self: *Builder, name: []const u8, path: []const u8) *Step.Compile {
        var ret = self.b.addExecutable(.{
            .name = name,
            .root_source_file = null,
            .target = self.options.wasm_target,
            .optimize = self.options.opt,
        });

        setWasmExeParams(ret);

        ret.addCSourceFile(.{
            .file = self.b.path(path),
        });
        return ret;
    }

    fn addExe(self: *Builder, name: []const u8, path: []const u8) *Step.Compile {
        return self.b.addExecutable(.{
            .name = name,
            .root_source_file = self.b.path(path),
            .target = self.options.target,
            .optimize = self.options.opt,
        });
    }

    fn addTest(self: *Builder, path: []const u8) *Step.Compile {
        return self.b.addTest(.{
            .root_source_file = self.b.path(path),
            .target = self.options.target,
            .test_runner = self.b.path("test/test_runner.zig"),
        });
    }

    fn addZigChamber(self: *Builder, name: []const u8, path: []const u8) *Step.Compile {
        const chamber = self.wasmExe(name, path);
        self.modules.linkPhysics(chamber);
        const install_chamber = self.b.addInstallArtifact(chamber, .{});
        self.steps.chambers.dependOn(&install_chamber.step);
        self.steps.install.dependOn(&install_chamber.step);
        self.steps.check.dependOn(&chamber.step);
        return chamber;
    }

    fn addCChamber(self: *Builder, name: []const u8, path: []const u8) void {
        const chamber = self.wasmExeC(name, path);
        self.wasm_libs.linkPhysics(chamber);
        chamber.root_module.export_symbol_names = &.{ "init", "saveMemory", "ballsMemory", "canvasMemory", "save", "load", "step", "render", "saveSize" };
        const install_chamber = self.b.addInstallArtifact(chamber, .{});
        self.steps.chambers.dependOn(&install_chamber.step);
        self.steps.install.dependOn(&install_chamber.step);
        self.steps.check.dependOn(&chamber.step);
    }

    fn addRustChamber(self: *Builder, comptime name: []const u8, path: []const u8) void {
        const output_bin_name = name ++ ".wasm";
        const output = runCargo(self.b, self.options, path, output_bin_name, "wasm32-unknown-unknown", &.{});
        output.generated.file.step.dependOn(&self.wasm_libs.physics_install.step);
        const install_chamber = self.b.addInstallBinFile(output, output_bin_name);
        self.steps.chambers.dependOn(&install_chamber.step);
        self.steps.install.dependOn(&install_chamber.step);
    }
};

fn runCargo(b: *Build, options: BuildOptions, crate_root: []const u8, output_file: []const u8, target: ?[]const u8, extra_args: []const []const u8) Build.LazyPath {
    const tool_run = b.addSystemCommand(&.{"cargo"});
    const crate_root_lazy = b.path(crate_root);
    tool_run.setCwd(crate_root_lazy);
    tool_run.addArg("build");
    if (target) |t| {
        tool_run.addArgs(&.{ "--target", t });
    }
    tool_run.addArgs(extra_args);

    var opt_path: []const u8 = undefined;
    switch (options.opt) {
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

    const generated = b.allocator.create(std.Build.GeneratedFile) catch unreachable;
    var path = b.build_root.join(b.allocator, &.{ crate_root, "target", opt_path, output_file }) catch unreachable;
    if (target) |t| {
        path = b.build_root.join(b.allocator, &.{ crate_root, "target", t, opt_path, output_file }) catch unreachable;
    }

    generated.* = .{
        .step = &tool_run.step,
        .path = path,
    };

    const lib_path = std.Build.LazyPath{ .generated = .{
        .file = generated,
    } };

    return lib_path;
}

fn generateDudeAnimation(b: *Build) std.Build.LazyPath {
    const tool_run = b.addSystemCommand(&.{"blender"});
    tool_run.setCwd(b.path("src/chambers/dude"));
    tool_run.addArgs(&.{ "-b", "-P", "export_animation.py", "--" });
    tool_run.addFileInput(b.path("src/chambers/dude/dude.blend"));
    tool_run.addFileInput(b.path("src/chambers/dude/export_animation.py"));
    return tool_run.addOutputFileArg("animation.zig");
}

fn buildVacuumChamber(builder: *Builder) void {
    const tool_run = builder.b.addSystemCommand(&.{"convert"});
    tool_run.addArgs(&.{
        "-background",
        "none",
    });
    tool_run.addFileArg(builder.b.path("src/chambers/vacuum/vacuum.svg"));
    tool_run.addArgs(&.{
        "-set",
        "colorspace",
        "Gray",
        "-resize",
        "30x-1",
        "-depth",
        "8",
    });
    const image_data = tool_run.addOutputFileArg("image.rgba");

    const vacuum = builder.addZigChamber("vacuum", "src/chambers/vacuum.zig");
    vacuum.addIncludePath(builder.b.path("src/chambers/vacuum"));
    vacuum.root_module.addAnonymousImport("image_data", .{
        .root_source_file = image_data,
    });
}

pub fn build(b: *std.Build) !void {
    var builder = Builder.init(b);

    _ = builder.addZigChamber("simple", "src/chambers/simple.zig");
    _ = builder.addZigChamber("platforms", "src/chambers/platforms.zig");
    _ = builder.addZigChamber("spinny_bar", "src/chambers/spinny_bar.zig");
    _ = builder.addZigChamber("pong", "src/chambers/pong.zig");
    _ = builder.addZigChamber("shadow", "src/chambers/shadow.zig");
    buildVacuumChamber(&builder);
    _ = builder.addZigChamber("angled_platforms", "src/chambers/angled_platforms.zig");
    builder.addCChamber("plinko", "src/chambers/plinko.c");
    builder.addRustChamber("counter", "src/chambers/counter");

    const dude_chamber = builder.addZigChamber("dude", "src/chambers/dude.zig");
    dude_chamber.root_module.addImport("animation", builder.modules.dude_animation);

    const client_side_sim = builder.wasmExe("simulation", "src/simulation_wasm.zig");
    builder.tools.embedFile(client_side_sim.getEmittedBin());
    if (builder.options.embed_www) {
        builder.tools.embedDir(b.path("src/res"));
    }
    builder.tools.embedFile(builder.wasm_libs.physics.getEmittedBin());
    builder.tools.embedFile(b.path("src/libphysics/physics.h"));
    builder.tools.embedFile(b.path("src/physics.zig"));

    const exe = builder.addExe("ball-machine", "src/main.zig");
    exe.root_module.addImport("resources", builder.modules.resources);
    builder.b.installArtifact(exe);
    builder.libs.linkAll(exe);

    const tester = builder.addExe("test_chamber", "src/test_chamber.zig");
    builder.libs.linkAll(tester);
    builder.b.installArtifact(tester);

    builder.steps.libphysics.dependOn(&builder.wasm_libs.physics_install.step);

    // NOTE: We have to make the executable again for the check step. If the
    // exe is depended on by an install step, even if not executed, this will
    // result in femit-bin which is quite slow. A second binary that isn't
    // installed allows that step to be skipped.
    const check_exe = builder.addExe("ball-chamber", "src/main.zig");
    check_exe.root_module.addImport("resources", builder.modules.fake_resources);
    builder.libs.linkAll(check_exe);
    builder.steps.check.dependOn(&check_exe.step);

    const tests = builder.addTest("src/main.zig");
    builder.libs.linkAll(tests);
    tests.root_module.addImport("resources", builder.modules.fake_resources);
    builder.steps.test_step.dependOn(&b.addRunArtifact(tests).step);

    const generate_test_db = builder.addExe("generate_test_db", "test/generate_test_db.zig");
    builder.libs.linkAll(generate_test_db);
    generate_test_db.root_module.addAnonymousImport("Db", .{ .root_source_file = b.path("src/Db.zig") });
    b.installArtifact(generate_test_db);
}
