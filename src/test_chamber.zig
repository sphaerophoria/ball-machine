const std = @import("std");
const ChamberTester = @import("ChamberTester.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const alloc = gpa.allocator();

    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);

    const chamber_f = try std.fs.cwd().openFile(args[1], .{});
    defer chamber_f.close();

    const chamber_data = try chamber_f.readToEndAlloc(alloc, 100_000_000);
    defer alloc.free(chamber_data);

    var tester = try ChamberTester.init();
    defer tester.deinit();

    try tester.ensureValidChamber(alloc, chamber_data);
}
