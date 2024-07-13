const std = @import("std");
const http = @import("http.zig");
const resources = @import("resources");
const userinfo = @import("userinfo.zig");
const Authentication = userinfo.Authentication;
const EventLoop = @import("EventLoop.zig");
const HttpClient = @import("HttpClient.zig");
const Allocator = std.mem.Allocator;
const Simulation = @import("Simulation.zig");
const physics = @import("physics.zig");
const future = @import("future.zig");
const Ball = physics.Ball;
const ConnectionSpawner = @import("TcpServer.zig").ConnectionSpawner;
const ServerSimulation = @import("ServerSimulation.zig");
const Db = @import("Db.zig");

const Server = @This();

alloc: Allocator,
www_root: ?[]const u8,
server_sim: *ServerSimulation,
admin_id: []const u8,
client_id: []const u8,
auth_request_thread: *AuthRequestThread,
auth_request_handle: std.Thread,
event_loop: *EventLoop,
auth: Authentication,
db: *Db,

pub fn init(
    alloc: Allocator,
    www_root: ?[]const u8,
    server_sim: *ServerSimulation,
    admin_id: []const u8,
    client_id: []const u8,
    client_secret: []const u8,
    jwt_keys: []const userinfo.RsaParams,
    server_url: []const u8,
    event_loop: *EventLoop,
    db: *Db,
) !Server {
    const trimmed_id = std.mem.trim(u8, client_id, &std.ascii.whitespace);
    const trimmed_secret = std.mem.trim(u8, client_secret, &std.ascii.whitespace);

    const auth_request_thread = try AuthRequestThread.init(alloc, trimmed_id, trimmed_secret, server_url);
    errdefer auth_request_thread.deinit();

    const auth_request_handle = try std.Thread.spawn(
        .{},
        AuthRequestThread.run,
        .{auth_request_thread},
    );

    const auth = try Authentication.init(alloc, server_url, jwt_keys, db);

    return Server{
        .alloc = alloc,
        .www_root = www_root,
        .server_sim = server_sim,
        .admin_id = admin_id,
        .client_id = trimmed_id,
        .auth = auth,
        .auth_request_thread = auth_request_thread,
        .auth_request_handle = auth_request_handle,
        .event_loop = event_loop,
        .db = db,
    };
}

pub fn deinit(self: *Server) void {
    self.auth_request_thread.shutdown.store(true, .monotonic);
    self.auth_request_handle.join();
    self.auth_request_thread.deinit();
}

pub fn spawner(self: *Server) ConnectionSpawner {
    const spawn_fn = struct {
        fn f(data: ?*anyopaque, stream: std.net.Stream) anyerror!EventLoop.EventHandler {
            const self_: *Server = @ptrCast(@alignCast(data));
            return self_.spawn(stream);
        }
    }.f;

    return .{
        .data = self,
        .spawn_fn = spawn_fn,
    };
}

