//! By convention, root.zig is the root source file when making a library.
const std = @import("std");
const Node = std.SinglyLinkedList.Node;
const Alignment = std.mem.Alignment;

const log_alloc = std.log.scoped(.allocator);

pub const MAGIC: u32 = 0xAAAAAAAA; //ALLOC0
const DEFAULT_ALIGN = Alignment.@"4";
//includes alignment padding
const HEADER_SIZE = @sizeOf(Header);
const DEFAULT_OFFSET = HEADER_SIZE - @sizeOf(Header);
const DataOffset = usize;

pub const Header = struct {
    magic: u32 = MAGIC,
    free: bool = true,
    node: Node = Node{},
    size: usize,
    data_align: Alignment,

    pub fn init(header: *Header, node: Node, size: usize, alignment: Alignment) void {
        header.* = Header{
            .node = node,
            .size = size,
            .data_align = alignment,
        };
        header.initHeaderOffset();
    }

    /// adjusts `alignment` and adjusts `size` to match `alignment`.
    pub fn tryRealign(self: *Header, alignment: Alignment) void {
        const offset = self.dataOffset();
        const new_offset = dataOffsetWithAlignment(alignment);
        if (offset > new_offset) {
            //increase in size because less padding
            if (offset - new_offset > self.size) return;
            self.size += offset - new_offset;
        } else {
            //decrease in size because more padding
            if (new_offset - offset > self.size) return;
            self.size -= new_offset - offset;
        }
        self.data_align = alignment;
    }

    pub fn next(self: *Header) ?*Header {
        if (self.node.next) |n| {
            return @fieldParentPtr("node", n);
        } else return null;
    }
    fn dataPtr(self: *Header) [*]u8 {
        return @ptrFromInt(@intFromPtr(self) + self.dataOffset());
    }
    //from start of header
    //gets the same minimum offset for any pointer alignment possibility
    fn dataOffset(self: *Header) usize {
        return self.data_align.forward(@sizeOf(Header) + @sizeOf(DataOffset));
    }
    fn dataOffsetWithAlignment(alignment: Alignment) usize {
        return alignment.forward(@sizeOf(Header) + @sizeOf(DataOffset));
    }
    fn getHeaderOffset(ptr: [*]u8) *align(1) DataOffset {
        //intentionally ignore usize alignment
        return @ptrCast(@intFromPtr(ptr) - @sizeOf(DataOffset));
    }
    fn initHeaderOffset(header: *Header) void {
        const data_ptr = header.dataPtr();
        const offset_ptr = getHeaderOffset(data_ptr);
        offset_ptr.* = @intFromPtr(data_ptr) - @intFromPtr(header);
    }
    //includes capacity
    fn getRealEndAddr(header: *Header, buffer_end_addr: usize) usize {
        return @intFromPtr(header.next()) orelse buffer_end_addr;
    }
    fn totalSize(self: *Header) usize {
        return self.dataOffset() + self.size;
    }
    fn totalCapacity(self: *Header, buffer_end_addr: usize) usize {
        return self.dataPtr() - self.getRealEndAddr(buffer_end_addr);
    }
    pub fn join(self: *Header, buffer_end_addr: usize) bool {
        var ptr: ?*Header = self.next();
        var count: usize = 0;
        while (ptr) |header| : (ptr = header.next()) {
            if (!header.free) break;
            const total_capacity = self.getRealEndAddr(buffer_end_addr) - @intFromPtr(self.dataPtr());

            self.size = total_capacity;
            self.node.next = header.node.next;
            header.magic = 0;
            count +|= 1;
        }
        log_alloc.debug("joined {f} {} time(s)", .{ self, count });
        return count > 0;
    }
    pub fn split(header: *Header, size: usize, buffer_end_addr: usize, default_alignment: Alignment) void {
        //also end of header data(the old one)
        const new_after_data_addr = @intFromPtr(header.dataPtr()) + size;
        const new_header: *Header = @ptrFromInt(Alignment.of(Header).forward(new_after_data_addr));
        const new_header_alignment_bytes = new_after_data_addr - @intFromPtr(new_header);

        const real_end_addr: *u8 = @intFromPtr(header.next()) orelse buffer_end_addr;
        const total_len = @intFromPtr(real_end_addr) - @intFromPtr(header.dataPtr());

        //account for alignment
        const new_header_alignment: Alignment = .@"1";
        //check if we have enough space to split (add a new header in unused bytes)
        //don't align forward because we only use alignment 1
        if (real_end_addr - size < @intFromPtr(new_header + 1) + @sizeOf(DataOffset)) return;

        //offset from data
        const new_size = total_len - (size + new_header_alignment_bytes + @sizeOf(DataOffset));

        new_header.* = Header{
            .size = new_size,
            .data_align = new_header_alignment,
        };
        //use align(1) still
        new_header.initHeaderOffset();
        new_header.tryRealign(default_alignment);
        header.node.insertAfter(&new_header.node);
        header.size = size;
    }
    pub fn fromDataPtr(ptr: [*]u8) *Header {
        return @ptrFromInt(@intFromPtr(ptr) - getHeaderOffset(ptr).*);
    }

    fn dataSizeWithAlignment(self: *Header, alignment: Alignment) ?usize {
        const offset = self.dataOffset();
        const end = offset + self.size;
        const new_offset = dataOffsetWithAlignment(alignment);
        if (end < new_offset) return null;
        return end - new_offset;
    }
    pub fn format(header: *Header, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("Block(align({}))({*})({X}){{ free:{}, size:0x{x}, align:{}, data offset:0x{x}/{} }}", .{
            @alignOf(Header),
            header,
            header.magic,
            header.free,
            header.size,
            header.data_align.toByteUnits(),
            header.dataOffset(),
            header.dataOffset(),
        });
    }
};

