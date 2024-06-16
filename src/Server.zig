const std = @import("std");
const http = @import("http.zig");
const resources = @import("resources");
const EventLoop = @import("EventLoop.zig");
const Allocator = std.mem.Allocator;
const Simulation = @import("Simulation.zig");
const physics = @import("physics.zig");
const Ball = physics.Ball;

const Server = @This();

alloc: Allocator,
event_loop: *EventLoop,
server: std.net.Server,
www_root: ?[]const u8,
chamber_paths: []const []const u8,
simulations: []Simulation,

pub fn init(
    alloc: Allocator,
    address: std.net.Address,
    event_loop: *EventLoop,
    www_root: ?[]const u8,
    chamber_paths: []const []const u8,
    simulations: []Simulation,
) !Server {
    var tcp_server = try address.listen(.{
        .reuse_port = true,
        .reuse_address = true,
    });
    errdefer tcp_server.deinit();

    try setNonblock(tcp_server.stream);

    return .{
        .alloc = alloc,
        .event_loop = event_loop,
        .server = tcp_server,
        .www_root = www_root,
        .chamber_paths = chamber_paths,
        .simulations = simulations,
    };
}

pub fn deinit(self: *Server) void {
    self.server.deinit();
}

pub fn handler(self: *Server) EventLoop.EventHandler {
    const callback = struct {
        fn f(data: ?*anyopaque) EventLoop.HandlerAction {
            return Server.acceptTcpConnection(@ptrCast(@alignCast(data))) catch |e| {
                std.log.err("Failed to create http connection: {any}", .{e});
                return .none;
            };
        }
    }.f;

    return .{
        .data = self,
        .callback = callback,
        .deinit = null,
    };
}

fn acceptTcpConnection(self: *Server) anyerror!EventLoop.HandlerAction {
    var connection = self.server.accept() catch {
        return .deinit;
    };

    var http_server = HttpConnection.init(self.alloc, connection.stream, self) catch |e| {
        connection.stream.close();
        return e;
    };
    errdefer http_server.deinit();

    try self.event_loop.register(connection.stream.handle, http_server.handler());
    return .none;
}

fn setNonblock(conn: std.net.Stream) !void {
    var flags = try std.posix.fcntl(conn.handle, std.posix.F.GETFL, 0);
    var flags_s: *std.posix.O = @ptrCast(&flags);
    flags_s.NONBLOCK = true;
    _ = try std.posix.fcntl(conn.handle, std.posix.F.SETFL, flags);
}