const Connection = struct {
    const State = enum {
        waiting_auth,
        http,
    };

    server: *Server,
    inner: http.HttpConnection,
    state: State = .http,
    ref_count: usize,

    fn init(server: *Server, stream: std.net.Stream) !*Connection {
        var inner = try http.HttpConnection.init(server.alloc, stream);
        errdefer inner.deinit();

        const ret = try server.alloc.create(Connection);
        errdefer server.alloc.free(ret);

        ret.* = .{
            .server = server,
            .inner = inner,
            .ref_count = 1,
        };

        return ret;
    }

    fn unref(self: *Connection) void {
        self.ref_count -= 1;
        if (self.ref_count != 0) {
            return;
        }

        self.inner.deinit();
        self.server.alloc.destroy(self);
    }

    fn ref(self: *Connection) void {
        self.ref_count += 1;
    }

    fn handler(self: *Connection) EventLoop.EventHandler {
        return .{
            .data = self,
            .callback = EventLoop.EventHandler.makeCallback(Connection, poll),
            .deinit = EventLoop.EventHandler.makeDeinit(Connection, Connection.unref),
        };
    }

    fn queueAuthRequest(self: *Connection, code: []const u8) !void {
        // promise cleanup handled through req.deinit() below
        const promise = try future.Promise([]const u8).init(self.server.alloc);
        var req = AuthRequestQueue.Request{
            .code = code,
            .promise = promise,
        };

        self.server.auth_request_thread.request_queue.push(req) catch |e| {
            req.deinit();
            return e;
        };

        // req at this point should not be cleaned up as it has been pushed
        // into the request queue. It will be cleaned up on the other end

        var fut = promise.future();
        const auth_waiter = AuthWaitingConnection.init(self, fut) catch |e| {
            fut.deinit();
            return e;
        };
        errdefer auth_waiter.deinit();
        try self.server.event_loop.register(fut.fd(), auth_waiter.handler());
    }

    fn setAuthResponse(self: *Connection, response: []const u8) !void {
        std.debug.assert(self.state == .waiting_auth);

        const session_cookie = try self.server.auth.validateAuthResponse(
            response,
            self.inner.reader.header_buf,
        );

        var set_cookie_buf: [500]u8 = undefined;
        const set_cookie_val = std.fmt.bufPrint(
            &set_cookie_buf,
            "{s}={s}; HttpOnly",
            .{ Authentication.session_cookie_key, session_cookie },
        ) catch {
            @panic("cookie buf length too low");
        };

        const header = http.Header{
            .content_type = .@"text/html",
            .status = std.http.Status.see_other,
            .content_length = 0,
            .extra = &.{ .{
                .key = "Location",
                .value = "/index.html",
            }, .{
                .key = "Set-Cookie",
                .value = set_cookie_val,
            } },
        };

        const writer = try http.Writer.init(self.server.alloc, header, "", false);
        self.inner.setResponse(writer);
        self.state = .http;
    }

    fn generateSingleNumberResponse(alloc: Allocator, number: anytype) !http.Writer {
        const stringized = try std.fmt.allocPrint(alloc, "{d}", .{number});
        errdefer alloc.free(stringized);

        const response_header = http.Header{
            .status = .ok,
            .content_type = .@"application/json",
            .content_length = stringized.len,
        };
        return try http.Writer.init(alloc, response_header, stringized, true);
    }

    fn processAdminRequest(self: *Connection, url_purpose: AdminUrlPurpose, reader: http.Reader) !?http.Writer {
        var user = self.server.auth.userForRequest(self.server.alloc, reader.header_buf) catch |e| {
            std.log.err("Admin account check failed", .{});
            return e;
        } orelse {
            std.log.err("Admin request triggered when not logged in", .{});
            return error.Unauthenticated;
        };
        defer user.deinit(self.server.alloc);

        if (!std.mem.eql(u8, user.twitch_id, self.server.admin_id)) {
            std.log.err("Admin request triggered, but {s} is not an admin", .{user.twitch_id});
            return error.Unauthenticated;
        }

        switch (url_purpose) {
            .set_chambers_per_row => {
                const chambers_per_row = try std.fmt.parseInt(usize, reader.buf.items, 10);
                if (chambers_per_row < 1) {
                    return error.Invalid;
                }
                self.server.server_sim.simulation.setChambersPerRow(chambers_per_row);
                const response_header = http.Header{
                    .status = .ok,
                    .content_type = .@"application/json",
                    .content_length = 0,
                };
                return try http.Writer.init(self.server.alloc, response_header, "", false);
            },
            .set_num_balls => {
                const num_balls = try std.fmt.parseInt(usize, reader.buf.items, 10);

                try self.server.server_sim.simulation.setNumBalls(num_balls);
                const response_header = http.Header{
                    .status = .ok,
                    .content_type = .@"application/json",
                    .content_length = 0,
                };
                return try http.Writer.init(self.server.alloc, response_header, "", false);
            },
            .reset => {
                const simulation = &self.server.server_sim.simulation;
                simulation.reset();
                const response_header = http.Header{
                    .status = .ok,
                    .content_type = .@"application/json",
                    .content_length = 0,
                };
                return try http.Writer.init(self.server.alloc, response_header, "", false);
            },
            .accept_chamber => |id_raw| {
                const id = Db.ChamberId{ .value = id_raw };

                var chamber = try self.server.db.getChamber(self.server.alloc, id);
                defer chamber.deinit(self.server.alloc);

                try self.server.server_sim.appendChamber(id, chamber.data);

                try self.server.db.setChamberState(id, Db.ChamberState.accepted);
                const response_header = http.Header{
                    .status = .ok,
                    .content_type = .@"application/json",
                    .content_length = 0,
                };
                return try http.Writer.init(self.server.alloc, response_header, "", false);
            },
            .reject_chamber => |id_raw| {
                const id = Db.ChamberId{ .value = id_raw };

                try self.server.db.setChamberState(id, Db.ChamberState.rejected);

                const response_header = http.Header{
                    .status = .ok,
                    .content_type = .@"application/json",
                    .content_length = 0,
                };
                return try http.Writer.init(self.server.alloc, response_header, "", false);
            },
        }
    }

    fn processRequest(self: *Connection, reader: http.Reader) !?http.Writer {
        const url_purpose = try UrlPurpose.parse(reader.target, reader.method);
        switch (url_purpose) {
            .admin => |admin_url_purpose| {
                return try self.processAdminRequest(admin_url_purpose, reader);
            },
            .init_info => {
                const InitInfo = struct {
                    chamber_height: f32,
                    chambers_per_row: usize,
                    num_balls: usize,
                    chamber_ids: []usize,
                };

                comptime {
                    const ChamberId = @typeInfo(@TypeOf(self.server.server_sim.chamber_ids).Slice).Pointer.child;
                    std.debug.assert(@alignOf(ChamberId) == @alignOf(usize));
                    std.debug.assert(@sizeOf(ChamberId) == @sizeOf(usize));
                }

                const init_info = InitInfo{
                    .chamber_height = Simulation.chamber_height,
                    .chambers_per_row = self.server.server_sim.simulation.chambers_per_row,
                    .num_balls = self.server.server_sim.simulation.balls.items.len,
                    .chamber_ids = std.mem.bytesAsSlice(usize, std.mem.sliceAsBytes(self.server.server_sim.chamber_ids.items)),
                };

                var out_buf = try std.ArrayList(u8).initCapacity(self.server.alloc, 4096);
                errdefer out_buf.deinit();

                try std.json.stringify(init_info, .{}, out_buf.writer());

                const response_body = try out_buf.toOwnedSlice();
                errdefer self.server.alloc.free(response_body);

                const response_header = http.Header{
                    .status = .ok,
                    .content_type = .@"application/json",
                    .content_length = response_body.len,
                };
                return try http.Writer.init(self.server.alloc, response_header, response_body, true);
            },
            .simulation_state => |since| {
                var it = self.server.server_sim.history.iter();
                const serializer = SimulationStateSerializer{ .it = &it, .since = since };

                var out_buf = try std.ArrayList(u8).initCapacity(self.server.alloc, 4096);
                errdefer out_buf.deinit();

                try std.json.stringify(serializer, .{ .emit_strings_as_arrays = true }, out_buf.writer());

                const response_body = try out_buf.toOwnedSlice();
                errdefer self.server.alloc.free(response_body);

                const response_header = http.Header{
                    .status = .ok,
                    .content_type = .@"application/json",
                    .content_length = response_body.len,
                };
                return try http.Writer.init(self.server.alloc, response_header, response_body, true);
            },
            .get_chamber => |id| {
                var chamber = try self.server.db.getChamber(self.server.alloc, Db.ChamberId{ .value = id });
                defer chamber.deinit(self.server.alloc);

                // Writer object requires either owned or static memory, the
                // chamber info does not provide this
                const chamber_data = try self.server.alloc.dupe(u8, chamber.data);
                errdefer self.server.alloc.free(chamber_data);

                const response_header = http.Header{
                    .status = .ok,
                    .content_type = .@"application/wasm",
                    .content_length = chamber.data.len,
                };
                return try http.Writer.init(self.server.alloc, response_header, chamber_data, true);
            },
            .login_redirect => {
                // FIXME: If already logged in just redirect back to index
                return try self.server.auth.makeTwitchRedirect(self.server.client_id);
            },
            .login_code => |code| {
                try self.queueAuthRequest(code);
                self.state = .waiting_auth;
                return null;
            },
            .upload => {
                var user = try self.server.auth.userForRequest(self.server.alloc, reader.header_buf) orelse {
                    std.log.err("User is not logged in for upload", .{});
                    return error.NotLoggedIn;
                };
                defer user.deinit(self.server.alloc);

                var parts = try http.parseMultipartReq(self.server.alloc, reader.header_buf, reader.buf.items);
                defer parts.deinit();

                const chamber_name = parts.get("name") orelse {
                    return error.NoChamberName;
                };

                const chamber = parts.get("chamber") orelse {
                    return error.NoChamber;
                };

                const chamber_id = try self.server.db.addChamber(user.id, chamber_name, chamber);
                // Temporary hack
                try self.server.db.setChamberState(chamber_id, .validated);

                const response_header = http.Header{
                    .status = .see_other,
                    .content_type = .@"text/html",
                    .content_length = 0,
                    .extra = &.{
                        .{
                            .key = "Location",
                            .value = "/index.html",
                        },
                    },
                };
                return try http.Writer.init(self.server.alloc, response_header, "", false);
            },
            .unaccepted_chambers => {
                var unaccepted_chambers = try self.server.db.getChambersWithState(self.server.alloc, .validated);
                defer unaccepted_chambers.deinit(self.server.alloc);

                const UnacceptedChamberJsonSerializer = struct {
                    chamber_list: *const Db.ChamberList,
                    db: *Db,
                    alloc: Allocator,

                    pub fn jsonStringify(ser: *const @This(), writer: anytype) @TypeOf(writer.*).Error!void {
                        try writer.beginArray();
                        for (ser.chamber_list.items) |chamber| {
                            // FIXME: who is it by
                            const Elem = struct {
                                chamber_name: []const u8,
                                chamber_id: i64,
                                user: []const u8,
                            };
                            var info = ser.db.userFromId(ser.alloc, chamber.user_id) catch null;
                            defer {
                                if (info) |*v| {
                                    v.deinit(ser.alloc);
                                }
                            }
                            var name: []const u8 = "";
                            if (info) |v| {
                                name = v.username;
                            }
                            const elem = Elem{
                                .chamber_id = chamber.id.value,
                                .chamber_name = chamber.name,
                                .user = name,
                            };

                            try writer.write(elem);
                        }
                        try writer.endArray();
                    }
                };

                var out_buf = try std.ArrayList(u8).initCapacity(self.server.alloc, 4096);
                errdefer out_buf.deinit();

                const serializer = UnacceptedChamberJsonSerializer{
                    .chamber_list = &unaccepted_chambers,
                    .db = self.server.db,
                    .alloc = self.server.alloc,
                };

                try std.json.stringify(serializer, .{}, out_buf.writer());

                const response_body = try out_buf.toOwnedSlice();
                errdefer self.server.alloc.free(response_body);

                const response_header = http.Header{
                    .status = .ok,
                    .content_type = .@"application/json",
                    .content_length = response_body.len,
                };
                return try http.Writer.init(self.server.alloc, response_header, response_body, true);
            },
            .userinfo => {
                var user = try self.server.auth.userForRequest(self.server.alloc, reader.header_buf) orelse {
                    const response_header = http.Header{
                        .status = .not_found,
                        .content_type = .@"application/json",
                        .content_length = 0,
                    };
                    return try http.Writer.init(self.server.alloc, response_header, "", false);
                };
                defer user.deinit(self.server.alloc);

                const UserinfoJson = struct {
                    name: []const u8,
                    is_admin: bool,
                };

                const userinfo_json = UserinfoJson{
                    .name = user.username,
                    .is_admin = std.mem.eql(u8, user.twitch_id, self.server.admin_id),
                };

                var out_buf = try std.ArrayList(u8).initCapacity(self.server.alloc, 4096);
                defer out_buf.deinit();

                try std.json.stringify(userinfo_json, .{}, out_buf.writer());

                const to_send = try out_buf.toOwnedSlice();
                errdefer self.server.alloc.free(to_send);

                const response_header = http.Header{
                    .status = .ok,
                    .content_type = .@"application/json",
                    .content_length = to_send.len,
                };
                return try http.Writer.init(self.server.alloc, response_header, to_send, true);
            },
            .redirect => |loc| {
                const header = http.Header{
                    .content_type = .@"text/html",
                    .status = std.http.Status.see_other,
                    .content_length = 0,
                    .extra = &.{.{
                        .key = "Location",
                        .value = loc,
                    }},
                };

                return try http.Writer.init(self.server.alloc, header, "", false);
            },
            .get_resource => {
                if (self.server.www_root) |root| {
                    if (getResourcePathAlloc(self.server.alloc, root, reader.target)) |p| {
                        defer self.server.alloc.free(p);
                        var f = try std.fs.cwd().openFile(p, .{});
                        defer f.close();

                        const chamber = try f.readToEndAlloc(self.server.alloc, 10_000_000);
                        errdefer self.server.alloc.free(chamber);

                        const response_header = http.Header{
                            .status = .ok,
                            .content_type = try pathToContentType(reader.target),
                            .content_length = chamber.len,
                        };
                        return try http.Writer.init(self.server.alloc, response_header, chamber, true);
                    } else |_| {
                        std.log.err("{s} not found in resource dir, falling back to embedded", .{reader.target});
                    }
                }

                const content = try embeddedLookup(reader.target);
                const response_header = http.Header{
                    .status = .ok,
                    .content_type = try pathToContentType(reader.target),
                    .content_length = content.len,
                };
                return try http.Writer.init(self.server.alloc, response_header, content, false);
            },
        }
    }

    fn poll(self: *Connection) EventLoop.HandlerAction {
        while (true) {
            const action = self.inner.poll();
            switch (action) {
                .none => return .none,
                .feed => {
                    const response = self.processRequest(self.inner.reader) catch |e| {
                        std.log.err("Failed to generate response: {any}", .{e});
                        return .deinit;
                    } orelse {
                        return .none;
                    };
                    self.inner.setResponse(response);
                },
                .deinit => return .deinit,
            }
        }
    }
};

