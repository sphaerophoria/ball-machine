const std = @import("std");
const Db = @import("Db");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const alloc = gpa.allocator();

    var arg_it = std.process.args();
    const process_name = arg_it.next().?;
    const process_dir = std.fs.path.dirname(process_name).?;
    const db_path = arg_it.next().?;

    var db = try Db.init(db_path);
    defer db.deinit();
    const user_id = try db.addUser("twitch", "testing", 0, 1230943);
    const session_id: [32]u8 = [1]u8{'1'} ** 32;
    try db.addSessionId(user_id, &session_id);

    const admin_id = try db.addUser("twitch_admin", "testing admin", 0, 1230943);
    const admin_session_id: [32]u8 = [1]u8{'2'} ** 32;
    try db.addSessionId(admin_id, &admin_session_id);

    const encoder = std.base64.url_safe.Encoder;
    const buf_len = encoder.calcSize(32);
    var buf: [4096]u8 = undefined;
    _ = encoder.encode(buf[0..buf_len], &admin_session_id);
    std.debug.print("admin id: \"{s}\"", .{buf[0..buf_len]});

    const chambers: []const []const u8 = &.{
        "dude",
        "simple",
        "platforms",
        "spinny_bar",
        "counter",
        "plinko",
    };

    var path_buf: [4096]u8 = undefined;
    for (chambers) |chamber| {
        const wasm_path = try std.fmt.bufPrint(&path_buf, "{s}/{s}.wasm", .{ process_dir, chamber });
        const f = try std.fs.cwd().openFile(wasm_path, .{});
        const wasm_data = try f.readToEndAlloc(alloc, 10_000_000);
        defer alloc.free(wasm_data);

        const chamber_id = try db.addChamber(user_id, chamber, wasm_data);
        try db.acceptChamber(chamber_id);
    }
}
