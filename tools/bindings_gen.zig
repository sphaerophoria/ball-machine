const std = @import("std");
const Ast = std.zig.Ast;
const Allocator = std.mem.Allocator;

fn cTypeLookup(typ: []const u8) []const u8 {
    const ZigType = enum {
        i32,
        f32,
        void,
        bool,
    };

    const zig_typ = std.meta.stringToEnum(ZigType, typ) orelse {
        std.debug.print("Unsupported type: {s}\n", .{typ});
        return typ;
    };

    switch (zig_typ) {
        .i32 => return "int32_t",
        .f32 => return "float",
        .void => return "void",
        .bool => return "bool",
    }
}

fn indentPrint(indent: usize, comptime fmt: []const u8, args: anytype) void {
    for (0..indent) |_| {
        std.debug.print("\t", .{});
    }
    std.debug.print(fmt, args);
}

/// Walk a Zig AST, returning both when going down and when going up through a
/// node
const AstIter = struct {
    ast: *const Ast,
    root_decls: []const Ast.Node.Index,
    root_idx: usize,
    loc: std.ArrayList(NodeLoc),

    const WalkStep = enum {
        selfDown,
        left,
        right,
    };

    const NodeLoc = struct {
        idx: Ast.Node.Index,
        last_step: WalkStep,
    };

    const WalkDir = enum {
        down,
        up,
    };

    const Output = struct {
        idx: Ast.Node.Index,
        direction: WalkDir,
    };

    pub fn init(alloc: Allocator, ast: *const Ast) AstIter {
        return .{
            .ast = ast,
            .root_decls = ast.rootDecls(),
            .root_idx = 0,
            .loc = std.ArrayList(NodeLoc).init(alloc),
        };
    }

    pub fn deinit(self: *AstIter) void {
        self.loc.deinit();
    }

    fn append(self: *AstIter, idx: Ast.Node.Index) !Output {
        try self.loc.append(.{
            .idx = idx,
            .last_step = .selfDown,
        });

        return .{
            .idx = idx,
            .direction = WalkDir.down,
        };
    }

    // NOTE: When calling this externally on WalkDir.up, this will pop the
    // parent of the node that was returned. This should probably only be
    // called on WalkDir.down
    pub fn pop(self: *AstIter) Output {
        const loc = self.loc.pop();
        return .{
            .idx = loc.idx,
            .direction = WalkDir.up,
        };
    }

    pub fn next(self: *AstIter) !?Output {
        while (true) {
            if (self.loc.items.len == 0) {
                if (self.root_idx >= self.root_decls.len) {
                    return null;
                }

                defer self.root_idx += 1;
                return try self.append(self.root_decls[self.root_idx]);
            }

            const loc = &self.loc.items[self.loc.items.len - 1];
            const node = self.ast.nodes.get(loc.idx);

            switch (node.tag) {
                // Known items with lhs and rhs that are both node indices,
                // otherwise our node walking will not work correctly
                .simple_var_decl,
                .fn_decl,
                .fn_proto_multi,
                .fn_proto_simple,
                .builtin_call_two,
                .string_literal,
                .container_decl_two,
                .container_field_init,
                => {},
                else => {
                    std.log.err("Unhandled tag: {any}", .{node.tag});
                    return self.pop();
                },
            }

            switch (loc.last_step) {
                .selfDown => {
                    loc.last_step = .left;
                    if (node.data.lhs == 0) {
                        continue;
                    }

                    return try self.append(node.data.lhs);
                },
                .left => {
                    loc.last_step = .right;
                    if (node.data.rhs == 0) {
                        continue;
                    }
                    return try self.append(node.data.rhs);
                },
                .right => {
                    return self.pop();
                },
            }
        }
    }
};

