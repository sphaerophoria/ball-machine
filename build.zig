const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const opt = b.standardOptimizeOption(.{});

    const generate_embedded_resources = b.addExecutable(.{
        .name = "generate_embedded_resources",
        .root_source_file = .{ .path = "tools/generate_embedded_resources.zig" },
        .target = b.host,
    });

    const generate_embedded_resources_step = b.addRunArtifact(generate_embedded_resources);
    generate_embedded_resources_step.addDirectoryArg(b.path("src/res"));
    const output = generate_embedded_resources_step.addOutputFileArg("resources.zig");

    _ = generate_embedded_resources_step.addDepFileOutputArg("deps.d");
    const exe = b.addExecutable(.{
        .name = "ball-machine",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = opt,
    });
    exe.root_module.addAnonymousImport("resources", .{ .root_source_file = output });

    b.installArtifact(exe);
}