const SimulationStateSerializer = struct {
    it: *ServerSimulation.SnapshotHistory.Iter,
    since: u64,

    pub fn jsonStringify(self: *const SimulationStateSerializer, writer: anytype) @TypeOf(writer.*).Error!void {
        try writer.beginArray();

        while (self.it.next()) |item| {
            if (item.num_steps_taken > self.since) {
                try writer.write(item);
            }
        }

        try writer.endArray();
    }
};

// Wrapper around Connection specifically to handle the reception of the ID
// token from twitch's auth servers
const AuthWaitingConnection = struct {
    auth_future: future.Future([]const u8),
    inner: *Connection,

    fn init(inner: *Connection, auth_future: future.Future([]const u8)) !*AuthWaitingConnection {
        const ret = try inner.server.alloc.create(AuthWaitingConnection);
        inner.ref();

        ret.* = .{
            .auth_future = auth_future,
            .inner = inner,
        };
        return ret;
    }

    fn deinit(self: *AuthWaitingConnection) void {
        const alloc = self.inner.server.alloc;
        self.auth_future.deinit();
        self.inner.unref();
        alloc.destroy(self);
    }

    fn handler(self: *AuthWaitingConnection) EventLoop.EventHandler {
        return .{
            .data = self,
            .callback = EventLoop.EventHandler.makeCallback(AuthWaitingConnection, poll),
            .deinit = EventLoop.EventHandler.makeDeinit(AuthWaitingConnection, AuthWaitingConnection.deinit),
        };
    }

    fn unregisterInner(self: *AuthWaitingConnection) void {
        self.inner.server.event_loop.unregister(self.inner.inner.tcp.handle) catch {
            std.log.err("Failed to unregister connection", .{});
        };
    }

    fn poll(self: *AuthWaitingConnection) EventLoop.HandlerAction {
        const response = self.auth_future.poll() catch |e| {
            std.log.err("Failed to wait for auth response: {any}", .{e});
            return .deinit;
        } orelse {
            return .none;
        };
        defer self.inner.server.alloc.free(response);

        self.inner.setAuthResponse(response) catch {
            self.unregisterInner();
            return .deinit;
        };

        switch (self.inner.poll()) {
            .none => {},
            .deinit => self.unregisterInner(),
            .server_shutdown => return .server_shutdown,
        }
        return .deinit;
    }
};

