const std = @import("std");

var gpa = std.heap.GeneralPurposeAllocator(.{}){};
const alloc = gpa.allocator();

fn walkFiles(output_writer: anytype, deps_writer: anytype, input_dir: std.fs.Dir, output_dir: std.fs.Dir, rel_path: []const u8) !void {
    var it: std.fs.Dir.Iterator = input_dir.iterate();

    while (try it.next()) |elem| {
        const new_rel_path = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ rel_path, elem.name });
        defer alloc.free(new_rel_path);

        switch (elem.kind) {
            .directory => {
                const new_input_dir = try input_dir.openDir(elem.name, .{
                    .iterate = true,
                });
                try output_dir.makeDir(elem.name);
                const new_output_dir = try output_dir.openDir(elem.name, .{});
                try walkFiles(output_writer, deps_writer, new_input_dir, new_output_dir, new_rel_path);
            },
            .file => {
                const input_abs_path = try input_dir.realpathAlloc(alloc, elem.name);
                defer alloc.free(input_abs_path);

                const output_dir_path = try output_dir.realpathAlloc(alloc, ".");
                defer alloc.free(output_dir_path);

                const output_abs_path = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ output_dir_path, elem.name });
                defer alloc.free(output_abs_path);

                try std.fs.symLinkAbsolute(input_abs_path, output_abs_path, .{});

                try deps_writer.print(" {s}", .{input_abs_path});
                try output_writer.print(
                    \\	.{{
                    \\	    .path = "{s}",
                    \\	    .data = @embedFile("{s}"),
                    \\	}},
                    \\
                , .{ new_rel_path[2..], new_rel_path });
            },
            else => {
                continue;
            },
        }
    }
}

pub fn parentPath(p: []const u8) ![]const u8 {
    var i = p.len;
    while (i > 0) {
        i -= 1;
        if (p[i] == '/') {
            return p[0..i];
        }
    }

    return error.NoParent;
}

pub fn main() !void {
    defer _ = gpa.deinit();

    var buf: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const args = try std.process.argsAlloc(fba.allocator());
    if (args.len < 2) {
        return error.MissingInputPath;
    }

    if (args.len < 3) {
        return error.MissingOutputPath;
    }

    if (args.len < 4) {
        return error.MissingDepsPath;
    }

    const output_dir = try std.fs.cwd().openDir(try parentPath(args[2]), .{ .iterate = true });
    var output_file = try std.fs.cwd().createFile(args[2], .{});
    defer output_file.close();
    var output_writer = output_file.writer();

    var deps_file = try std.fs.cwd().createFile(args[3], .{});
    defer deps_file.close();
    const deps_writer = deps_file.writer();
    try deps_writer.print("{s}:", .{args[2]});

    try output_writer.print(
        \\pub const Resource = struct {{
        \\    path: []const u8,
        \\    data: []const u8,
        \\}};
        \\
        \\pub const resources = [_]Resource {{
        \\
    , .{});

    const real_path = try std.fs.realpathAlloc(alloc, args[1]);
    defer alloc.free(real_path);

    const input_dir = try std.fs.cwd().openDir(args[1], .{
        .iterate = true,
    });
    try walkFiles(output_writer, deps_writer, input_dir, output_dir, ".");

    try output_writer.print(
        \\}}
        \\;
    , .{});
}
