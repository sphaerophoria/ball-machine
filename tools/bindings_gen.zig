const std = @import("std");
const Ast = std.zig.Ast;
const Allocator = std.mem.Allocator;

const ZigType = enum {
    i32,
    f32,
    void,
    bool,
};

//    library_types: std.StringHashMap(Ast.Node.Index),
//
//    fn isBuiltin(typ: []const u8) bool {
//        return std.meta.stringToEnum(ZigType, typ) != null;
//    }
//
//    fn needsSerialization(self: *const TypeLookup, typ: []const u8) bool {
//        return self.library_types.get(typ) != null;
//    }
//};

fn cTypeLookup(typ: []const u8) []const u8 {
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

    const NodeLoc = struct {
        idx: Ast.Node.Index,
        // 0 self, 1..n, n
        // node.children.len + 1
        last_step: u32,
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
            .last_step = 0,
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

    fn resolveChildNodeId(self: *AstIter, node_idx: Ast.Node.Index, num_children_walked: u32) ?Ast.Node.Index {
        const node = self.ast.nodes.get(node_idx);
        switch (node.tag) {
            .simple_var_decl,
            .fn_decl,
            .fn_proto_multi,
            .fn_proto_simple,
            .builtin_call_two,
            .string_literal,
            .container_decl_two,
            .container_field_init,
            .block_two_semicolon,
            .identifier,
            => {
                switch (num_children_walked) {
                    0 => return node.data.lhs,
                    1 => return node.data.rhs,
                    else => return null,
                }
            },
            .container_decl => {
                const idx = node.data.lhs + num_children_walked;
                if (idx >= node.data.rhs) {
                    return null;
                }
                return self.ast.extra_data[idx];
            },
            else => {
                std.log.err("Unhandled tag: {any}", .{node.tag});
                return null;
            },
        }
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

            while (self.resolveChildNodeId(loc.idx, loc.last_step)) |node_idx| {
                defer loc.last_step += 1;
                if (node_idx == 0) {
                    continue;
                }
                return try self.append(node_idx);
            }

            return self.pop();
        }
    }
};

const FnParamType = struct {
    pointer_level: u8,
    val: []const u8,
};

fn resolveFnParamType(ast: *const Ast, node_idx: Ast.Node.Index) FnParamType {
    const node = ast.nodes.get(node_idx);
    switch (node.tag) {
        .identifier => {
            const val = ast.tokenSlice(node.main_token);
            return .{
                .pointer_level = 0,
                .val = val,
            };
        },
        .ptr_type_aligned => {
            const pointer_info = ast.ptrTypeAligned(node_idx);
            var ret = resolveFnParamType(ast, pointer_info.ast.child_type);
            ret.pointer_level += 1;
            return ret;
        },
        else => {
            @panic("Unimplemented");
        },
    }
}

