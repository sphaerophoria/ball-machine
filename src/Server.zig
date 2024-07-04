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
const App = @import("App.zig");
const Db = @import("Db.zig");

const Server = @This();

alloc: Allocator,
www_root: ?[]const u8,
app: *App,
client_id: []const u8,
auth_request_thread: *AuthRequestThread,
auth_request_handle: std.Thread,
event_loop: *EventLoop,
auth: Authentication,
db: *Db,

pub fn init(
    alloc: Allocator,
    www_root: ?[]const u8,
    app: *App,
    client_id: []const u8,
    client_secret: []const u8,
    jwt_keys: []const userinfo.RsaParams,
    event_loop: *EventLoop,
    db: *Db,
) !Server {
    const trimmed_id = std.mem.trim(u8, client_id, &std.ascii.whitespace);
    const trimmed_secret = std.mem.trim(u8, client_secret, &std.ascii.whitespace);

    const auth_request_thread = try AuthRequestThread.init(alloc, trimmed_id, trimmed_secret);
    errdefer auth_request_thread.deinit();

    const auth_request_handle = try std.Thread.spawn(
        .{},
        AuthRequestThread.run,
        .{auth_request_thread},
    );

    const auth = try Authentication.init(alloc, jwt_keys, db);

    return Server{
        .alloc = alloc,
        .www_root = www_root,
        .app = app,
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

    fn getSimulation(self: *Connection, id: usize) !*Simulation {
        if (id >= self.server.app.simulations.items.len) {
            return error.OutOfBounds;
        }

        return &self.server.app.simulations.items[id];
    }

    fn processRequest(self: *Connection, reader: http.Reader) !?http.Writer {
        const url_purpose = try UrlPurpose.parse(reader.target);
        switch (url_purpose) {
            .num_simulations => {
                const num_sims_s = try std.fmt.allocPrint(self.server.alloc, "{d}", .{self.server.app.simulations.items.len});
                errdefer self.server.alloc.free(num_sims_s);

                const response_header = http.Header{
                    .status = .ok,
                    .content_type = .@"application/json",
                    .content_length = num_sims_s.len,
                };
                return try http.Writer.init(self.server.alloc, response_header, num_sims_s, true);
            },
            .simulation_state => |id| {
                const simulation = try self.getSimulation(id);
                const ResponseJson = struct {
                    balls: [Simulation.num_balls]Ball,
                    chamber_state: []const u8,
                };

                var chamber_save: []const u8 = &.{};
                defer self.server.alloc.free(chamber_save);

                const response_content = blk: {
                    simulation.mutex.lock();
                    defer simulation.mutex.unlock();

                    chamber_save = try simulation.chamber_mod.save(self.server.alloc);

                    break :blk ResponseJson{
                        .balls = simulation.balls,
                        .chamber_state = chamber_save,
                    };
                };

                var out_buf = try std.ArrayList(u8).initCapacity(self.server.alloc, 4096);
                errdefer out_buf.deinit();
                try std.json.stringify(response_content, .{ .emit_strings_as_arrays = true }, out_buf.writer());

                const response_body = try out_buf.toOwnedSlice();
                errdefer self.server.alloc.free(response_body);

                const response_header = http.Header{
                    .status = .ok,
                    .content_type = .@"application/json",
                    .content_length = response_body.len,
                };
                return try http.Writer.init(self.server.alloc, response_header, response_body, true);
            },
            .reset => |id| {
                const simulation = try self.getSimulation(id);
                simulation.mutex.lock();
                defer simulation.mutex.unlock();
                simulation.reset();
                const response_header = http.Header{
                    .status = .ok,
                    .content_type = .@"application/json",
                    .content_length = 0,
                };
                return try http.Writer.init(self.server.alloc, response_header, "", false);
            },
            .get_chamber => |id| {
                if (id >= self.server.app.chamber_ids.items.len) {
                    return error.OutOfBounds;
                }

                var chamber = try self.server.db.getChamber(self.server.alloc, self.server.app.chamber_ids.items[id]);
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
                self.server.app.appendChamber(chamber_id, chamber) catch |e| {
                    self.server.db.deleteChamber(chamber_id) catch |del_err| {
                        std.log.err("Failed to delete chamber: {any}", .{del_err});
                    };
                    return e;
                };

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

                const username = try std.fmt.allocPrint(self.server.alloc, "\"{s}\"", .{user.username});
                const response_header = http.Header{
                    .status = .ok,
                    .content_type = .@"application/json",
                    .content_length = username.len,
                };
                return try http.Writer.init(self.server.alloc, response_header, username, true);
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

const UrlPurpose = union(enum) {
    simulation_state: usize,
    reset: usize,
    get_chamber: usize,
    login_redirect: void,
    login_code: []const u8,
    upload: void,
    userinfo: void,
    get_resource: void,
    redirect: []const u8,
    num_simulations: void,

    const IndexedTargetOption = enum {
        @"/simulation_state",
        @"/reset",
        @"/chamber.wasm",
    };

    fn parseIndexed(target: []const u8) ?UrlPurpose {
        if (target.len < 1 or target[0] != '/') {
            return null;
        }

        var end = std.mem.indexOfScalar(u8, target[1..], '/') orelse {
            return null;
        };
        end += 1;

        // FIXME: max id check
        const id = std.fmt.parseInt(usize, target[1..end], 10) catch {
            return null;
        };

        const remaining = target[end..];
        const option = std.meta.stringToEnum(IndexedTargetOption, remaining) orelse {
            return null;
        };

        switch (option) {
            .@"/simulation_state" => {
                return UrlPurpose{ .simulation_state = id };
            },
            .@"/reset" => {
                return UrlPurpose{ .reset = id };
            },
            .@"/chamber.wasm" => {
                return UrlPurpose{ .get_chamber = id };
            },
        }
    }

    fn extractCodeFromQueryParams(target: []const u8) ?[]const u8 {
        var it = http.QueryParamsIt.init(target);
        while (it.next()) |param| {
            if (std.mem.eql(u8, param.key, "code")) {
                return param.val;
            }
        }

        return null;
    }

    const NonIndexedTargetOption = enum {
        @"/login_redirect",
        @"/upload",
        @"/userinfo",
        @"/num_simulations",
        @"/",
    };

    fn parse(target: []const u8) !UrlPurpose {
        if (parseIndexed(target)) |parsed| {
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
                .@"/num_simulations" => {
                    return UrlPurpose{ .num_simulations = {} };
                },
                .@"/" => {
                    return UrlPurpose{ .redirect = "/index.html" };
                },
            }
        }

        if (std.mem.startsWith(u8, target, "/login_code?")) {
            const code = extractCodeFromQueryParams(target) orelse {
                return error.NoCode;
            };

            return UrlPurpose{ .login_code = code };
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
    client: HttpClient,
    shutdown: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    client_id: []const u8,
    client_secret: []const u8,
    request_queue: AuthRequestQueue = .{},

    fn init(
        alloc: Allocator,
        client_id: []const u8,
        client_secret: []const u8,
    ) !*AuthRequestThread {
        const ret = try alloc.create(AuthRequestThread);
        errdefer alloc.destroy(ret);

        const client = try HttpClient.init();
        ret.* = .{
            .alloc = alloc,
            .client = client,
            .client_id = client_id,
            .client_secret = client_secret,
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
                    "&redirect_uri=http://localhost:8000/login_code",
                .{ self.client_id, self.client_secret, req.code },
            );
            const url = "https://id.twitch.tv/oauth2/token";
            const response = try self.client.post(self.alloc, url, req_data);
            req.promise.set(response);
        }
    }
};
