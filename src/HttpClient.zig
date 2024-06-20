const std = @import("std");
const Allocator = std.mem.Allocator;
const c = @import("c.zig");

const HttpClient = @This();

curl: *c.CURL,

pub fn init() !HttpClient {
    const curl = c.curl_easy_init() orelse {
        return error.InternalError;
    };

    return .{
        .curl = curl,
    };
}

pub fn deinit(self: *HttpClient) void {
    c.curl_easy_cleanup(self.curl);
}

pub fn post(self: *HttpClient, alloc: Allocator, url: [:0]const u8, data: [:0]const u8) ![]const u8 {
    const Output = std.ArrayList(u8);
    const writeCallback = struct {
        fn f(contents: ?*anyopaque, size: usize, nmemb: usize, userdata: ?*anyopaque) callconv(.C) usize {
            const real_size = size * nmemb;
            const contents_u8: [*]u8 = @ptrCast(contents);

            var output: *Output = @ptrCast(@alignCast(userdata));
            output.appendSlice(contents_u8[0..real_size]) catch {
                @panic("uh oh");
            };

            return real_size;
        }
    }.f;

    var output = Output.init(alloc);

    try checkOk(c.curl_easy_setopt(self.curl, c.CURLOPT_URL, url.ptr));
    try checkOk(c.curl_easy_setopt(self.curl, c.CURLOPT_POSTFIELDS, data.ptr));
    try checkOk(c.curl_easy_setopt(self.curl, c.CURLOPT_WRITEFUNCTION, writeCallback));
    try checkOk(c.curl_easy_setopt(self.curl, c.CURLOPT_WRITEDATA, &output));
    try checkOk(c.curl_easy_perform(self.curl));

    return try output.toOwnedSlice();
}

fn checkOk(ret: c_uint) !void {
    if (ret != c.CURLE_OK) {
        return error.InternalError;
    }
}
