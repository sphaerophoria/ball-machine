const std = @import("std");
const Db = @import("Db");

pub fn main() !void {
    var arg_it = std.process.args();
    _ = arg_it.next();
    const db_path = arg_it.next().?;

    var db = try  Db.init(db_path);
    defer db.deinit();
    const user_id = try db.addUser("twitch", "testing", 0, 1230943);
    const session_id: [32]u8 = [1]u8{'1'} ** 32;
    try db.addSessionId(user_id, &session_id);
}
