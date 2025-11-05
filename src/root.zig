//! By convention, root.zig is the root source file when making a library.
const std = @import("std");
const Node = std.SinglyLinkedList.Node;
const Alignment = std.mem.Alignment;
// const ALIGN = std.mem.Alignment.@"16";
pub fn SAlloc(comptime bufsize: usize) type {
    return struct {
        const Self = @This();
        global_buffer: [bufsize]u8,
        alloc: std.mem.Allocator,

        const vtable = struct {
            fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, _: usize) ?[*]u8 {
                const self: *Self = @ptrCast(@alignCast(ctx));
                //TODO
                _ = alignment;
                //find first free big enough
                var h: ?*Header = self.get_first();
                while (h) |header| : (h = header.next()) {
                    if (header.free and header.size >= len) {
                        header.split(len);
                        return header.data_ptr();
                    }
                }
            }
            //attempt or shrink or grow memory in-place
            // fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, _: usize) bool {
            //     const self: *Self = @ptrCast(@alignCast(ctx));
            //     // if (new_len<)
            // }
        };
        pub const Header = struct {
            free: bool = true,
            node: Node = Node{},
            size: usize,
            data_align: Alignment,

            pub fn next(self: *Header) ?*Header {
                if (self.node.next) |n| {
                    return @fieldParentPtr("node", n);
                } else return null;
            }
            fn data_ptr(self: *Header) *anyopaque {
                return self.data_align.forward(self + 1);
            }
            fn data_offset(self: *Header) usize {
                return self - self.data_ptr();
            }
            fn split(header: *Header, size: usize) void {
                if (header.size < size + DEFAULT_HEADER_SIZE) return;
                const new_header: *Header = @ptrCast(@alignCast(@as(*u8, header.data_ptr()) + size));
                const new_header_off = header.data_ptr() - new_header;

                new_header.* = Header{
                    .size = header.size - new_header_off - header.data_offset(),
                    .data_align = DEFAULT_ALIGN,
                };
                header.node.insertAfter(&new_header.node);
                header.size = size;
            }
        };
        // const HEADER_SIZE = ALIGN.forward(@sizeOf(Header));
        const DEFAULT_ALIGN = Alignment.@"16";
        const DEFAULT_HEADER_SIZE = DEFAULT_ALIGN.forward(@sizeOf(Header));
        const DEFAULT_OFFSET = DEFAULT_HEADER_SIZE - @sizeOf(Header);
        fn get_first(self: *Self) *Header {
            return @ptrCast(@alignCast(self.global_buffer));
        }
        pub fn init(self: *Self) void {
            self.alloc = .{ .ptr = self, .vtable = &std.mem.Allocator.VTable{
                .alloc = vtable.alloc,
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
