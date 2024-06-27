const std = @import("std");
const c = @import("c.zig");
const Allocator = std.mem.Allocator;

const Db = @This();

db: *c.sqlite3,

pub fn init(db_folder: []const u8) !Db {
    try std.fs.cwd().makePath(db_folder);

    var full_path_buf: [200]u8 = undefined;
    const full_path = try std.fmt.bufPrintZ(&full_path_buf, "{s}/db.db", .{db_folder});

    var db_opt: ?*c.sqlite3 = undefined;
    if (c.sqlite3_open(full_path, &db_opt) != c.SQLITE_OK) {
        closeDb(db_opt);
        return error.Sql;
    }

    const db = db_opt orelse unreachable;
    try createTables(db);

    return .{
        .db = db,
    };
}

fn initMemory() !Db {
    var db_opt: ?*c.sqlite3 = undefined;

    if (c.sqlite3_open(":memory:", &db_opt) != c.SQLITE_OK) {
        closeDb(db_opt);
        return error.Sql;
    }

    const db = db_opt orelse unreachable;
    try createTables(db);

    return .{
        .db = db,
    };
}

pub fn deinit(self: *Db) void {
    closeDb(self.db);
}

pub fn addUser(self: *Db, twitch_id: []const u8, username: []const u8, issue_time: i64, expire_time: i64) !i64 {
    const sql = "INSERT INTO users(twitch_id, username, issue_time, expire_time) " ++
        "VALUES (?1, ?2, ?3, ?4) " ++
        "ON CONFLICT(twitch_id) DO " ++
        "UPDATE SET username=?2, issue_time=?3, expire_time=?4 RETURNING users.id;";

    const statement = try makeStatement(self.db, sql, "add user");
    defer finalizeStatement(statement);

    try checkSqliteRet("bind twitch id", c.sqlite3_bind_text(
        statement,
        1,
        twitch_id.ptr,
        try toSqlLen(twitch_id.len),
        c.SQLITE_STATIC,
    ));

    try checkSqliteRet("bind username", c.sqlite3_bind_text(
        statement,
        2,
        username.ptr,
        try toSqlLen(username.len),
        c.SQLITE_STATIC,
    ));

    try checkSqliteRet("bind issue time", c.sqlite3_bind_int64(statement, 3, issue_time));
    try checkSqliteRet("bind expire time", c.sqlite3_bind_int64(statement, 4, expire_time));

    const sqlite_ret = c.sqlite3_step(statement);
    if (sqlite_ret != c.SQLITE_ROW) {
        std.log.err("Failed to run add user", .{});
        return error.Sql;
    }
    return c.sqlite3_column_int64(statement, 0);
}

pub fn addSessionId(self: *Db, user: i64, session_id: []const u8) !void {
    const sql = "INSERT INTO session_ids(id, user_id) VALUES (?1, ?2)";

    const statement = try makeStatement(self.db, sql, "add session id");
    defer finalizeStatement(statement);

    try checkSqliteRet("bind session id", c.sqlite3_bind_blob(
        statement,
        1,
        session_id.ptr,
        try toSqlLen(session_id.len),
        c.SQLITE_STATIC,
    ));

    try checkSqliteRet("bind user id", c.sqlite3_bind_int64(statement, 2, user));

    const ret = c.sqlite3_step(statement);
    if (ret != c.SQLITE_DONE) {
        std.log.err("Failed to run add session id", .{});
        return error.Sql;
    }
}

pub fn addChamber(self: *Db, user_id: i64, chamber_name: []const u8, chamber_data: []const u8) !i64 {
    const sql = "INSERT INTO chambers(user_id, name, data) VALUES(?1, ?2, ?3) RETURNING chambers.id;";

    const statement = try makeStatement(self.db, sql, "add chamber");
    defer finalizeStatement(statement);

    try checkSqliteRet("bind user id", c.sqlite3_bind_int64(
        statement,
        1,
        user_id,
    ));

    try checkSqliteRet("chamber_name", c.sqlite3_bind_text(
        statement,
        2,
        chamber_name.ptr,
        try toSqlLen(chamber_name.len),
        c.SQLITE_STATIC,
    ));

    try checkSqliteRet("chamber_data", c.sqlite3_bind_blob(
        statement,
        3,
        chamber_data.ptr,
        try toSqlLen(chamber_data.len),
        c.SQLITE_STATIC,
    ));

    var ret = c.sqlite3_step(statement);

    if (ret != c.SQLITE_ROW) {
        std.log.err("Failed to run get chamber id", .{});
        return error.Sql;
    }

    const id = c.sqlite3_column_int64(statement, 0);
    ret = c.sqlite3_step(statement);
    if (ret != c.SQLITE_DONE) {
        std.log.err("Failed to run add session id", .{});
        return error.Sql;
    }

    return id;
}

