//! By convention, root.zig is the root source file when making a library.
const std = @import("std");
const Node = std.SinglyLinkedList.Node;
const Alignment = std.mem.Alignment;

const alloc_log = std.log.scoped(.allocator);

pub const MAGIC: u32 = 0xA770c0; //ALLOC0
//includes alignment padding
const HEADER_SIZE = @sizeOf(Header) + @sizeOf(usize);
const DataOffset = usize;

pub const Header = struct {
    magic: u32 = MAGIC,
    free: bool = true,
    node: Node = Node{},
    size: usize,
    data_align: Alignment,

    pub fn init(header: *Header, size: usize, alignment: Alignment) void {
        header.* = Header{
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
        self.initHeaderOffset();
    }

    pub fn next(self: *Header) ?*Header {
        if (self.node.next) |n| {
            return @fieldParentPtr("node", n);
        } else return null;
    }
    /// only reads Header.data_align and the self ptr
    fn dataPtr(self: *Header) [*]u8 {
        return @ptrFromInt(@intFromPtr(self) + self.dataOffset());
    }
    /// gets the data offset from start of header
    fn dataOffset(self: *Header) usize {
        return self.data_align.forward(@sizeOf(Header) + @sizeOf(DataOffset));
    }
    fn dataOffsetWithAlignment(alignment: Alignment) usize {
        return alignment.forward(@sizeOf(Header) + @sizeOf(DataOffset));
    }
    fn getHeaderOffset(ptr: [*]u8) *align(1) DataOffset {
        //intentionally ignore usize alignment
        return @ptrFromInt(@intFromPtr(ptr) - @sizeOf(DataOffset));
    }
    fn initHeaderOffset(header: *Header) void {
        const data_ptr = header.dataPtr();
        const offset_ptr = getHeaderOffset(data_ptr);
        offset_ptr.* = @intFromPtr(data_ptr) - @intFromPtr(header);
    }
    /// gets the capacity end address
    /// only uses `Header.next()` or buffer_end_addr
    fn getRealEndAddr(header: *Header, buffer_end_addr: usize) usize {
        return if (header.next()) |next_header|
            @intFromPtr(next_header)
        else
            buffer_end_addr;
    }
    fn totalSize(self: *Header) usize {
        return self.dataOffset() + self.size;
    }
    /// includes data capacity as well as the header
    fn totalCapacity(self: *Header, buffer_end_addr: usize) usize {
        return self.getRealEndAddr(buffer_end_addr) - @intFromPtr(self);
    }
    fn totalDataCapacity(self: *Header, buffer_end_addr: usize) usize {
        return self.getRealEndAddr(buffer_end_addr) - @intFromPtr(self.dataPtr());
    }
    pub fn join(self: *Header, buffer_end_addr: usize) bool {
        var ptr: ?*Header = self.next();
        var count: usize = 0;
        while (ptr) |header| : (ptr = header.next()) {
            if (!header.free) break;
            const total_capacity = self.totalDataCapacity(buffer_end_addr);

            self.size = total_capacity;
            self.node.next = header.node.next;
            header.magic = 0;
            count +|= 1;
        }
        self.size = self.totalDataCapacity(buffer_end_addr);
        alloc_log.debug("joined {f} {} time(s)", .{ self, count });
        return count > 0;
    }
    /// takes the header capacity and tries to insert an extra header in the unused capacity.
    /// capacity is calculated with the new requested `size`.
    /// only reads `header.data_align` and `header.node.next`.
    pub fn split(header: *Header, size: usize, buffer_end_addr: usize, default_alignment: Alignment) void {
        //also end of header data(the old one)
        const new_after_data_addr = @intFromPtr(header.dataPtr()) + size;
        const new_header: *Header = @ptrFromInt(Alignment.of(Header).forward(new_after_data_addr));
        const new_header_alignment_padding = @intFromPtr(new_header) - new_after_data_addr;

        const current_total_capacity = header.totalDataCapacity(buffer_end_addr);

        //check if we have enough space to split (add a new header and offset in unused bytes)
        const new_header_alignment: Alignment = .@"1";
        //don't align forward because we only use alignment 1
        const new_used_space = size + new_header_alignment_padding + @sizeOf(Header) + @sizeOf(DataOffset);
        if (header.totalDataCapacity(buffer_end_addr) < new_used_space) return;

        //offset from data
        const new_size = current_total_capacity - new_used_space;

        init(new_header, new_size, new_header_alignment);
        //use align(1) still
        new_header.tryRealign(default_alignment);
        header.node.insertAfter(&new_header.node);
        header.size = size;
    }
    pub fn joinAndSplit(self: *Header, size: usize, buffer_end_addr: usize, default_alignment: Alignment) void {
        var ptr: ?*Header = if (self.next()) |next_header|
            if (next_header.free) next_header else null
        else
            null;
        //find the last free header while removing the magic number
        var capacity = self.totalDataCapacity(buffer_end_addr);
        if (ptr) |next_header| capacity += next_header.totalCapacity(buffer_end_addr);
        //try to use empty space first
        if (capacity >= size) {
            self.size = size;
        }
        const last_free: ?*Header = while (ptr) |header| {
            if (header.next()) |next_header| {
                header.magic = 0;
                capacity += header.totalCapacity(buffer_end_addr);
                if (!next_header.free or capacity >= size)
                    break ptr;
                ptr = next_header;
            } else break ptr;
        } else null;
        if (last_free) |header| {
            self.node.next = header.node.next;
            self.split(size, buffer_end_addr, default_alignment);
        }
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
            alloc_log.debug("alloc {} | free {}\n", .{ requested_size, self.count_free() });
            alloc_log.debug("prealloc {f}", .{self});
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
                                alloc_log.debug("after alloc ({*}) {f}", .{ header.dataPtr(), self });
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
                            alloc_log.debug("after alloc ({*}) {f}", .{ header.dataPtr(), self });
                            return header.dataPtr();
                        }
                    }
                }
            }
            alloc_log.err("couldn't alloc :<", .{});
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
            const header: *Header = Header.fromDataPtr(memory.ptr);
            if (header.magic != MAGIC) {
                alloc_log.err("MAGIC doesn't match {}", .{header.magic});
                return false;
            }
            if (memory.len == new_len) return true;
            const buffer_end_addr = @intFromPtr(self.global_buffer.ptr) + self.global_buffer.len;
            header.joinAndSplit(new_len, buffer_end_addr, self.default_align);
            alloc_log.debug("resized to {}\n", .{new_len});
            return header.size == new_len;
        }
        fn free(ctx: *anyopaque, memory: []u8, _: Alignment, _: usize) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            const header: *Header = Header.fromDataPtr(memory.ptr);
            header.free = true;
            const buffer_end_addr = @intFromPtr(self.global_buffer.ptr) + self.global_buffer.len;
            _ = header.join(buffer_end_addr);
            alloc_log.debug("free {f}", .{header});
            alloc_log.debug("postfree {f}\n", .{self});
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
        first.init(size, .@"1");
        first.tryRealign(self.default_align);
    }
    pub fn initWithFreeMem(self: *Self, T: type, last_global: *const T) void {
        const global_end = @as([*]u8, @ptrCast(last_global)) + @sizeOf(T);
        const space_remaining = std.wasm.page_size - @intFromPtr(global_end);
        const buffer = global_end[0..space_remaining];
        self.init(buffer);
    }
    pub fn allocator(self: *Self) std.mem.Allocator {
        return self.alloc;
    }
};

