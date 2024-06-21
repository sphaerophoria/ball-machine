const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const TcpServer = @import("TcpServer.zig");
const EventLoop = @import("EventLoop.zig");
const http = @import("http.zig");

const c = @cImport({
    @cInclude("openssl/rsa.h");
    @cInclude("openssl/sha.h");
    @cInclude("openssl/pem.h");
    @cInclude("openssl/param_build.h");
});

const RsaParams = struct {
    kid: []const u8,
    n: []const u8,
    e: []const u8,

    fn deinit(self: *const RsaParams, alloc: Allocator) void {
        alloc.free(self.kid);
        alloc.free(self.n);
        alloc.free(self.e);
    }
};

const RsaParamsList = struct {
    items: []RsaParams,

    fn deinit(self: *const RsaParamsList, alloc: Allocator) void {
        for (self.items) |elem| {
            elem.deinit(alloc);
        }
        alloc.free(self.items);
    }
};

const JsonWebKeys = struct {
    keys: []JsonWebKey,

    fn parse(alloc: Allocator, jwk: []const u8) !RsaParamsList {
        const parsed = try std.json.parseFromSlice(JsonWebKeys, alloc, jwk, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();

        var ret = std.ArrayList(RsaParams).init(alloc);
        defer {
            for (ret.items) |elem| {
                elem.deinit(alloc);
            }
            ret.deinit();
        }

        for (parsed.value.keys) |key| {
            key.validate() catch |e| {
                std.log.err("Failed to validate key: {any}", .{e});
                continue;
            };
            const params = try key.getRsaParams(alloc);
            errdefer params.deinit(alloc);

            try ret.append(params);
        }

        return .{
            .items = try ret.toOwnedSlice(),
        };
    }
};

fn base64UrlDecode(alloc: Allocator, data: []const u8) ![]const u8 {
    const num_padding_chars_needed = (4 - data.len % 4) % 4;
    const padded = try alloc.alloc(u8, data.len + num_padding_chars_needed);
    defer alloc.free(padded);
    @memcpy(padded[0..data.len], data);
    @memset(padded[data.len .. data.len + num_padding_chars_needed], '=');

    const size = try std.base64.url_safe.Decoder.calcSizeForSlice(padded);
    const decoded = try alloc.alloc(u8, size);
    errdefer alloc.free(decoded);

    try std.base64.url_safe.Decoder.decode(decoded, padded);
    return decoded;
}

const JsonWebKey = struct {
    alg: []const u8,
    e: []const u8,
    n: []const u8,
    kid: []const u8,
    kty: []const u8,
    use: []const u8,

    fn getRsaParams(self: JsonWebKey, alloc: Allocator) !RsaParams {
        const kid = try alloc.dupe(u8, self.kid);
        errdefer alloc.free(kid);

        const e = try base64UrlDecode(alloc, self.e);
        errdefer alloc.free(e);

        const n = try base64UrlDecode(alloc, self.n);
        errdefer alloc.free(n);

        return .{
            .kid = kid,
            .e = e,
            .n = n,
        };
    }

    fn validate(self: JsonWebKey) !void {
        if (!std.mem.eql(u8, self.alg, "RS256")) {
            std.log.err("Unsupported alg: {s}\n", .{self.alg});
            return error.Unsupported;
        }

        if (!std.mem.eql(u8, self.kty, "RSA")) {
            std.log.err("Unsupported key type: {s}\n", .{self.kty});
            return error.Unsupported;
        }

        if (!std.mem.eql(u8, self.use, "sig")) {
            std.log.err("Unsupported use: {s}\n", .{self.use});
            return error.Unsupported;
        }
    }
};

const JsonWebToken = struct {
    const Header = struct {
        alg: []const u8,
        typ: []const u8,
        kid: []const u8,

        fn verify(header: *const Header) !void {
            if (!std.mem.eql(u8, header.alg, "RS256")) {
                return error.Unsupported;
            }

            if (!std.mem.eql(u8, header.typ, "JWT")) {
                return error.Unsupported;
            }
        }

        fn selectKey(header: *const Header, rsa_params: []const RsaParams) ?RsaParams {
            for (rsa_params) |params| {
                if (std.mem.eql(u8, params.kid, header.kid)) {
                    return params;
                }
            }
            return null;
        }
    };

    const Message = struct {
        aud: []const u8,
        exp: i64,
        iat: i64,
        iss: []const u8,
        sub: []const u8,
        azp: []const u8,
        nonce: []const u8,
        preferred_username: []const u8,
    };

    arena: std.heap.ArenaAllocator,
    message_buf: []const u8,
    message: Message,

    fn deinit(self: *JsonWebToken) void {
        self.arena.deinit();
    }

    fn parse(alloc: Allocator, rsa_params_list: []const RsaParams, jwt: []const u8) !JsonWebToken {
        var it = std.mem.splitScalar(u8, jwt, '.');
        var components: [3][]const u8 = undefined;
        for (&components, 0..) |*component, i| {
            component.* = it.next() orelse {
                std.log.err("component {d} of jwt is not present", .{i});
                return error.Invalid;
            };
        }

        if (it.next() != null) {
            std.log.err("More than 3 components in jwt", .{});
            return error.Invalid;
        }

        const header_buf = try base64UrlDecode(alloc, components[0]);
        defer alloc.free(header_buf);

        const header_parsed = try std.json.parseFromSlice(Header, alloc, header_buf, .{});
        defer header_parsed.deinit();

        const signature = try base64UrlDecode(alloc, components[2]);
        defer alloc.free(signature);

        try header_parsed.value.verify();
        const rsa_params = header_parsed.value.selectKey(rsa_params_list) orelse {
            return error.NoKey;
        };
        try JsonWebToken.verifySignature(jwt, rsa_params, signature);

        var arena = ArenaAllocator.init(alloc);
        errdefer arena.deinit();
        const arena_alloc = arena.allocator();

        const message_buf = try base64UrlDecode(arena_alloc, components[1]);
        const message = try std.json.parseFromSliceLeaky(Message, arena_alloc, message_buf, .{});

        return .{
            .arena = arena,
            .message_buf = message_buf,
            .message = message,
        };
    }

    fn makeEvpPkey(rsa_params: RsaParams) !?*c.EVP_PKEY {
        const rsa_n = c.BN_bin2bn(rsa_params.n.ptr, @intCast(rsa_params.n.len), null);
        if (rsa_n == null) {
            return error.InvalidInput;
        }
        defer c.BN_free(rsa_n);

        const rsa_e = c.BN_bin2bn(rsa_params.e.ptr, @intCast(rsa_params.e.len), null);
        if (rsa_e == null) {
            return error.InvalidInput;
        }
        defer c.BN_free(rsa_e);

        const params_builder = c.OSSL_PARAM_BLD_new();
        if (params_builder == null) {
            return error.InternalError;
        }
        defer c.OSSL_PARAM_BLD_free(params_builder);
        if (c.OSSL_PARAM_BLD_push_BN(params_builder, "n", rsa_n) != 1) {
            return error.InternalError;
        }
        if (c.OSSL_PARAM_BLD_push_BN(params_builder, "e", rsa_e) != 1) {
            return error.InternalError;
        }
        const params = c.OSSL_PARAM_BLD_to_param(params_builder);
        if (params == null) {
            return error.InternalError;
        }
        defer c.OSSL_PARAM_free(params);

        const ctx = c.EVP_PKEY_CTX_new_from_name(null, "RSA", null);
        if (ctx == null) {
            return error.InternalError;
        }
        defer c.EVP_PKEY_CTX_free(ctx);

        var pkey: ?*c.EVP_PKEY = null;
        if (c.EVP_PKEY_fromdata_init(ctx) != 1) {
            return error.InternalError;
        }
        errdefer c.EVP_PKEY_free(pkey);

        if (c.EVP_PKEY_fromdata(ctx, &pkey, c.EVP_PKEY_PUBLIC_KEY, params) != 1) {
            return error.InternalError;
        }

        return pkey;
    }

    fn verifySignature(jwt: []const u8, rsa_params: RsaParams, sig: []const u8) !void {
        const message_end = std.mem.lastIndexOfScalar(u8, jwt, '.') orelse {
            return error.InvalidData;
        };

        const message = jwt[0..message_end];

        const pkey = try makeEvpPkey(rsa_params);
        defer c.EVP_PKEY_free(pkey);

        const ctx = c.EVP_PKEY_CTX_new(pkey, null);
        defer c.EVP_PKEY_CTX_free(ctx);

        if (c.EVP_PKEY_verify_init(ctx) <= 0) {
            return error.InternalError;
        }

        if (c.EVP_PKEY_CTX_set_rsa_padding(ctx, c.RSA_PKCS1_PADDING) != 1) {
            return error.InternalError;
        }

        if (c.EVP_PKEY_CTX_set_signature_md(ctx, c.EVP_sha256()) != 1) {
            return error.InternalError;
        }

        var message_hash: [c.SHA256_DIGEST_LENGTH]u8 = undefined;
        _ = c.SHA256(message.ptr, message.len, &message_hash);

        if (c.EVP_PKEY_verify(ctx, sig.ptr, @intCast(sig.len), &message_hash, message_hash.len) != 1) {
            return error.InvalidSignature;
        }
    }
};

const Server = struct {
    alloc: Allocator,

    const index_html =
        \\<!doctype html>
        \\<head>
        \\</head>
        \\<body>
        \\  <button>Log in with twitch</button>
        \\</body>
    ;

    pub fn spawner(self: *Server) TcpServer.ConnectionSpawner {
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

    fn spawn(self: *Server, stream: std.net.Stream) !EventLoop.EventHandler {
        var http_server = try http.HttpConnection.init(self.alloc, stream, self.responseGenerator());
        return http_server.handler();
    }

    fn responseGenerator(self: *Server) http.HttpResponseGenerator {
        const generate_fn = struct {
            fn f(userdata: ?*anyopaque, conn: *http.HttpConnection) anyerror!?http.Writer {
                const self_: *Server = @ptrCast(@alignCast(userdata));
                return self_.generateResponse(conn.reader);
            }
        }.f;

        return .{
            .data = self,
            .generate_fn = generate_fn,
            .deinit_fn = null,
        };
    }

    fn generateResponse(self: *Server, reader: http.Reader) !?http.Writer {
        _ = reader;
        const response_header = http.Header{
            .status = .ok,
            .content_type = http.ContentType.@"text/html",
            .content_length = index_html.len,
        };
        return try http.Writer.init(self.alloc, response_header, index_html, false);
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const alloc = gpa.allocator();
    const id_token = "eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCIsImtpZCI6IjEifQ.eyJhdWQiOiJhaGZmbWM4bnB0dzYxa3phajF1a2dyMndtb2JldHkiLCJleHAiOjE3MTg4MzM0NDQsImlhdCI6MTcxODgzMjU0NCwiaXNzIjoiaHR0cHM6Ly9pZC50d2l0Y2gudHYvb2F1dGgyIiwic3ViIjoiNTEyMTk1NDIiLCJhenAiOiJhaGZmbWM4bnB0dzYxa3phajF1a2dyMndtb2JldHkiLCJub25jZSI6ImMzYWI4YWE2MDllYTExZTc5M2FlOTIzNjFmMDAyNjcxIiwicHJlZmVycmVkX3VzZXJuYW1lIjoic3BoYWVyb3Bob3JpYSJ9.BaJOfyG94xTUyCpYS8dKlXPR3i51PhzVQSb5bSAub1tt49jsEmieY1uCVwnxX2BmHw_vOdeipoUa1OF6uQCOuoetRtG6hgDW2e5wLMVoTABjxiHb_-3tdIeR9qScZd_bNKBee5YMt-B3p7LqyyPI_d2gtaGumAXR-tINLHB9E53qAr9lN2xbAwE-PEV57guzB0KrAjjPnHvMYjOfxbDfrKs6yOhGC27QTV6UpUnSGBsdukPp_dA2hj8qSbn_FpWS_nrrbbCDtSCFiyQhJMR1P569L5t0nG7mzEfeZAIBqZdQrLy8r9QEVoXGjuKywLhAOjqjnxByLU810GJ5WNtycg";

    const twitch_jwk =
        \\{"keys":[{"alg":"RS256","e":"AQAB","kid":"1","kty":"RSA","n":"6lq9MQ-q6hcxr7kOUp-tHlHtdcDsVLwVIw13iXUCvuDOeCi0VSuxCCUY6UmMjy53dX00ih2E4Y4UvlrmmurK0eG26b-HMNNAvCGsVXHU3RcRhVoHDaOwHwU72j7bpHn9XbP3Q3jebX6KIfNbei2MiR0Wyb8RZHE-aZhRYO8_-k9G2GycTpvc-2GBsP8VHLUKKfAs2B6sW3q3ymU6M0L-cFXkZ9fHkn9ejs-sqZPhMJxtBPBxoUIUQFTgv4VXTSv914f_YkNw-EjuwbgwXMvpyr06EyfImxHoxsZkFYB-qBYHtaMxTnFsZBr6fn8Ha2JqT1hoP7Z5r5wxDu3GQhKkHw","use":"sig"}]}
    ;

    const rsa_params = try JsonWebKeys.parse(alloc, twitch_jwk);
    defer rsa_params.deinit(alloc);

    var jwt = try JsonWebToken.parse(alloc, rsa_params.items, id_token);
    defer jwt.deinit();
    std.debug.print("{s}\n", .{jwt.message.preferred_username});

    var event_loop = try EventLoop.init(alloc);
    defer event_loop.deinit();

    var response_server = Server{
        .alloc = alloc,
    };
    const addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 8000);
    var tcp_server = try TcpServer.init(addr, response_server.spawner(), &event_loop);
    defer tcp_server.deinit();
    try event_loop.register(tcp_server.server.stream.handle, tcp_server.handler());
    try event_loop.run();
}