pub const SAlloc = struct {
    const Self = @This();
    global_buffer: []u8,
    alloc: std.mem.Allocator,
    default_align: Alignment = .@"1",

    const vtable = struct {
        fn alloc(ctx: *anyopaque, requested_size: usize, alignment: std.mem.Alignment, _: usize) ?[*]u8 {
            const self: *Self = @ptrCast(@alignCast(ctx));
            log_alloc.debug("alloc {} | free {}\n", .{ requested_size, self.count_free() });
            log_alloc.debug("prealloc {f}", .{self});
            const buffer_end_addr = @intFromPtr(self.global_buffer.ptr) + self.global_buffer.len;
            //find first free big enough
            //and adjust alignment
            var h: ?*Header = self.getFirst();
            while (h) |header| : (h = header.next()) {
                if (header.free) {
                    _ = header.join(buffer_end_addr);
                    if (header.data_align != alignment) {
                        if (header.dataSizeWithAlignment(alignment)) |new_size| {
                            if (new_size >= requested_size) {
                                header.free = false;
                                header.tryRealign(alignment);
                                header.split(requested_size, buffer_end_addr, self.default_align);
                                log_alloc.debug("after alloc ({*}) {f}", .{ header.dataPtr(), self });
                                return header.dataPtr();
                            }
                        }
                        //fails if this block has a small size and align but a big align is requested
                        continue;
                    } else {
                        //equal alignment
                        if (header.size >= requested_size) {
                            header.split(requested_size, buffer_end_addr, self.default_align);
                            header.free = false;
                            log_alloc.debug("after alloc ({*}) {f}", .{ header.dataPtr(), self });
                            return header.dataPtr();
                        }
                    }
                }
            }
            log_alloc.err("couldn't alloc :<", .{});
            return null;
        }
        fn remap(
            context: *anyopaque,
            memory: []u8,
            alignment: Alignment,
            new_len: usize,
            return_address: usize,
        ) ?[*]u8 {
            return if (resize(context, memory, alignment, new_len, return_address)) memory.ptr else null;
        }
        //attempt or shrink or expand memory in-place
        fn resize(ctx: *anyopaque, memory: []u8, _: std.mem.Alignment, new_len: usize, _: usize) bool {
            const self: *Self = @ptrCast(@alignCast(ctx));
            const header: *Header = self.header_from_memory(memory).?;
            if (header.magic != MAGIC) {
                log_alloc.err("MAGIC doesn't match {}", .{header.magic});
                return false;
            }
            if (memory.len == new_len) return true;
            const buffer_end_addr = @intFromPtr(self.global_buffer.ptr) + self.global_buffer.len;
            header.join(buffer_end_addr);
            log_alloc.debug("grow to {}\n", .{new_len});
            header.split(new_len);
            log_alloc.debug("shrink to {}\n", .{new_len});
            return header.size == new_len;
        }
        fn free(ctx: *anyopaque, memory: []u8, _: Alignment, _: usize) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            const header: *Header = Header.fromDataPtr(memory.ptr);
            header.free = true;
            _ = header.join();
            log_alloc.debug("free {f}", .{header});
            log_alloc.debug("postfree {f}\n", .{self});
        }
    };

    fn getFirst(self: *Self) *Header {
        return @ptrFromInt(Alignment.of(Header).forward(@intFromPtr(self.global_buffer.ptr)));
    }
    pub fn count_free(self: *Self) usize {
        var free: usize = 0;
        var h: ?*Header = self.getFirst();
        while (h) |header| : (h = header.next()) {
            if (header.free) free += header.size;
        }
        return free;
    }
    pub fn format(self: *Self, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("SAlloc{{ free:{}, buffer({*}).len:{}\nHeaders:\n", .{ self.count_free(), self.global_buffer.ptr, self.global_buffer.len });
        var h: ?*Header = self.getFirst();
        while (h) |header| : (h = header.next()) {
            try writer.print("\t{f},\n", .{header});
        }
        try writer.print("}}", .{});
    }
    pub fn init(self: *Self, buffer: []u8) void {
        self.* = Self{
            .alloc = .{ .ptr = self, .vtable = &std.mem.Allocator.VTable{
                .alloc = vtable.alloc,
                .free = vtable.free,
                .remap = vtable.remap,
                .resize = vtable.resize,
            } },
            .global_buffer = buffer,
        };
        const first: *Header = self.getFirst();
        const buffer_end = @intFromPtr(self.global_buffer.ptr) + self.global_buffer.len;
        const size = buffer_end - (@intFromPtr(first) + HEADER_SIZE);
        first.* = Header{
            .size = size,
            .data_align = .@"1",
            .free = true,
        };
        first.tryRealign(DEFAULT_ALIGN);
    }
    pub fn allocator(self: *Self) std.mem.Allocator {
        return self.alloc;
    }
};

