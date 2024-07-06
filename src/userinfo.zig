const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const http = @import("http.zig");
const c = @import("c.zig");
const Db = @import("Db.zig");

const AuthResponse = struct {
    id_token: []const u8,
};

pub const RsaParams = struct {
    kid: []const u8,
    n: []const u8,
    e: []const u8,

    pub fn deinit(self: *const RsaParams, alloc: Allocator) void {
        alloc.free(self.kid);
        alloc.free(self.n);
        alloc.free(self.e);
    }
};

pub const RsaParamsList = struct {
    items: []RsaParams,

    pub fn deinit(self: *const RsaParamsList, alloc: Allocator) void {
        for (self.items) |elem| {
            elem.deinit(alloc);
        }
        alloc.free(self.items);
    }
};

pub const JsonWebKeys = struct {
    keys: []JsonWebKey,

    pub fn parse(alloc: Allocator, jwk: []const u8) !RsaParamsList {
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
        // client id
        aud: []const u8,
        // expiry time
        exp: i64,
        // issue time
        iat: i64,
        // issuer url
        iss: []const u8,
        // user id
        sub: []const u8,
        // client id
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

pub const Authentication = struct {
    const session_id_len = 32;
    const SessionId = [session_id_len]u8;
    const SessionCookie = [std.base64.url_safe.Encoder.calcSize(session_id_len)]u8;

    alloc: Allocator,
    jwt_keys: []const RsaParams,
    server_url: []const u8,
    rng: std.rand.DefaultCsprng,
    db: *Db,

    pub fn init(alloc: Allocator, server_url: []const u8, jwt_keys: []const RsaParams, db: *Db) !Authentication {
        var seed: [std.rand.DefaultCsprng.secret_seed_length]u8 = undefined;
        try std.posix.getrandom(&seed);
        const rng = std.rand.DefaultCsprng.init(seed);

        return .{
            .alloc = alloc,
            .jwt_keys = jwt_keys,
            .server_url = server_url,
            .rng = rng,
            .db = db,
        };
    }

    const nonce_size = std.base64.url_safe.Encoder.calcSize(
        std.crypto.hash.sha2.Sha256.digest_length,
    );

    fn nonceFromNumber(num: u64) [nonce_size]u8 {
        const Sha256 = std.crypto.hash.sha2.Sha256;
        var hashed_val: [Sha256.digest_length]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(std.mem.asBytes(&num), &hashed_val, .{});

        var base64_encoded: [nonce_size]u8 = undefined;
        _ = std.base64.url_safe.Encoder.encode(&base64_encoded, &hashed_val);

        return base64_encoded;
    }

    const nonce_cookie_key = "nonce_unhashed";

    fn nonceFromCookie(header_buf: []const u8) ![nonce_size]u8 {
        var cookie_it = http.CookieIt.init(header_buf);
        var cookie_val_opt: ?u64 = null;
        while (cookie_it.next()) |cookie| {
            if (std.mem.eql(u8, cookie.key, nonce_cookie_key)) {
                cookie_val_opt = try std.fmt.parseInt(u64, cookie.val, 10);
                break;
            }
        }

        const cookie_val = cookie_val_opt orelse {
            return error.NoCookie;
        };

        return nonceFromNumber(cookie_val);
    }

    pub const session_cookie_key = "session_id";

    fn sessionIdFromHeader(header_buf: []const u8) !SessionId {
        // FIXME: dedup with nonceFromCookie
        var cookie_it = http.CookieIt.init(header_buf);
        var cookie_val_opt: ?[]const u8 = null;
        while (cookie_it.next()) |cookie| {
            if (std.mem.eql(u8, cookie.key, session_cookie_key)) {
                cookie_val_opt = cookie.val;
                break;
            }
        }

        const cookie_val = cookie_val_opt orelse {
            return error.NoCookie;
        };

        const decoded_len = try std.base64.url_safe.Decoder.calcSizeForSlice(cookie_val);
        if (decoded_len != session_id_len) {
            return error.InvalidSessionId;
        }

        var ret: SessionId = undefined;
        try std.base64.url_safe.Decoder.decode(&ret, cookie_val);

        return ret;
    }

    pub fn makeTwitchRedirect(self: *Authentication, client_id: []const u8) !http.Writer {
        const login_cookie = self.rng.random().int(u64);
        const base64_encoded = nonceFromNumber(login_cookie);

        var redirect_buf: [2048]u8 = undefined;
        const redirect_loc = try std.fmt.bufPrint(
            &redirect_buf,
            "https://id.twitch.tv/oauth2/authorize" ++
                "?response_type=code" ++
                "&client_id={s}" ++
                "&redirect_uri={s}/login_code&" ++
                "scope=openid&state={s}" ++
                "&nonce={s}",
            .{ client_id, self.server_url, base64_encoded, base64_encoded },
        );

        var set_cookie_buf: [100]u8 = undefined;
        const set_cookie_val = std.fmt.bufPrint(
            &set_cookie_buf,
            "{s}={d}; HttpOnly",
            .{ nonce_cookie_key, login_cookie },
        ) catch {
            @panic("cookie buf length too low");
        };

        const header = http.Header{
            .content_type = .@"text/html",
            .status = std.http.Status.see_other,
            .content_length = 0,
            .extra = &.{ .{
                .key = "Location",
                .value = redirect_loc,
            }, .{
                .key = "Set-Cookie",
                .value = set_cookie_val,
            } },
        };

        return try http.Writer.init(self.alloc, header, "", false);
    }

    pub fn validateAuthResponse(
        self: *Authentication,
        response: []const u8,
        header_buf: []const u8,
    ) !SessionCookie {
        const expected_nonce = try Authentication.nonceFromCookie(header_buf);

        const parsed = try std.json.parseFromSlice(AuthResponse, self.alloc, response, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();

        var jwt = try JsonWebToken.parse(self.alloc, self.jwt_keys, parsed.value.id_token);
        defer jwt.deinit();

        if (!std.mem.eql(u8, &expected_nonce, jwt.message.nonce)) {
            return error.InvalidResponse;
        }

        const id = try self.db.addUser(
            jwt.message.sub,
            jwt.message.preferred_username,
            jwt.message.iat,
            jwt.message.exp,
        );

        var session_id: SessionId = undefined;
        self.rng.random().bytes(&session_id);

        // FIXME: if session id is already set, remove the old session id from
        // the db
        //
        // FIXME: cap the number of session ids for a user
        try self.db.addSessionId(id, &session_id);

        var cookie: SessionCookie = undefined;
        _ = std.base64.url_safe.Encoder.encode(&cookie, &session_id);
        return cookie;
    }

    pub fn userForRequest(self: *Authentication, alloc: Allocator, header_buf: []const u8) !?Db.UserInfo {
        const session_id = sessionIdFromHeader(header_buf) catch {
            return null;
        };

        return try self.db.userFromSessionId(alloc, &session_id);
    }
};
