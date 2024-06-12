const std = @import("std");
const plugin_alloc = std.heap.wasm_allocator;

pub export fn alloc(size: usize, alignment: u8) ?[*]u8 {
    const alloc_size = size + @sizeOf(usize);
    const ret_w_len = plugin_alloc.rawAlloc(alloc_size, alignment, @returnAddress()) orelse {
        return null;
    };

    @memcpy(ret_w_len[0..@sizeOf(usize)], std.mem.asBytes(&alloc_size));

    const ret = ret_w_len + @sizeOf(usize);
    return ret;
}

pub fn ptrToSlice(data: [*]u8) []u8 {
    const alloced_ptr = data - @sizeOf(usize);
    var allocated_len: usize = undefined;
    @memcpy(std.mem.asBytes(&allocated_len), alloced_ptr[0..@sizeOf(usize)]);

    return data[@sizeOf(usize)..allocated_len];
}

pub export fn free(data: [*]u8) void {
    const alloced_ptr = data - @sizeOf(usize);
    var allocated_len: usize = undefined;
    @memcpy(std.mem.asBytes(&allocated_len), alloced_ptr[0..@sizeOf(usize)]);

    plugin_alloc.free(alloced_ptr[0..allocated_len]);
}

pub fn create(comptime T: type) !*T {
    return plugin_alloc.create(T);
}

pub fn destroy(p: anytype) void {
    return plugin_alloc.destroy(p);
}