test "blocks" {
    std.testing.log_level = .info;
    std.log.info("header size is {} or 0x{x} or {} with header offset\n", .{ @sizeOf(Header), @sizeOf(Header), HEADER_SIZE });

    const alignment = @alignOf(Header);

    var expected: [HEADER_SIZE * 4]u8 align(alignment) = @splat(0xAB);
    const header1 = @as(*Header, @ptrCast(@alignCast(&expected[0 * (HEADER_SIZE)])));
    const header2 = @as(*Header, @ptrCast(@alignCast(&expected[2 * (HEADER_SIZE)])));
    header1.init(HEADER_SIZE, .@"1");
    header2.init(HEADER_SIZE, .@"1");
    header1.node.next = &header2.node;
    header1.free = false;
    header2.free = false;

    const data1_bytes: [HEADER_SIZE]u8 = @splat(0xca);
    const data2_bytes: [HEADER_SIZE]u8 = @splat(0xfe);

    @memcpy(header1.dataPtr()[0..HEADER_SIZE], &data1_bytes);
    @memcpy(header2.dataPtr()[0..HEADER_SIZE], &data2_bytes);

    var buf: [HEADER_SIZE * 4]u8 align(alignment) = @splat(0xAB);
    var sa: SAlloc = undefined;
    sa.init(&buf);

    const alloc1 = try sa.alloc.alloc(u8, HEADER_SIZE);
    const alloc2 = try sa.alloc.alloc(u8, HEADER_SIZE);

    @memcpy(alloc1, &data1_bytes);
    @memcpy(alloc2, &data2_bytes);

    const alloc_header = Header.fromDataPtr(alloc1.ptr);
    alloc_header.node = header1.node;
    std.log.info("header1: {f}", .{header1});
    std.log.info("header2: {f}", .{header2});
    std.log.info("header1: {f}", .{alloc_header});
    std.log.info("header2: {f}", .{Header.fromDataPtr(alloc2.ptr)});

    try std.testing.expectEqualSlices(u8, &expected, &buf);
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