/// Walk a Zig AST and extract function prototype info
const FunctionIter = struct {
    alloc: Allocator,
    inner_it: AstIter,
    namespace: std.ArrayList([]const u8),

    const FunctionParam = struct {
        ident: []const u8,
        typ: []const u8,
    };

    const FunctionProto = struct {
        alloc: Allocator,

        namespace: []const []const u8,
        name: []const u8,
        params: []const FunctionParam,
        ret: []const u8,

        fn deinit(self: *const @This()) void {
            self.alloc.free(self.params);
            self.alloc.free(self.namespace);
        }
    };

    pub fn init(alloc: Allocator, ast: *const Ast) FunctionIter {
        return .{
            .alloc = alloc,
            .inner_it = AstIter.init(alloc, ast),
            .namespace = std.ArrayList([]const u8).init(alloc),
        };
    }

    pub fn deinit(self: *FunctionIter) void {
        self.inner_it.deinit();
        self.namespace.deinit();
    }

    fn parseProto(self: *FunctionIter, idx: Ast.Node.Index) !FunctionProto {
        var buf: [1]Ast.Node.Index = undefined;
        const proto = self.inner_it.ast.fullFnProto(&buf, idx).?;
        const name = self.inner_it.ast.tokenSlice(proto.name_token.?);

        var params = try self.alloc.alloc(FunctionParam, proto.ast.params.len);
        errdefer self.alloc.free(params);

        for (proto.ast.params, 0..) |param, i| {
            const param_node = self.inner_it.ast.nodes.get(param);
            switch (param_node.tag) {
                .identifier => {
                    const param_type = self.inner_it.ast.tokenSlice(param_node.main_token);
                    const param_name = self.inner_it.ast.tokenSlice(param_node.main_token - 2);

                    params[i] = .{
                        .ident = param_name,
                        .typ = param_type,
                    };
                },
                else => {
                    std.log.err("Unhandled arg type: {any}", .{param_node.tag});
                    return error.Unimplemented;
                },
            }
        }

        const return_type = self.inner_it.ast.tokenSlice(self.inner_it.ast.nodes.get(proto.ast.return_type).main_token);
        var namespace_array_list = try self.namespace.clone();
        defer namespace_array_list.deinit();
        const namespace = try namespace_array_list.toOwnedSlice();

        return FunctionProto{
            .alloc = self.alloc,
            .namespace = namespace,
            .name = name,
            .params = params,
            .ret = return_type,
        };
    }

    fn handleDown(self: *FunctionIter, idx: Ast.Node.Index) !?FunctionProto {
        const node = self.inner_it.ast.nodes.get(idx);
        switch (node.tag) {
            .simple_var_decl => {
                const name = self.inner_it.ast.tokenSlice(node.main_token + 1);
                try self.namespace.append(name);
            },
            .fn_decl,
            .fn_proto_multi,
            .fn_proto_simple,
            => {
                const ret = try self.parseProto(idx);
                _ = self.inner_it.pop();
                return ret;
            },
            else => {},
        }
        return null;
    }

    fn handleUp(self: *FunctionIter, idx: Ast.Node.Index) !void {
        const node = self.inner_it.ast.nodes.get(idx);
        if (node.tag == .simple_var_decl) {
            _ = self.namespace.popOrNull();
        }
    }

    pub fn next(self: *FunctionIter) !?FunctionProto {
        while (try self.inner_it.next()) |item| {
            switch (item.direction) {
                .down => {
                    if (try self.handleDown(item.idx)) |proto| {
                        return proto;
                    }
                },
                .up => {
                    try self.handleUp(item.idx);
                },
            }
        }
        return null;
    }
};

fn writeCReturnType(w: std.fs.File.Writer, typ: []const u8) !void {
    const return_c_type = cTypeLookup(typ);
    try w.print("{s} ", .{return_c_type});
}

fn writeCNamespace(w: std.fs.File.Writer, namespace: []const []const u8) !void {
    for (namespace) |component| {
        try w.print("{s}_", .{component});
    }
}

