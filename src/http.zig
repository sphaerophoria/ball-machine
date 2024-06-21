const std = @import("std");
const mem = std.mem;
const Allocator = std.mem.Allocator;
const EventLoop = @import("EventLoop.zig");

pub const ContentType = enum {
    @"application/json",
    @"text/html",
    @"text/javascript",
    @"application/wasm",

    fn name(self: ContentType) []const u8 {
        inline for (std.meta.fields(ContentType)) |field| {
            if (@intFromEnum(self) == field.value) {
                return field.name;
            }
        }

        unreachable;
    }
};

pub const Header = struct {
    status: std.http.Status,
    content_type: ContentType,
    content_length: usize,

    pub fn format(self: *const Header, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) @TypeOf(writer).Error!void {
        _ = options;
        _ = fmt;

        try writer.print(
            "HTTP/1.1 {d} {s}\r\n" ++
                "Content-Type: {s}\r\n" ++
                "Connection: close\r\n" ++
                "Content-Length: {d}\r\n" ++
                "\r\n",
            .{
                @intFromEnum(self.status),
                self.status.phrase() orelse "",
                self.content_type.name(),
                self.content_length,
            },
        );
    }
};
pub const Reader = struct {
    const State = enum {
        read_header,
        read_body,
        finished,
        deinit,
    };

    state: State = .read_header,
    hp: std.http.HeadParser = .{},

    // General buffer used in any read state, at .finished will be the body
    buf: std.ArrayListUnmanaged(u8) = .{},

    // Valid after .read_header
    header_size: usize = 0,
    header_buf: []const u8 = &.{},
    target: []const u8 = &.{},
    transfer_encoding: std.http.TransferEncoding = undefined,
    content_length: ?u64 = null,

    pub fn deinit(self: *Reader, alloc: Allocator) void {
        self.buf.deinit(alloc);
        alloc.free(self.header_buf);
    }

    pub fn poll(self: *Reader, alloc: Allocator, tcp: std.net.Stream) !void {
        while (true) {
            switch (self.state) {
                .read_header => try self.readHeader(alloc, tcp),
                .read_body => try self.readBody(alloc, tcp),
                .deinit, .finished => {
                    return;
                },
            }
        }
    }

    fn readHeader(self: *Reader, alloc: Allocator, tcp: std.net.Stream) !void {
        while (self.hp.state != .finished) {
            var buf: [1024]u8 = undefined;
            const buf_len = try tcp.read(&buf);
            if (buf_len == 0) {
                self.state = .deinit;
                return;
            }

            try self.buf.appendSlice(alloc, buf[0..buf_len]);
            self.header_size += self.hp.feed(buf[0..buf_len]);
        }

        var new_buf = std.ArrayListUnmanaged(u8){};
        errdefer new_buf.deinit(alloc);

        try new_buf.appendSlice(alloc, self.buf.items[self.header_size..]);

        var old_buf = self.buf;
        old_buf.items.len = self.header_size;

        self.header_buf = try old_buf.toOwnedSlice(alloc);
        const header = try std.http.Server.Request.Head.parse(self.header_buf);
        self.target = header.target;
        self.transfer_encoding = header.transfer_encoding;
        self.content_length = header.content_length;

        self.buf = new_buf;
        self.state = .read_body;
    }

    fn readBody(self: *Reader, alloc: Allocator, tcp: std.net.Stream) !void {
        if (self.transfer_encoding == .chunked) {
            return error.Unsupported;
        }

        // FIXME: Set reasonable max len
        if (self.content_length == null) {
            self.state = .finished;
            return;
        }

        const cl = self.content_length.?;
        const expected_end_size = cl + self.header_size;
        while (self.buf.items.len < expected_end_size) {
            var buf: [1024]u8 = undefined;
            const buf_len = try tcp.read(&buf);
            if (buf_len == 0) {
                self.state = .deinit;
                return;
            }

            try self.buf.appendSlice(alloc, buf[0..buf_len]);

            if (self.buf.items.len > expected_end_size) {
                return error.InvalidData;
            } else if (self.buf.items.len == expected_end_size) {
                self.state = .finished;
                return;
            }
        }
    }
};

pub const Writer = struct {
    state: State = .write_header,
    header_writer: WriteState = .{},
    deinit_body: bool = false,
    body_writer: WriteState = .{},

    const State = enum {
        write_header,
        write_body,
        finished,
        deinit,
    };

    pub fn init(alloc: Allocator, header: Header, body: []const u8, deinit_body: bool) !Writer {
        const header_buf = try std.fmt.allocPrint(alloc, "{any}", .{header});
        errdefer alloc.free(header_buf);

        return .{
            .header_writer = .{
                .to_write = header_buf,
            },
            .deinit_body = deinit_body,
            .body_writer = .{
                .to_write = body,
            },
        };
    }

    pub fn deinit(self: *Writer, alloc: Allocator) void {
        alloc.free(self.header_writer.to_write);
        if (self.deinit_body) {
            alloc.free(self.body_writer.to_write);
        }
    }

    pub fn poll(self: *Writer, tcp: std.net.Stream) !void {
        while (true) {
            switch (self.state) {
                .write_header => try self.writeHeader(tcp),
                .write_body => try self.writeBody(tcp),
                .deinit, .finished => {
                    return;
                },
            }
        }
    }

    fn writeHeader(self: *Writer, tcp: std.net.Stream) !void {
        if (try self.header_writer.write(tcp)) {
            self.state = .deinit;
            return;
        }
        self.state = .write_body;
    }

    fn writeBody(self: *Writer, tcp: std.net.Stream) !void {
        if (try self.body_writer.write(tcp)) {
            self.state = .deinit;
            return;
        }
        self.state = .finished;
    }
};

const WriteState = struct {
    to_write: []const u8 = &.{},
    amount_written: usize = 0,

    fn write(self: *WriteState, tcp: std.net.Stream) !bool {
        while (true) {
            if (self.amount_written >= self.to_write.len) {
                return false;
            }

            const written = try tcp.write(self.to_write[self.amount_written..]);
            if (written == 0) {
                return true;
            }
            self.amount_written += written;
        }
    }
};

pub const HttpResponseGenerator = struct {
    const Generator = fn (?*anyopaque, Reader) anyerror!Writer;
    data: ?*anyopaque,
    generate_fn: *const Generator,

    fn generate(self: *const HttpResponseGenerator, reader: Reader) !Writer {
        return self.generate_fn(self.data, reader);
    }
};

pub const HttpConnection = struct {
    const State = enum {
        read,
        write,
        finished,
        deinit,
    };

    alloc: Allocator,
    tcp: std.net.Stream,
    state: State = .read,
    response_generator: HttpResponseGenerator,

    reader: Reader = .{},
    writer: Writer = .{},

    pub fn init(alloc: Allocator, tcp: std.net.Stream, response_generator: HttpResponseGenerator) !*HttpConnection {
        const ret = try alloc.create(HttpConnection);
        errdefer alloc.destroy(ret);

        ret.* = .{
            .alloc = alloc,
            .tcp = tcp,
            .response_generator = response_generator,
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

    pub fn deinit(self: *HttpConnection) void {
        self.reset();
        self.tcp.close();
        self.alloc.destroy(self);
    }

    pub fn handler(self: *HttpConnection) EventLoop.EventHandler {
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

        self.writer = try self.response_generator.generate(self.reader);
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