pub fn deleteChamber(self: *Db, chamber_id: i64) !void {
    const sql = "DELETE FROM chambers WHERE chambers.id = ?1;";

    const statement = try makeStatement(self.db, sql, "delete chamber");
    defer finalizeStatement(statement);

    try checkSqliteRet("chamber id", c.sqlite3_bind_int64(
        statement,
        1,
        chamber_id,
    ));

    const ret = c.sqlite3_step(statement);

    if (ret != c.SQLITE_DONE) {
        std.log.err("Failed to run delete chamber", .{});
        return error.Sql;
    }
}

pub const Chamber = struct {
    id: i64,
    user_id: i64,
    name: []const u8,
    data: []const u8,

    pub fn deinit(self: *Chamber, alloc: Allocator) void {
        alloc.free(self.name);
        alloc.free(self.data);
    }
};

pub const ChamberList = struct {
    items: []Chamber,

    pub fn deinit(self: *ChamberList, alloc: Allocator) void {
        for (self.items) |*item| {
            item.deinit(alloc);
        }
        alloc.free(self.items);
    }
};

const ChamberSqliteColumns = struct {
    id: c_int,
    user_id: c_int,
    name: c_int,
    data: c_int,
};

fn chamberFromColumns(alloc: Allocator, statement: *c.sqlite3_stmt, cols: ChamberSqliteColumns) !Chamber {
    const id = c.sqlite3_column_int64(statement, cols.id);
    const user_id = c.sqlite3_column_int64(statement, cols.user_id);

    const name = try extractColumnText(alloc, statement, cols.name) orelse {
        std.log.err("Chamber has no name", .{});
        return error.Sql;
    };
    errdefer alloc.free(name);

    const data = try extractColumnBlob(alloc, statement, cols.data) orelse {
        std.log.err("Chamber has no data", .{});
        return error.Sql;
    };
    errdefer alloc.free(data);

    return .{
        .id = id,
        .user_id = user_id,
        .name = name,
        .data = data,
    };
}

pub fn getChamber(self: *Db, alloc: Allocator, id: i64) !Chamber {
    const sql = "SELECT id, user_id, name, data FROM chambers WHERE id = ?1;";

    const statement = try makeStatement(self.db, sql, "get chamber");
    defer finalizeStatement(statement);

    try checkSqliteRet("bind chamber id", c.sqlite3_bind_int64(statement, 1, id));

    const sqlite_ret = c.sqlite3_step(statement);

    if (sqlite_ret != c.SQLITE_ROW) {
        std.log.err("Failed to run getChambers", .{});
        return error.Sql;
    }

    return chamberFromColumns(alloc, statement, .{
        .id = 0,
        .user_id = 1,
        .name = 2,
        .data = 3,
    });
}

pub fn getChambers(self: *Db, alloc: Allocator) !ChamberList {
    const sql = "SELECT id, user_id, name, data FROM chambers;";

    const statement = try makeStatement(self.db, sql, "get chambers");
    defer finalizeStatement(statement);

    var chambers = std.ArrayList(Chamber).init(alloc);
    errdefer {
        for (chambers.items) |*item| {
            item.deinit(alloc);
        }
        chambers.deinit();
    }

    while (true) {
        const sqlite_ret = c.sqlite3_step(statement);
        if (sqlite_ret == c.SQLITE_DONE) {
            break;
        }

        if (sqlite_ret != c.SQLITE_ROW) {
            std.log.err("Failed to run getChambers", .{});
            return error.Sql;
        }

        const chamber = try chamberFromColumns(alloc, statement, .{
            .id = 0,
            .user_id = 1,
            .name = 2,
            .data = 3,
        });

        try chambers.append(chamber);
    }

    const items = try chambers.toOwnedSlice();
    return .{
        .items = items,
    };
}

pub const UserInfo = struct {
    id: i64,
    twitch_id: []const u8,
    username: []const u8,
    issue_time: i64,
    expire_time: i64,

    pub fn deinit(self: *UserInfo, alloc: Allocator) void {
        alloc.free(self.twitch_id);
        alloc.free(self.username);
    }
};

