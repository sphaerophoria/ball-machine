const std = @import("std");
const http = @import("http.zig");
const resources = @import("resources");
const EventLoop = @import("EventLoop.zig");
const Allocator = std.mem.Allocator;
const Simulation = @import("Simulation.zig");
const physics = @import("physics.zig");
const Ball = physics.Ball;
const ConnectionSpawner = @import("TcpServer.zig").ConnectionSpawner;

const Server = @This();

alloc: Allocator,
www_root: ?[]const u8,
chamber_paths: []const []const u8,
simulations: []Simulation,

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

fn generateResponse(self: *Server, reader: http.Reader) !http.Writer {
    if (std.mem.eql(u8, reader.target, "/num_simulations")) {
        const num_sims_s = try std.fmt.allocPrint(self.alloc, "{d}", .{self.simulations.len});
        errdefer self.alloc.free(num_sims_s);

        const response_header = http.Header{
            .status = .ok,
            .content_type = .@"application/json",
            .content_length = num_sims_s.len,
        };
        return try http.Writer.init(self.alloc, response_header, num_sims_s, true);
    }

    if (isTaggedRequest(reader.target)) |tagged_url| {
        if (tagged_url.id >= self.simulations.len) {
            return error.InvalidId;
        }
        const simulation = &self.simulations[tagged_url.id];
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
            return try http.Writer.init(self.alloc, response_header, response_body, true);
        } else if (std.mem.eql(u8, target, "/save")) {
            simulation.mutex.lock();
            defer simulation.mutex.unlock();

            try simulation.history.save("history.json");
            const response_header = http.Header{
                .status = .ok,
                .content_type = .@"application/json",
                .content_length = 0,
            };
            return try http.Writer.init(self.alloc, response_header, "", false);
        } else if (std.mem.eql(u8, target, "/reset")) {
            simulation.mutex.lock();
            defer simulation.mutex.unlock();
            simulation.reset();
            const response_header = http.Header{
                .status = .ok,
                .content_type = .@"application/json",
                .content_length = 0,
            };
            return try http.Writer.init(self.alloc, response_header, "", false);
        } else if (std.mem.eql(u8, target, "/chamber.wasm")) {
            var f = try std.fs.cwd().openFile(self.chamber_paths[tagged_url.id], .{});
            const chamber = try f.readToEndAlloc(self.alloc, 10_000_000);
            errdefer self.alloc.free(chamber);

            const response_header = http.Header{
                .status = .ok,
                .content_type = try pathToContentType(target),
                .content_length = chamber.len,
            };
            return try http.Writer.init(self.alloc, response_header, chamber, true);
        }
    }

    if (self.www_root) |root| {
        if (getResourcePathAlloc(self.alloc, root, reader.target)) |p| {
            defer self.alloc.free(p);
            var f = try std.fs.cwd().openFile(p, .{});
            const chamber = try f.readToEndAlloc(self.alloc, 10_000_000);
            errdefer self.alloc.free(chamber);

            const response_header = http.Header{
                .status = .ok,
                .content_type = try pathToContentType(reader.target),
                .content_length = chamber.len,
            };
            return try http.Writer.init(self.alloc, response_header, chamber, true);
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
    return try http.Writer.init(self.alloc, response_header, content, false);
}

const Connection = struct {
    server: *Server,
    inner: http.HttpConnection,

    fn init(server: *Server, stream: std.net.Stream) !*Connection {
        var inner = try http.HttpConnection.init(server.alloc, stream);
        errdefer inner.deinit();

        const ret = try server.alloc.create(Connection);
        errdefer server.alloc.free(ret);

        ret.* = .{
            .server = server,
            .inner = inner,
        };

        return ret;
    }

    fn deinit(self: *Connection) void {
        self.inner.deinit();
        self.server.alloc.destroy(self);
    }

    fn handler(self: *Connection) EventLoop.EventHandler {
        const callback_fn = struct {
            fn f(data: ?*anyopaque) EventLoop.HandlerAction {
                const conn: *Connection = @ptrCast(@alignCast(data));
                return conn.poll();
            }
        }.f;

        const deinit_fn = struct {
            fn f(data: ?*anyopaque) void {
                const conn: *Connection = @ptrCast(@alignCast(data));
                conn.deinit();
            }
        }.f;

        return .{
            .data = self,
            .callback = callback_fn,
            .deinit = deinit_fn,
        };
    }

    fn poll(self: *Connection) EventLoop.HandlerAction {
        while (true) {
            const action = self.inner.poll();
            switch (action) {
                .none => return .none,
                .feed => {
                    const response = self.server.generateResponse(self.inner.reader) catch |e| {
                        std.log.err("Failed to generate response: {any}", .{e});
                        return .deinit;
                    };
                    self.inner.setResponse(response);
                },
                .deinit => return .deinit,
            }
        }
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