fn spawn(self: *Server, stream: std.net.Stream) !EventLoop.EventHandler {
    var connection = try Connection.init(self, stream);
    return connection.handler();
}

const UrlComponents = struct {
    id: usize,
    target: []const u8,
};

fn isTaggedRequest(target: []const u8) ?UrlComponents {
    if (target.len < 1 or target[0] != '/') {
        return null;
    }

    var end = std.mem.indexOfScalar(u8, target[1..], '/') orelse {
        return null;
    };
    end += 1;

    const id = std.fmt.parseInt(usize, target[1..end], 10) catch {
        return null;
    };

    return .{
        .id = id,
        .target = target[end..],
    };
}

fn pathToContentType(path: []const u8) !http.ContentType {
    const Extension = enum {
        @".js",
        @".html",
        @".wasm",
        @".css",
    };

    inline for (std.meta.fields(Extension)) |field| {
        if (std.mem.endsWith(u8, path, field.name)) {
            const enumVal: Extension = @enumFromInt(field.value);
            switch (enumVal) {
                .@".js" => return .@"text/javascript",
                .@".html" => return .@"text/html",
                .@".wasm" => return .@"application/wasm",
                .@".css" => return .@"text/css",
            }
        }
    }

    return error.Unimplemented;
}

fn embeddedLookup(path: []const u8) ![]const u8 {
    const path_rel = path[1..];
    for (resources.resources) |elem| {
        if (std.mem.eql(u8, elem.path, path_rel)) {
            return elem.data;
        }
    }
    std.log.err("No file {s} embedded in application", .{path});
    return error.InvalidPath;
}