pub fn userFromSessionId(self: *Db, alloc: Allocator, session_id: []const u8) !?UserInfo {
    const sql = "SELECT users.id, users.twitch_id, users.username, users.issue_time, users.expire_time " ++
        "FROM session_ids " ++
        "LEFT JOIN users ON session_ids.user_id == users.id WHERE session_ids.id == ?1;";

    const statement = try makeStatement(self.db, sql, "get user");
    defer finalizeStatement(statement);

    try checkSqliteRet("bind session id", c.sqlite3_bind_blob(
        statement,
        1,
        session_id.ptr,
        try toSqlLen(session_id.len),
        c.SQLITE_STATIC,
    ));

    const ret = c.sqlite3_step(statement);
    if (ret == c.SQLITE_DONE) {
        return null;
    }

    if (ret != c.SQLITE_ROW) {
        std.log.err("Failed to get user id from session id: {d}", .{ret});
        return error.Sql;
    }

    const user_id = c.sqlite3_column_int64(statement, 0);

    const twitch_id = try extractColumnText(alloc, statement, 1) orelse {
        std.log.err("No twitch id", .{});
        return error.Sql;
    };
    errdefer alloc.free(twitch_id);

    const username = try extractColumnText(alloc, statement, 2) orelse {
        std.log.err("No username", .{});
        return error.Sql;
    };
    errdefer alloc.free(username);

    const issue_time = c.sqlite3_column_int64(statement, 3);
    const expire_time = c.sqlite3_column_int64(statement, 4);

    return .{
        .id = user_id,
        .twitch_id = twitch_id,
        .username = username,
        .issue_time = issue_time,
        .expire_time = expire_time,
    };
}

fn toSqlLen(len: usize) !c_int {
    return std.math.cast(c_int, len) orelse {
        return error.Sql;
    };
}

fn fromSqlLen(len: c_int) !usize {
    return std.math.cast(usize, len) orelse {
        return error.Sql;
    };
}

fn closeDb(db: ?*c.sqlite3) void {
    if (c.sqlite3_close(db) != c.SQLITE_OK) {
        std.log.err("Failed to close db\n", .{});
    }
}

fn makeStatement(db: *c.sqlite3, sql: [:0]const u8, purpose: []const u8) !*c.sqlite3_stmt {
    var statement: ?*c.sqlite3_stmt = null;

    const ret = c.sqlite3_prepare_v2(db, sql, try toSqlLen(sql.len + 1), &statement, null);

    if (ret != c.SQLITE_OK) {
        std.log.err("Failed to prepare {s} statement", .{purpose});
        return error.Sql;
    }
    return statement orelse unreachable;
}

fn finalizeStatement(statement: *c.sqlite3_stmt) void {
    _ = c.sqlite3_finalize(statement);
}

fn checkSqliteRet(purpose: []const u8, ret: i32) !void {
    if (ret != c.SQLITE_OK) {
        std.log.err("Failed to {s}", .{purpose});
        return error.Sql;
    }
}

fn dupeSqliteData(alloc: Allocator, item_opt: ?[*]const u8, item_len: i32) !?[]const u8 {
    const item = item_opt orelse {
        return null;
    };
    const item_clone = try alloc.dupe(u8, item[0..try fromSqlLen(item_len)]);
    return item_clone;
}

fn extractColumnText(alloc: Allocator, statement: *c.sqlite3_stmt, column_id: c_int) !?[]const u8 {
    const item_opt: ?[*]const u8 = @ptrCast(c.sqlite3_column_text(statement, column_id));
    const item_len = c.sqlite3_column_bytes(statement, column_id);
    return dupeSqliteData(alloc, item_opt, item_len);
}

fn extractColumnBlob(alloc: Allocator, statement: *c.sqlite3_stmt, column_id: c_int) !?[]const u8 {
    const item_opt: ?[*]const u8 = @ptrCast(c.sqlite3_column_blob(statement, column_id));
    const item_len = c.sqlite3_column_bytes(statement, column_id);
    return dupeSqliteData(alloc, item_opt, item_len);
}

fn createTables(db: *c.sqlite3) !void {
    var err_c: [*c]u8 = undefined;

    var ret = c.sqlite3_exec(db,
        \\CREATE TABLE IF NOT EXISTS users (
        \\    id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
        \\    twitch_id TEXT UNIQUE NOT NULL,
        \\    username TEXT NOT NULL,
        \\    issue_time INTEGER NOT NULL,
        \\    expire_time INTEGER NOT NULL
        \\) STRICT;
    , null, null, &err_c);

    if (ret != c.SQLITE_OK) {
        const err: [*:0]u8 = @ptrCast(err_c);
        std.log.err("Failed to create users table: {s}", .{err});
        return error.Sql;
    }

    ret = c.sqlite3_exec(db,
        \\CREATE TABLE IF NOT EXISTS session_ids (
        \\    id BLOB PRIMARY KEY NOT NULL,
        \\    user_id INTEGER,
        \\    FOREIGN KEY(user_id) REFERENCES users(id)
        \\) STRICT;
    , null, null, &err_c);

    if (ret != c.SQLITE_OK) {
        const err: [*:0]u8 = @ptrCast(err_c);
        std.log.err("Failed to create session_id tables: {s}", .{err});
        return error.Sql;
    }

    ret = c.sqlite3_exec(db,
        \\CREATE TABLE IF NOT EXISTS chambers (
        \\    id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
        \\    user_id INTEGER NOT NULL,
        \\    name TEXT NOT NULL,
        \\    data BLOB NOT NULL,
        \\    FOREIGN KEY(user_id) REFERENCES users(id)
        \\) STRICT;
    , null, null, &err_c);

    if (ret != c.SQLITE_OK) {
        const err: [*:0]u8 = @ptrCast(err_c);
        std.log.err("Failed to create chambers table: {s}", .{err});
        return error.Sql;
    }
}

