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

pub const Header = struct {
    magic: u32 = MAGIC,
    free: bool = true,
    node: Node = Node{},
    size: usize,
    data_align: Alignment,

    /// adjusts `alignment` and adjusts `size` to match `alignment`.
    pub fn try_realign(self: *Header, alignment: Alignment) void {
        const offset = self.data_offset();
        const new_offset = self.data_offset_align(alignment);
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
    fn data_ptr(self: *Header) [*]u8 {
        return @ptrFromInt(@intFromPtr(self) + self.data_offset());
    }
    //from start of header
    fn data_offset(self: *Header) usize {
        return self.data_align.forward(@sizeOf(Header));
    }
    fn total_size(self: *Header) usize {
        return self.data_offset() + self.size;
    }
    pub fn join(self: *Header) bool {
        var ptr: ?*Header = self.next();
        var count: usize = 0;
        while (ptr) |header| : (ptr = header.next()) {
            if (!header.free) break;
            //account for padding
            self.size += (@intFromPtr(header) - (@intFromPtr(self.data_ptr()) + self.size)) + header.total_size();
            self.node.next = header.node.next;
            header.magic = 0;
            count += 1;
        }
        log_alloc.debug("joined {f} {} time(s)", .{ self, count });
        return count > 0;
    }
    pub fn split(header: *Header, size: usize) void {
        //also end of header data(the old one)
        const new_header: *Header = @ptrFromInt(Alignment.of(Header).forward(@intFromPtr(header.data_ptr()) + size));
        //account for alignmentZ
        if (@intFromPtr(header.data_ptr()) + header.size < @intFromPtr(new_header) + @sizeOf(Header)) return;
        //how far from start of original_header.data
        const new_header_off = @intFromPtr(new_header) - @intFromPtr(header.data_ptr());
        const new_size = header.size - new_header_off - @sizeOf(Header);

        new_header.* = Header{
            .size = new_size,
            .data_align = .@"1",
        };
        new_header.try_realign(DEFAULT_ALIGN);
        header.node.insertAfter(&new_header.node);
        header.size = size;
    }
    fn data_offset_align(self: *Header, alignment: Alignment) usize {
        _ = self;
        return alignment.forward(@sizeOf(Header));
    }
    fn data_size_with_alignment(self: *Header, alignment: Alignment) ?usize {
        const offset = self.data_offset();
        const end = offset + self.size;
        const new_offset = self.data_offset_align(alignment);
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
            header.data_offset(),
            header.data_offset(),
        });
    }
};

pub const SAlloc = struct {
    const Self = @This();
    global_buffer: []u8,
    alloc: std.mem.Allocator,

    const vtable = struct {
        fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, _: usize) ?[*]u8 {
            const self: *Self = @ptrCast(@alignCast(ctx));
            log_alloc.debug("alloc {} | free {}\n", .{ len, self.count_free() });
            log_alloc.debug("prealloc {f}", .{self});
            //find first free big enough
            //and adjust alignment
            var h: ?*Header = self.get_first();
            while (h) |header| : (h = header.next()) {
                if (header.free) {
                    _ = header.join();
                    if (header.data_align != alignment) {
                        if (header.data_size_with_alignment(alignment)) |new_size| {
                            if (new_size >= len) {
                                header.free = false;
                                header.try_realign(alignment);
                                header.split(len);
                                log_alloc.debug("after alloc ({*}) {f}", .{ header.data_ptr(), self });
                                return header.data_ptr();
                            }
                        }
                        //fails if this block has a small size and align but a big align is requested
                        continue;
                    } else {
                        //equal alignment
                        if (header.size >= len) {
                            header.split(len);
                            header.free = false;
                            log_alloc.debug("after alloc ({*}) {f}", .{ header.data_ptr(), self });
                            return header.data_ptr();
                        }
                    }
                }
            }
            log_alloc.debug("couldn't alloc :<", .{});
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
            log_alloc.debug("preresize {f}\n", .{self});
            if (memory.len == new_len) return true;
            if (header.next()) |next| {
                if (new_len > memory.len) {
                    if (next.free and next.total_size() + (@intFromPtr(next) - @intFromPtr(header.data_ptr())) >= new_len) {
                        log_alloc.debug("grow to {}\n", .{new_len});
                        const result = header.join();
                        _ = result;
                        header.split(new_len);
                        if (header.size != new_len) {
                            log_alloc.debug("couldn't resize ig\n", .{});
                        }
                        log_alloc.debug("postresize {f}\n", .{self});
                        return header.size == new_len;
                    }
                } else {
                    //shrink
                    log_alloc.debug("shrink to {}\n", .{new_len});
                    //must be able to move next block
                    if (!next.free) return false;
                    const diff = header.size - new_len;
                    const offset = next.data_offset();
                    const old_size = next.size;
                    const old_next = next.node;
                    const new_end: *Header = @ptrFromInt(Alignment.of(Header).forward(header.data_offset() + new_len));
                    new_end.* = Header{
                        .node = old_next,
                        .size = diff + offset + old_size,
                        .data_align = Alignment.@"1", //make calculation easier
                    };
                    new_end.try_realign(DEFAULT_ALIGN);
                    header.node.next = &new_end.node;
                    return true;
                }
            }
            return false;
        }
        fn free(ctx: *anyopaque, memory: []u8, _: Alignment, _: usize) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            const header: *Header = self.header_from_memory(memory).?;
            header.free = true;
            _ = header.join();
            log_alloc.debug("free {f}", .{header});
            log_alloc.debug("postfree {f}\n", .{self});
        }
    };

    pub fn header_from_memory(self: *Self, memory: []u8) ?*Header {
        var header_ptr: ?*Header = self.get_first();
        while (header_ptr) |header| : (header_ptr = header.next()) {
            if (header.data_ptr() == memory.ptr) return header;
        }
        return null;
    }
    fn get_first(self: *Self) *Header {
        return @ptrFromInt(Alignment.of(Header).forward(@intFromPtr(self.global_buffer.ptr)));
    }
    pub fn count_free(self: *Self) usize {
        var free: usize = 0;
        var h: ?*Header = self.get_first();
        while (h) |header| : (h = header.next()) {
            if (header.free) free += header.size;
        }
        return free;
    }
    pub fn format(self: *Self, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("SAlloc{{ free:{}, buffer({*}).len:{}\nHeaders:\n", .{ self.count_free(), self.global_buffer.ptr, self.global_buffer.len });
        var h: ?*Header = self.get_first();
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
        const first: *Header = self.get_first();
        const buffer_end = @intFromPtr(self.global_buffer.ptr) + self.global_buffer.len;
        const size = buffer_end - (@intFromPtr(first) + HEADER_SIZE);
        first.* = Header{
            .size = size,
            .data_align = .@"1",
            .free = true,
        };
        first.try_realign(DEFAULT_ALIGN);
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