fn writeCParam(w: std.fs.File.Writer, param: FunctionIter.FunctionParam) !void {
    const param_c_type = cTypeLookup(param.typ);
    try w.print("{s} {s}", .{ param_c_type, param.ident });
}

fn writeZigParam(w: std.fs.File.Writer, param: FunctionIter.FunctionParam) !void {
    try w.print("{s}: {s}", .{ param.ident, param.typ });
}

fn writeCallParam(w: std.fs.File.Writer, param: FunctionIter.FunctionParam) !void {
    try w.print("{s}", .{param.ident});
}

const ParamWriteFn = fn (std.fs.File.Writer, FunctionIter.FunctionParam) anyerror!void;
fn writeParams(w: std.fs.File.Writer, params: []const FunctionIter.FunctionParam, paramWriter: *const ParamWriteFn) !void {
    try w.writeAll("(");
    if (params.len == 0) {
        try w.writeAll(")");
        return;
    }

    try paramWriter(w, params[0]);
    for (params[1..]) |param| {
        try w.writeAll(",");
        try paramWriter(w, param);
    }

    try w.writeAll(")");
}

fn writeHeader(w: std.fs.File.Writer, proto: FunctionIter.FunctionProto) !void {
    try writeCReturnType(w, proto.ret);
    try writeCNamespace(w, proto.namespace);
    try w.writeAll(proto.name);

    try writeParams(w, proto.params, &writeCParam);
    try w.writeAll(";\n");
}

fn writeZigBody(w: std.fs.File.Writer, proto: FunctionIter.FunctionProto) !void {
    try w.writeAll(
        \\{
        \\    return inner.
    );

    for (proto.namespace) |component| {
        try w.print("{s}.", .{component});
    }
    try w.writeAll(proto.name);
    try writeParams(w, proto.params, &writeCallParam);

    try w.writeAll(
        \\;
        \\}
        \\
        \\
    );
}

fn writeImpl(w: std.fs.File.Writer, proto: FunctionIter.FunctionProto) !void {
    try w.writeAll("export fn ");
    try writeCNamespace(w, proto.namespace);
    try w.writeAll(proto.name);
    try writeParams(w, proto.params, &writeZigParam);
    try w.print(" {s} ", .{proto.ret});

    try writeZigBody(w, proto);
}

const Args = struct {
    input: []const u8,
    output_impl: []const u8,
    output_header: []const u8,
    it: std.process.ArgIterator,

    pub fn parse(alloc: Allocator) !Args {
        var it = try std.process.argsWithAllocator(alloc);
        errdefer it.deinit();
        _ = it.next();

        const input = it.next();
        const output_impl = it.next();
        const output_header = it.next();

        return .{
            .input = input orelse {
                return error.NoInput;
            },
            .output_impl = output_impl orelse {
                return error.NoOutputImpl;
            },
            .output_header = output_header orelse {
                return error.NoOutputHeader;
            },
            .it = it,
        };
    }

    pub fn deinit(self: *Args) void {
        self.it.deinit();
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const alloc = gpa.allocator();

    var args = try Args.parse(alloc);
    defer args.deinit();

    const f = try std.fs.cwd().openFile(args.input, .{});
    const content = try f.readToEndAllocOptions(alloc, 1_000_000_000, 0, 1, 0);
    defer alloc.free(content);

    var header_f = try std.fs.cwd().createFile(args.output_header, .{});
    try header_f.writeAll("#include <stdint.h>\n\n");

    var impl_f = try std.fs.cwd().createFile(args.output_impl, .{});
    try impl_f.writer().print("const inner = @import(\"{s}\");\n\n", .{args.input});

    var ast = try Ast.parse(alloc, content, .zig);
    defer ast.deinit(alloc);

    var it = FunctionIter.init(alloc, &ast);
    defer it.deinit();

    while (try it.next()) |proto| {
        defer proto.deinit();
        try writeHeader(header_f.writer(), proto);
        try writeImpl(impl_f.writer(), proto);
    }
}