fn indexOfChamber(id: i64, chambers: []const Chamber) ?usize {
    for (chambers, 0..) |chamber, i| {
        if (id == chamber.id) {
            return i;
        }
    }

    return null;
}

test "sanity test" {
    var db = try initMemory();
    defer db.deinit();

    const user_id = try db.addUser("twitch", "me", 10, 20);
    try db.addSessionId(user_id, "session");
    try db.addSessionId(user_id, "session2");

    const user_id2 = try db.addUser("other_twitch", "not me", 20, 30);
    try db.addSessionId(user_id2, "user2_session");
    try db.addSessionId(user_id2, "user2_session2");

    const user1_ids: []const []const u8 = &.{ "session", "session2" };
    for (user1_ids) |id| {
        var user = try db.userFromSessionId(std.testing.allocator, id) orelse {
            return error.NoSession;
        };
        defer user.deinit(std.testing.allocator);

        try std.testing.expectEqual(user_id, user.id);
        try std.testing.expectEqualStrings("me", user.username);
        try std.testing.expectEqualStrings("twitch", user.twitch_id);
        try std.testing.expectEqual(10, user.issue_time);
        try std.testing.expectEqual(20, user.expire_time);
    }

    const user2_ids: []const []const u8 = &.{ "user2_session", "user2_session2" };
    for (user2_ids) |id| {
        var user = try db.userFromSessionId(std.testing.allocator, id) orelse {
            return error.NoSession;
        };
        defer user.deinit(std.testing.allocator);

        try std.testing.expectEqual(user_id2, user.id);
        try std.testing.expectEqualStrings("not me", user.username);
        try std.testing.expectEqualStrings("other_twitch", user.twitch_id);
        try std.testing.expectEqual(20, user.issue_time);
        try std.testing.expectEqual(30, user.expire_time);
    }

    try std.testing.expect(try db.userFromSessionId(std.testing.allocator, "notpresent") == null);

    const chamber_id = try db.addChamber(user_id, "name", "data");
    const chamber_id2 = try db.addChamber(user_id2, "name2", "data2");

    var chambers = try db.getChambers(std.testing.allocator);
    defer chambers.deinit(std.testing.allocator);
    try std.testing.expectEqual(chambers.items.len, 2);

    const chamber_idx = indexOfChamber(chamber_id, chambers.items) orelse {
        return error.NoChamber;
    };

    const chamber = chambers.items[chamber_idx];
    try std.testing.expectEqual(user_id, chamber.user_id);
    try std.testing.expectEqualStrings("name", chamber.name);
    try std.testing.expectEqualStrings("data", chamber.data);

    const chamber_idx2 = indexOfChamber(chamber_id2, chambers.items) orelse {
        return error.NoChamber;
    };

    const chamber2 = chambers.items[chamber_idx2];
    try std.testing.expectEqual(user_id2, chamber2.user_id);
    try std.testing.expectEqualStrings("name2", chamber2.name);
    try std.testing.expectEqualStrings("data2", chamber2.data);

    try db.deleteChamber(chamber_id2);

    var chambers_again = try db.getChambers(std.testing.allocator);
    defer chambers_again.deinit(std.testing.allocator);
    try std.testing.expectEqual(chambers_again.items.len, 1);
    try std.testing.expectEqual(chambers_again.items[0].id, chamber_id);
}

test "duplicate session id" {
    var db = try initMemory();
    defer db.deinit();

    const user_id = try db.addUser("twitch", "me", 10, 20);
    try db.addSessionId(user_id, "session");
    try std.testing.expectError(error.Sql, db.addSessionId(user_id, "session"));
}

test "user update" {
    var db = try initMemory();
    defer db.deinit();

    const user_id = try db.addUser("twitch", "me", 10, 20);
    const user_id2 = try db.addUser("twitch", "me2", 11, 21);

    try std.testing.expectEqual(user_id, user_id2);
    // NOTE: no way to get user directly from ID cause we don't need it externally
    try db.addSessionId(user_id, "asdf");

    var user_info = try db.userFromSessionId(std.testing.allocator, "asdf") orelse {
        return error.NoUser;
    };
    defer user_info.deinit(std.testing.allocator);

    try std.testing.expectEqual(11, user_info.issue_time);
    try std.testing.expectEqual(21, user_info.expire_time);
    try std.testing.expectEqualStrings("me2", user_info.username);
}