const HttpConnection = struct {
    const State = enum {
        read,
        write,
        finished,
        deinit,
    };

    alloc: Allocator,
    tcp: std.net.Stream,
    server: *Server,
    state: State = .read,

    reader: http.Reader = .{},
    writer: http.Writer = .{},

    fn init(alloc: Allocator, tcp: std.net.Stream, server: *Server) !*HttpConnection {
        const ret = try alloc.create(HttpConnection);
        errdefer alloc.destroy(ret);

        try setNonblock(tcp);

        ret.* = .{
            .alloc = alloc,
            .tcp = tcp,
            .server = server,
        };
        return ret;
    }

    fn reset(self: *HttpConnection) void {
        self.reader.deinit(self.alloc);
        self.writer.deinit(self.alloc);

        self.state = .read;
        self.reader = .{};
        self.writer = .{};
    }

    fn deinit(self: *HttpConnection) void {
        self.reset();
        self.tcp.close();
        self.alloc.destroy(self);
    }

    fn handler(self: *HttpConnection) EventLoop.EventHandler {
        const callback = struct {
            fn f(userdata: ?*anyopaque) EventLoop.HandlerAction {
                const server: *HttpConnection = @ptrCast(@alignCast(userdata));
                return server.pollNoError();
            }
        }.f;

        const opaque_deinit = struct {
            fn f(userdata: ?*anyopaque) void {
                const server: *HttpConnection = @ptrCast(@alignCast(userdata));
                server.deinit();
            }
        }.f;

        return .{
            .data = self,
            .callback = callback,
            .deinit = opaque_deinit,
        };
    }

    fn setupResponse(self: *HttpConnection) !void {
        errdefer self.state = .deinit;
        defer self.state = .write;

        if (std.mem.eql(u8, self.reader.target, "/num_simulations")) {
            const num_sims_s = try std.fmt.allocPrint(self.alloc, "{d}", .{self.server.simulations.len});
            errdefer self.alloc.free(num_sims_s);

            const response_header = http.Header{
                .status = .ok,
                .content_type = .@"application/json",
                .content_length = num_sims_s.len,
            };
            self.writer = try http.Writer.init(self.alloc, response_header, num_sims_s, true);
            return;
        }

        if (isTaggedRequest(self.reader.target)) |tagged_url| {
            if (tagged_url.id >= self.server.simulations.len) {
                return error.InvalidId;
            }
            const simulation = &self.server.simulations[tagged_url.id];
            const target = tagged_url.target;

            if (std.mem.startsWith(u8, target, "/simulation_state")) {
                const ResponseJson = struct {
                    balls: [Simulation.num_balls]Ball,
                    chamber_state: []const u8,
                };

                var chamber_save: []const u8 = &.{};
                defer self.alloc.free(chamber_save);

                const response_content = blk: {
                    simulation.mutex.lock();
                    defer simulation.mutex.unlock();

                    chamber_save = try simulation.chamber_mod.save(self.alloc, simulation.chamber_state);

                    break :blk ResponseJson{
                        .balls = simulation.balls,
                        .chamber_state = chamber_save,
                    };
                };

                var out_buf = try std.ArrayList(u8).initCapacity(self.alloc, 4096);
                errdefer out_buf.deinit();
                try std.json.stringify(response_content, .{ .emit_strings_as_arrays = true }, out_buf.writer());

                const response_body = try out_buf.toOwnedSlice();
                errdefer self.alloc.free(response_body);

                const response_header = http.Header{
                    .status = .ok,
                    .content_type = .@"application/json",
                    .content_length = response_body.len,
                };
                self.writer = try http.Writer.init(self.alloc, response_header, response_body, true);
                return;
            } else if (std.mem.eql(u8, target, "/save")) {
                simulation.mutex.lock();
                defer simulation.mutex.unlock();

                try simulation.history.save("history.json");
                const response_header = http.Header{
                    .status = .ok,
                    .content_type = .@"application/json",
                    .content_length = 0,
                };
                self.writer = try http.Writer.init(self.alloc, response_header, "", false);
                return;
            } else if (std.mem.eql(u8, target, "/reset")) {
                simulation.mutex.lock();
                defer simulation.mutex.unlock();
                simulation.reset();
                const response_header = http.Header{
                    .status = .ok,
                    .content_type = .@"application/json",
                    .content_length = 0,
                };
                self.writer = try http.Writer.init(self.alloc, response_header, "", false);
                return;
            } else if (std.mem.eql(u8, target, "/chamber.wasm")) {
                var f = try std.fs.cwd().openFile(self.server.chamber_paths[tagged_url.id], .{});
                const chamber = try f.readToEndAlloc(self.alloc, 10_000_000);
                errdefer self.alloc.free(chamber);

                const response_header = http.Header{
                    .status = .ok,
                    .content_type = try pathToContentType(target),
                    .content_length = chamber.len,
                };
                self.writer = try http.Writer.init(self.alloc, response_header, chamber, true);
                return;
            }
        }

        if (self.server.www_root) |root| {
            if (getResourcePathAlloc(self.alloc, root, self.reader.target)) |p| {
                defer self.alloc.free(p);
                var f = try std.fs.cwd().openFile(p, .{});
                const chamber = try f.readToEndAlloc(self.alloc, 10_000_000);
                errdefer self.alloc.free(chamber);

                const response_header = http.Header{
                    .status = .ok,
                    .content_type = try pathToContentType(self.reader.target),
                    .content_length = chamber.len,
                };
                self.writer = try http.Writer.init(self.alloc, response_header, chamber, true);
                return;
            } else |_| {
                std.log.err("{s} not found in resource dir, falling back to embedded", .{self.reader.target});
            }
        }

        const content = try embeddedLookup(self.reader.target);
        const response_header = http.Header{
            .status = .ok,
            .content_type = try pathToContentType(self.reader.target),
            .content_length = content.len,
        };
        self.writer = try http.Writer.init(self.alloc, response_header, content, false);
    }

    fn read(self: *HttpConnection) !void {
        try self.reader.poll(self.alloc, self.tcp);

        if (self.reader.state == .deinit) {
            self.state = .deinit;
            return;
        }

        if (self.reader.state == .finished) {
            try self.setupResponse();
            return;
        }
    }

    fn write(self: *HttpConnection) !void {
        try self.writer.poll(self.tcp);

        if (self.writer.state == .deinit) {
            self.state = .deinit;
            return;
        }

        if (self.writer.state == .finished) {
            self.state = .finished;
            return;
        }
    }

    fn pollNoError(self: *HttpConnection) EventLoop.HandlerAction {
        return self.poll() catch |e| {
            if (e == error.WouldBlock) {
                return .none;
            }

            std.log.err("Error {any}", .{e});

            return .deinit;
        };
    }

    fn poll(self: *HttpConnection) !EventLoop.HandlerAction {
        while (true) {
            switch (self.state) {
                .read => try self.read(),
                .write => try self.write(),
                .deinit => return .deinit,
                .finished => {
                    // For the time being it seems that connection re-use
                    // actually reduces the amount of requests a browser will
                    // make per second, making the simulation look choppy
                    return .deinit;
                },
            }
        }
    }
};

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

pub fn pathToContentType(path: []const u8) !http.ContentType {
    const Extension = enum {
        @".js",
        @".html",
        @".wasm",
    };

    inline for (std.meta.fields(Extension)) |field| {
        if (std.mem.endsWith(u8, path, field.name)) {
            const enumVal: Extension = @enumFromInt(field.value);
            switch (enumVal) {
                .@".js" => return .@"text/javascript",
                .@".html" => return .@"text/html",
                .@".wasm" => return .@"application/wasm",
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

pub fn getResourcePathAlloc(alloc: Allocator, root: []const u8, path: []const u8) ![]const u8 {
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
