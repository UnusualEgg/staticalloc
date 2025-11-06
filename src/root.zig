//! By convention, root.zig is the root source file when making a library.
const std = @import("std");
const Node = std.SinglyLinkedList.Node;
const Alignment = std.mem.Alignment;

pub fn SAlloc(comptime bufsize: usize) type {
    return struct {
        const Self = @This();
        global_buffer: [bufsize]u8,
        alloc: std.mem.Allocator,
        const MAGIC: u32 = 0xA110C0; //ALLOC0

        const vtable = struct {
            fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, _: usize) ?[*]u8 {
                const self: *Self = @ptrCast(@alignCast(ctx));
                //find first free big enough
                //and adjust alignment
                var h: ?*Header = self.get_first();
                while (h) |header| : (h = header.next()) {
                    if (header.free) {
                        //TODO header.join();
                        if (header.data_align != alignment) {
                            if (header.data_size_with_alignment(alignment)) |new_size| {
                                if (new_size >= len) {
                                    header.data_align = alignment;
                                    header.split(len);
                                    return header;
                                }
                            }
                            //fails if this block has a small size and align but a big align is requested
                            continue;
                        } else {
                            //equal alignment
                            if (header.size >= len) {
                                header.split(len);
                                return header.data_ptr();
                            }
                        }
                    }
                }
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
            fn resize(_: *anyopaque, memory: []u8, _: std.mem.Alignment, new_len: usize, _: usize) bool {
                const header: *Header = Header.from_memory(memory);
                if (header.magic != MAGIC) {
                    std.log.err("MAGIC doesn't match {}", .{header.magic});
                    return false;
                }
                if (memory.len == new_len) return true;
                if (header.next()) |next| {
                    if (new_len > memory.len) {
                        if (next.free and next.total_size() + header.size >= new_len) {
                            return header.join();
                        }
                    } else {
                        //shrink
                        //must be able to move next block
                        if (!next.free) return false;
                        const diff = header.size - new_len;
                        const offset = next.data_offset();
                        const old_size = next.size;
                        const old_next = next.node;
                        const new_end: *Header = @ptrFromInt(Alignment.of(Header).forward(header.data_ptr() + new_len));
                        new_end.* = Header{
                            .node = old_next,
                            .size = diff + offset + old_size,
                            .alignment = Alignment.@"1", //make calculation easier
                        };
                        header.node.next = new_end;
                        return true;
                    }
                }
                return false;
            }
            fn free(_: *anyopaque, memory: []u8, _: Alignment, _: usize) void {
                const self = Header.from_memory(memory);
                self.free = true;
                self.join();
            }
        };
        const Header = struct {
            free: bool = true,
            node: Node = Node{},
            size: usize,
            data_align: Alignment,
            magic: u32 = MAGIC,

            pub fn from_memory(memory: []u8) *Header {
                return @ptrFromInt(Alignment.of(Header).backward(memory.ptr - @sizeOf(Header)));
            }

            pub fn next(self: *Header) ?*Header {
                if (self.node.next) |n| {
                    return @fieldParentPtr("node", n);
                } else return null;
            }
            fn data_ptr(self: *Header) *anyopaque {
                return self.data_align.forward(self + 1);
            }
            //from start of header
            fn data_offset(self: *Header) usize {
                return self - self.data_ptr();
            }
            fn total_size(self: *Header) usize {
                return self.data_offset() + self.size;
            }
            pub fn join(self: *Header) bool {
                var ptr: ?*Header = self.next();
                while (ptr) |header| : (ptr = header.next()) {
                    if (!header.free) break;
                    self.size += header.total_size();
                    self.node.next = header.node.next;
                    return true;
                }
                return false;
            }
            pub fn split(header: *Header, size: usize) void {
                if (header.size < size + DEFAULT_HEADER_SIZE) return;
                //also end of header data(the old one)
                const new_header: *Header = @ptrCast(@alignCast(header.data_ptr() + size));
                //at least header.len + alignment padding
                const new_header_off = header.data_ptr() - new_header;

                new_header.* = Header{
                    .size = header.size - new_header_off - header.data_offset(),
                    .data_align = DEFAULT_ALIGN,
                };
                header.node.insertAfter(&new_header.node);
                header.size = size;
            }
            fn data_offset_align(self: *Header, alignment: Alignment) usize {
                return self - alignment.forward(self + 1);
            }
            fn data_size_with_alignment(self: *Header, alignment: Alignment) ?usize {
                const offset = self.data_offset();
                const end = offset + self.size;
                const new_offset = self.data_offset_align(alignment);
                if (end < new_offset) return null;
                return end - new_offset;
            }
        };
        const DEFAULT_ALIGN = Alignment.@"16";
        const DEFAULT_HEADER_SIZE = DEFAULT_ALIGN.forward(@sizeOf(Header));
        const DEFAULT_OFFSET = DEFAULT_HEADER_SIZE - @sizeOf(Header);
        fn get_first(self: *Self) *Header {
            return @ptrCast(@alignCast(self.global_buffer));
        }
        pub fn init(self: *Self) void {
            self.alloc = .{ .ptr = self, .vtable = &std.mem.Allocator.VTable{
                .alloc = vtable.alloc,
                .free = vtable.free,
                .remap = vtable.remap,
                .resize = vtable.resize,
            } };
            const first: *Header = self.get_first();
            const after: *u8 = @ptrCast(first.data_ptr());
            const offset = after - (&self.global_buffer);
            const after_slice = self.global_buffer[offset..];
            first.* = Header{
                .size = after_slice.len,
            };
        }
    };
}