fn getResourcePathAlloc(alloc: Allocator, root: []const u8, path: []const u8) ![]const u8 {
    var dir = try std.fs.cwd().openDir(root, .{});
    defer dir.close();

    const real_path = try dir.realpathAlloc(alloc, path[1..]);
    errdefer alloc.free(real_path);

    const root_real_path = try std.fs.realpathAlloc(alloc, root);
    defer alloc.free(root_real_path);

    if (!std.mem.startsWith(u8, real_path, root_real_path)) {
        return error.InvalidPath;
    }

    return real_path;
}

const AdminUrlPurpose = union(enum) {
    set_chambers_per_row: void,
    set_num_balls: void,
    accept_chamber: i64,
    reject_chamber: i64,
    reset: void,
};

const UrlPurpose = union(enum) {
    admin: AdminUrlPurpose,
    init_info: void,
    simulation_state: u64,
    get_chamber: i64,
    login_redirect: void,
    login_code: []const u8,
    upload: void,
    userinfo: void,
    get_resource: void,
    redirect: []const u8,
    unaccepted_chambers: void,

    fn parseGetChamber(target: []const u8) ?UrlPurpose {
        if (target.len < 1 or target[0] != '/') {
            return null;
        }

        var end = std.mem.indexOfScalar(u8, target[1..], '/') orelse {
            return null;
        };
        end += 1;

        // FIXME: max id check
        const id = std.fmt.parseInt(i64, target[1..end], 10) catch {
            return null;
        };

        const remaining = target[end..];
        if (std.mem.eql(u8, remaining, "/chamber.wasm")) {
            return UrlPurpose{ .get_chamber = id };
        }

        return null;
    }

    fn extractStringFromQueryParams(target: []const u8, key: []const u8) ?[]const u8 {
        var it = http.QueryParamsIt.init(target);
        while (it.next()) |param| {
            if (std.mem.eql(u8, param.key, key)) {
                return param.val;
            }
        }

        return null;
    }

    fn extractIdFromQueryParams(target: []const u8) !?i64 {
        const id_s = extractStringFromQueryParams(target, "id") orelse {
            return null;
        };
        return try std.fmt.parseInt(i64, id_s, 10);
    }

    const NonIndexedTargetOption = enum {
        @"/init_info",
        @"/login_redirect",
        @"/upload",
        @"/userinfo",
        @"/chambers_per_row",
        @"/num_balls",
        @"/",
        @"/reset",
        @"/simulation_state",
        @"/unaccepted_chambers",
    };

    const QueryParamOptions = enum {
        @"/login_code",
        @"/accept_chamber",
        @"/reject_chamber",
        @"/simulation_state",

        fn parse(target: []const u8) ?QueryParamOptions {
            inline for (std.meta.fields(QueryParamOptions)) |field| {
                const field_w_qmark = field.name ++ "?";
                if (std.mem.startsWith(u8, target, field_w_qmark)) {
                    return @field(QueryParamOptions, field.name);
                }
            }

            return null;
        }
    };

    fn parse(target: []const u8, method: std.http.Method) !UrlPurpose {
        if (parseGetChamber(target)) |parsed| {
            return parsed;
        }

        if (std.meta.stringToEnum(NonIndexedTargetOption, target)) |option| {
            switch (option) {
                .@"/login_redirect" => {
                    return UrlPurpose{ .login_redirect = {} };
                },
                .@"/upload" => {
                    return UrlPurpose{ .upload = {} };
                },
                .@"/userinfo" => {
                    return UrlPurpose{ .userinfo = {} };
                },
                .@"/chambers_per_row" => {
                    if (method == .PUT) {
                        return UrlPurpose{ .admin = .{ .set_chambers_per_row = {} } };
                    } else {
                        return error.InvalidMethod;
                    }
                },
                .@"/num_balls" => {
                    if (method == .PUT) {
                        return UrlPurpose{ .admin = .{ .set_num_balls = {} } };
                    } else {
                        return error.InvalidMethod;
                    }
                },
                .@"/" => {
                    return UrlPurpose{ .redirect = "/index.html" };
                },
                .@"/reset" => {
                    return UrlPurpose{ .admin = .{ .reset = {} } };
                },
                .@"/init_info" => {
                    return UrlPurpose{ .init_info = {} };
                },
                .@"/simulation_state" => {
                    return UrlPurpose{ .simulation_state = 0 };
                },
                .@"/unaccepted_chambers" => {
                    return UrlPurpose{ .unaccepted_chambers = {} };
                },
            }
        }

        if (QueryParamOptions.parse(target)) |opt| {
            switch (opt) {
                .@"/login_code" => {
                    const code = extractStringFromQueryParams(target, "code") orelse {
                        return error.NoCode;
                    };

                    return UrlPurpose{ .login_code = code };
                },
                .@"/accept_chamber" => {
                    const id = try extractIdFromQueryParams(target) orelse {
                        std.log.err("ID param not provided in /accept_chamber", .{});
                        return error.NoId;
                    };

                    return UrlPurpose{ .admin = .{ .accept_chamber = id } };
                },
                .@"/reject_chamber" => {
                    const id = try extractIdFromQueryParams(target) orelse {
                        std.log.err("ID param not provided in /reject_chamber", .{});
                        return error.NoId;
                    };

                    return UrlPurpose{ .admin = .{ .reject_chamber = id } };
                },
                .@"/simulation_state" => {
                    const since_s = extractStringFromQueryParams(target, "since") orelse "0";
                    const since = try std.fmt.parseInt(u64, since_s, 10);

                    return UrlPurpose{ .simulation_state = since };
                },
            }
        }

        return UrlPurpose{ .get_resource = {} };
    }
};