test "blocks" {
    // std.testing.log_level = .debug;
    std.debug.print("header size is {} or 0x{x} or {} w default alignment\n", .{ @sizeOf(Header), @sizeOf(Header), HEADER_SIZE });

    var buf: [HEADER_SIZE * 4]u8 align(@alignOf(Header)) = undefined;
    std.debug.print("size of buf is {0} or 0x{0x}\n", .{buf.len});
    var s: SAlloc = undefined;
    s.init(&buf);
    var expected: [HEADER_SIZE * 4]u8 align(@alignOf(Header)) = undefined;
    const header1 = @as(*Header, @ptrCast(@alignCast(&expected[0 * (HEADER_SIZE)])));
    const header2 = @as(*Header, @ptrCast(@alignCast(&expected[2 * (HEADER_SIZE)])));
    header1.* =
        Header{
            .data_align = .@"1",
            .free = false,
            .size = HEADER_SIZE,
        };
    const data1 = expected[HEADER_SIZE * 1 .. HEADER_SIZE * 2];
    for (0..HEADER_SIZE) |i| {
        data1[i] = 0xbe;
    }
    header2.* =
        Header{
            .data_align = .@"1",
            .free = false,
            .size = HEADER_SIZE,
        };
    const data2 = expected[HEADER_SIZE * 3 .. HEADER_SIZE * 4];
    for (0..HEADER_SIZE) |i| {
        data2[i] = 0xef;
    }
    std.debug.print("expected \n{f}{f}", .{ header1, header2 });
    std.debug.print("before\n{f}\n", .{&s});
    const alloc = s.allocator();
    const first = try alloc.alignedAlloc(u8, .@"1", HEADER_SIZE);
    try std.testing.expectEqual(@intFromPtr(first.ptr), @intFromPtr(&buf[0]) + HEADER_SIZE);
    for (0..HEADER_SIZE) |i| {
        first[i] = 0xbe;
    }
    std.debug.print("after first alloc\n{f}\n", .{&s});

    const second = try alloc.alignedAlloc(u8, .@"1", HEADER_SIZE);
    for (0..HEADER_SIZE) |i| {
        second[i] = 0xef;
    }
    std.debug.print("final\n{f}\n", .{&s});
    const expected_bytes: []u8 align(@alignOf(Header)) = @ptrCast(&expected);

    const buf_header1 = @as(*Header, @ptrCast(@alignCast(&buf[0 * HEADER_SIZE])));
    std.debug.print("buf_header1 {f}", .{buf_header1});
    // const buf_header2 = @as(*Header, @ptrCast(@alignCast(&buf[2 * HEADER_SIZE])));
    // std.debug.print("buf_header2 {f}", .{buf_header2});

    // const copy1 = header1.*;
    // const copy2 = header2.*;
    // const buf_copy1 = buf_header1.*;
    // const buf_copy2 = buf_header2.*;
    // try std.testing.expectEqual(copy1, buf_copy1);
    // try std.testing.expectEqual(copy2, buf_copy2);
    buf_header1.node.next = null;
    try std.testing.expectEqualSlices(u8, expected_bytes, &buf);
}

test "salloc" {
    var buf: [1024]u8 = undefined;
    var s: SAlloc = undefined;
    s.init(&buf);
}
test "salloc1" {
    var buf: [1024]u8 = undefined;
    var s: SAlloc = undefined;
    s.init(&buf);
    const alloc = s.alloc;
    const first = try alloc.alloc(u8, 2);
    alloc.free(first);
}
test "salloc basic" {
    var buf: [1024]u8 = undefined;
    var s: SAlloc = undefined;
    s.init(&buf);
    const alloc = s.alloc;
    const first = try alloc.alloc(u8, 2);
    first[0] = 0xde;
    first[1] = 0xad;
    const second = try alloc.alloc(u8, 33);
    alloc.free(second);
    try std.testing.expectEqual(0xde, first[0]);
    try std.testing.expectEqual(0xad, first[1]);
    const third = try alloc.alloc(u32, 5);
    third[2] = 12345;
    alloc.free(first);
    try std.testing.expectEqual(12345, third[2]);
    alloc.free(third);
}
test "alignment" {
    // const testing_alloc = std.testing.allocator;
    // var list: std.ArrayList(*u8) = .empty;
    // errdefer {
    //     for (list.items) |ptr| {
    //         testing_alloc.free(ptr);
    //     }
    // }

    // var have_unaligned = false;
    // const alignment = Alignment.fromByteUnits(@sizeOf(usize));
    // while (!have_unaligned) {
    //     const ptr = try testing_alloc.create(u8);
    //     if (std.mem.isAligned(@intFromPtr(ptr), alignment));
    // }
}