/// Walk a Zig AST and extract function prototype info
const FunctionIter = struct {
    alloc: Allocator,
    inner_it: AstIter,
    namespace: std.ArrayList([]const u8),

    const FunctionParam = struct {
        ident: []const u8,
        typ: FnParamType,
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

        var params = std.ArrayList(FunctionParam).init(self.alloc);
        errdefer params.deinit();

        var param_it = proto.iterate(self.inner_it.ast);
        var i: usize = 0;
        while (param_it.next()) |param| {
            defer i += 1;
            const name_token_idx = param.name_token orelse {
                std.log.err("Unhandled unnamed param", .{});
                continue;
            };
            const param_name = self.inner_it.ast.tokenSlice(name_token_idx);
            const param_type_node = self.inner_it.ast.nodes.get(param.type_expr);
            std.debug.print("node: {any}\n", .{param_type_node.tag});

            const param_type = resolveFnParamType(self.inner_it.ast, param.type_expr);

            try params.append(.{
                .ident = param_name,
                .typ = param_type,
            });
        }

        const return_type = self.inner_it.ast.tokenSlice(self.inner_it.ast.nodes.get(proto.ast.return_type).main_token);
        var namespace_array_list = try self.namespace.clone();
        defer namespace_array_list.deinit();
        const namespace = try namespace_array_list.toOwnedSlice();

        const params_slice = try params.toOwnedSlice();

        return FunctionProto{
            .alloc = self.alloc,
            .namespace = namespace,
            .name = name,
            .params = params_slice,
            .ret = return_type,
        };
    }

    fn handleDown(self: *FunctionIter, idx: Ast.Node.Index) !?FunctionProto {
        const node = self.inner_it.ast.nodes.get(idx);
        std.debug.print("{any}\n", .{node.tag});
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

fn writeCParam(w: std.fs.File.Writer, param: FunctionIter.FunctionParam, types: []const TypeIndex) !void {
    _ = types;
    const param_c_type = cTypeLookup(param.typ.val);
    try w.writeAll(param_c_type);
    try w.writeByteNTimes('*', param.typ.pointer_level);
    try w.print(" {s}", .{param.ident});
}

fn writeZigParam(w: std.fs.File.Writer, param: FunctionIter.FunctionParam, types: []const TypeIndex) !void {
    try w.print("{s}: ", .{param.ident});
    try w.writeBytesNTimes("[*c]", param.typ.pointer_level);
    if (typesContainsName(types, param.typ.val)) {
        try w.print("inner.{s}", .{param.typ.val});
    } else {
        try w.print("{s}", .{param.typ.val});
    }
}

fn typesContainsName(types: []const TypeIndex, name: []const u8) bool {
    for (types) |typ| {
        if (std.mem.eql(u8, typ.name, name)) {
            return true;
        }
    }
    return false;
}

fn writeCallParam(w: std.fs.File.Writer, param: FunctionIter.FunctionParam, types: []const TypeIndex) !void {
    _ = types;
    try w.print("{s}", .{param.ident});
}

const ParamWriteFn = fn (std.fs.File.Writer, FunctionIter.FunctionParam, types: []const TypeIndex) anyerror!void;
fn writeParams(w: std.fs.File.Writer, params: []const FunctionIter.FunctionParam, types: []const TypeIndex, paramWriter: *const ParamWriteFn) !void {
    try w.writeAll("(");
    if (params.len == 0) {
        try w.writeAll(")");
        return;
    }

    try paramWriter(w, params[0], types);
    for (params[1..]) |param| {
        try w.writeAll(",");
        try paramWriter(w, param, types);
    }

    try w.writeAll(")");
}

fn writeHeader(w: std.fs.File.Writer, proto: FunctionIter.FunctionProto) !void {
    try writeCReturnType(w, proto.ret);
    try writeCNamespace(w, proto.namespace);
    try w.writeAll(proto.name);

    try writeParams(w, proto.params, &.{}, &writeCParam);
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
    try writeParams(w, proto.params, &.{}, &writeCallParam);

    try w.writeAll(
        \\;
        \\}
        \\
        \\
    );
}

fn writeImpl(w: std.fs.File.Writer, proto: FunctionIter.FunctionProto, types: []const TypeIndex) !void {
    try w.writeAll("export fn ");
    try writeCNamespace(w, proto.namespace);
    try w.writeAll(proto.name);
    try writeParams(w, proto.params, types, &writeZigParam);
    if (typesContainsName(types, proto.ret)) {
        try w.print(" inner.{s} ", .{proto.ret});
    } else {
        try w.print(" {s} ", .{proto.ret});
    }

    try writeZigBody(w, proto);
}

const FunctionLoc = struct {
    namespace: []const u8,
    node_idx: Ast.Node.Index,
};

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

fn isContainer(ast: *const Ast, node_idx: Ast.Node.Index) bool {
    const tag = ast.nodes.items(.tag)[node_idx];
    switch (tag) {
        .container_decl,
        .container_decl_trailing,
        .container_decl_two,
        .container_decl_two_trailing,
        .container_decl_arg,
        .container_decl_arg_trailing,
        => return true,
        else => return false,
    }
}

const TypeIndex = struct {
    name: []const u8,
    idx: Ast.Node.Index,
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

    var ast_it = AstIter.init(alloc, &ast);
    defer ast_it.deinit();

    //var function_locations = std.ArrayList(FunctionLoc).init(alloc);
    var type_indices = std.ArrayList(TypeIndex).init(alloc);
    defer type_indices.deinit();

    while (try ast_it.next()) |val| {
        if (val.direction != .down) {
            continue;
        }

        const tag = ast.nodes.items(.tag)[val.idx];
        if (tag == .simple_var_decl) {
            const decl = ast.simpleVarDecl(val.idx);
            const name = ast.tokenSlice(decl.ast.mut_token + 1);
            if (isContainer(&ast, decl.ast.init_node)) {
                try type_indices.append(.{ .name = name, .idx = decl.ast.init_node });
            }
        }
    }

    const header_writer = header_f.writer();
    for (type_indices.items) |item| {
        var buf: [2]Ast.Node.Index = undefined;
        const decl: Ast.full.ContainerDecl = ast.fullContainerDecl(&buf, item.idx).?;

        try header_writer.writeAll("typedef struct {\n");

        for (decl.ast.members) |member_idx| {
            const member_tag = ast.nodes.items(.tag)[member_idx];
            if (member_tag != .container_field_init) {
                continue;
            }

            const container_field_init = ast.containerFieldInit(member_idx);
            const member_ident = ast.tokenSlice(container_field_init.ast.main_token);
            std.debug.print("container field: {s}\n", .{ast.tokenSlice(container_field_init.ast.main_token)});
            const typ = resolveFnParamType(&ast, container_field_init.ast.type_expr);
            try header_writer.writeAll("\t");
            try writeCParam(header_writer, .{
                .ident = member_ident,
                .typ = typ,
            }, type_indices.items);
            try header_writer.writeAll(";\n");
            std.debug.print("{d}, {s}\n", .{ typ.pointer_level, typ.val });
        }

        try header_writer.print("}} {s};\n", .{item.name});
        std.debug.print("{s}: {d}\n", .{ item.name, decl.ast.members.len });
    }

    var it = FunctionIter.init(alloc, &ast);
    defer it.deinit();

    while (try it.next()) |proto| {
        defer proto.deinit();
        try writeHeader(header_f.writer(), proto);
        try writeImpl(impl_f.writer(), proto, type_indices.items);
    }
}