const AuthRequestQueue = struct {
    const Request = struct {
        code: []const u8,
        promise: *future.Promise([]const u8),

        fn deinit(self: *@This()) void {
            self.promise.unref();
        }
    };
    const Fifo = std.fifo.LinearFifo(Request, .{ .Static = 100 });

    mutex: std.Thread.Mutex = .{},
    cv: std.Thread.Condition = .{},
    fifo: Fifo = Fifo.init(),

    fn pop(self: *AuthRequestQueue, timeout_ns: u64) ?Request {
        self.mutex.lock();
        defer self.mutex.unlock();

        while (true) {
            self.cv.timedWait(&self.mutex, timeout_ns) catch {
                return null;
            };
            return self.fifo.readItem();
        }
    }

    fn push(self: *AuthRequestQueue, req: Request) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        try self.fifo.writeItem(req);
        self.cv.signal();
    }
};

const AuthRequestThread = struct {
    alloc: Allocator,
    server_url: []const u8,
    client: HttpClient,
    shutdown: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    client_id: []const u8,
    client_secret: []const u8,
    request_queue: AuthRequestQueue = .{},

    fn init(
        alloc: Allocator,
        client_id: []const u8,
        client_secret: []const u8,
        server_url: []const u8,
    ) !*AuthRequestThread {
        const ret = try alloc.create(AuthRequestThread);
        errdefer alloc.destroy(ret);

        const client = try HttpClient.init();
        ret.* = .{
            .alloc = alloc,
            .client = client,
            .client_id = client_id,
            .client_secret = client_secret,
            .server_url = server_url,
        };
        return ret;
    }

    fn deinit(self: *AuthRequestThread) void {
        self.client.deinit();
        self.alloc.destroy(self);
    }

    fn run(self: *AuthRequestThread) !void {
        while (!self.shutdown.load(.monotonic)) {
            var req = self.request_queue.pop(50_000_000) orelse {
                continue;
            };
            defer req.deinit();

            var data_buf: [512]u8 = undefined;
            const req_data = try std.fmt.bufPrintZ(
                &data_buf,
                "client_id={s}" ++
                    "&client_secret={s}" ++
                    "&code={s}" ++
                    "&grant_type=authorization_code" ++
                    "&redirect_uri={s}/login_code",
                .{ self.client_id, self.client_secret, req.code, self.server_url },
            );
            const url = "https://id.twitch.tv/oauth2/token";
            const response = try self.client.post(self.alloc, url, req_data);
            req.promise.set(response);
        }
    }
};
