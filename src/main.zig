const std = @import("std");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const socket = try std.net.connectUnixSocket("/run/user/1000/wayland-0");

    try wl_display.request.get_registry(socket, 2, gpa);

    var next_id: u32 = 3;
    try wl_display.request.sync(socket, next_id, gpa);

    main_loop: while (true) {
        const message = try wl_message.read(socket, gpa);
        switch (message.header.id) {
            1 =>{
                switch (message.header.opcode) {
                    0 => {
                        const display_error = wl_display.event.parse_error(message.content);
                        std.debug.print("error in {d}, code: {d}, message: {s}", .{display_error.object_id, display_error.error_code, display_error.message_string});
                    },

                    1 => {
                        const deleted_id = wl_display.event.parse_delete_id(message.content);
                        std.debug.print("Deleted: {d}\n", .{deleted_id});
                    },
                    else => std.debug.print("Invalid opcode: {d} for id {d}\n", .{message.header.opcode, message.header.id}),
                }
            },

            2 =>{
                switch (message.header.opcode) {
                    0 => {
                        const global = wl_registry.event.parse_global(message.content) catch wl_registry.event.global{.name = 0, .interface = &[_]u8{}, .version = 0};
                        std.debug.print("Global object name: {d}\ninterface: {s}\nversion:{d}\n", .{global.name, global.interface, global.version});
                    },

                    1 => {
                    },

                    else => std.debug.print("Invalid opcode {d} for id {d}\n", .{message.header.opcode, message.header.id}),
                }
            },

            3 => continue,
            
            else => {std.debug.print("header id: {d}\nopcode: {d}\nsize:{d}\nmessage:{d}", .{message.header.id, message.header.opcode, message.header.size, message.content});
                break :main_loop;
            }
        }
        const result = arena.reset(.free_all);
        if (result == false) {
            std.debug.print("Free arena result: {}", .{result});
        }
    }
    next_id += 1;
}

const wl_message = struct {
    const wl_header = struct {
        id: u32,
        opcode: u16,
        size: u16,
    };

    header: wl_header,
    content: []u8,

    pub fn read(socket: std.net.Stream, gpa: std.mem.Allocator) !wl_message {
        var buffer = std.ArrayList(u8).init(gpa);
        //defer buffer.deinit();
        try buffer.resize(8);

        const bytes_read = try socket.read(buffer.items);
        if (bytes_read < 8) {
            return error.NoHeader;
        }

        var message = wl_message {
            .header = .{
                .id = id: {
                    const v: u32 = std.mem.readInt(u32, buffer.items[0..4], .little);
                    break :id v;
                },
                
                .opcode = o: {
                    const v: u16 = std.mem.readInt(u16, buffer.items[4..][0..2], .little);
                    break :o v;
                },

                .size = s: {
                    const v: u16 = std.mem.readInt(u16, buffer.items[6..][0..2], .little);
                    break :s v;
                },
            },

            .content = &[_]u8{},
        };


        if (message.header.size > 8) {
            try buffer.resize(message.header.size - 8);
        } else {
            try buffer.resize(message.header.size);
        }
        message.content = c: {
            const message_bytes_read = try socket.read(buffer.items);
            if (message_bytes_read < 1) {
                std.debug.print("no message...\n", .{});
            }
            break :c buffer.items;
        };

        return message;
    }

    pub fn write(self: *const wl_message, socket: std.net.Stream, gpa: std.mem.Allocator) !void {
        if (self.header.size < 8) return error.No_Message;
        try socket.writeAll(msg:{
            var buffer = std.ArrayList(u8).init(gpa);
            defer buffer.deinit();
            try buffer.resize(self.header.size);
            try buffer.replaceRange(0, 4, &std.mem.toBytes(self.header.id));
            try buffer.replaceRange(4, 2, &std.mem.toBytes(self.header.opcode));
            try buffer.replaceRange(6, 2, &std.mem.toBytes(self.header.size));
            try buffer.replaceRange(8, self.content.len, self.content);
            break :msg try buffer.toOwnedSlice();
        });
    }
};

const wl_display = struct {
    pub const id = 1;
    pub const request = struct {
        pub const request_id = enum(u16) {
            sync = 0,
            get_registry = 1,
        };

        pub fn sync(socket: std.net.Stream, callback_id: u32, gpa: std.mem.Allocator) !void {
            const message = wl_message{
                .header = .{
                    .id = 1,
                    .opcode = @as(u16, @intFromEnum(wl_display.request.request_id.sync)),
                    .size = 12,
                },
                .content = value: {
                    var bytes = std.mem.toBytes(callback_id);
                    break :value &bytes;
                },
            };

            try message.write(socket, gpa);
        }

        pub fn get_registry(socket: std.net.Stream, registry_id: u32, gpa: std.mem.Allocator) !void {
            const message = wl_message{
                .header = .{
                    .id = 1,
                    .opcode = @as(u16, @intFromEnum(wl_display.request.request_id.get_registry)),
                    .size = 12,
                },
                .content = value: {
                    var bytes = std.mem.toBytes(registry_id);
                    break :value &bytes;
                },
            };
            try message.write(socket, gpa);
        }
    };

    pub const event = struct {
        pub const event_id = enum(u16) {
            display_error = 0,
            delete_id = 1,
        };

        const display_error = struct {
            object_id: u32,
            error_code: u32,
            message_string: []u8,
        };

        pub fn parse_error(message: []u8) display_error {
            return display_error{
                .object_id = id: {
                    const bytes = message[0..][0..4];
                    const v: u32 = std.mem.readInt(u32, bytes, .little);
                    break :id v;
                },
                .error_code = code: {
                    const bytes = message[4..][0..4];
                    const v: u32 = std.mem.readInt(u32, bytes, .little);
                    break :code v;
                },
                .message_string = msg: {
                    const size_bytes = message[8..][0..4];
                    const string_size: u32 = std.mem.readInt(u32, size_bytes, .little);
                    const string_bytes = message[12..][0..string_size];
                    break :msg string_bytes;
                },
            };
        }
        pub fn parse_delete_id(message: []u8) u32 {
            return id: {
                const bytes = message[0..][0..4];
                const v: u32 = std.mem.readInt(u32, bytes, .little);
                break :id v;
            };
        }
    };
};

const wl_registry = struct {
    pub const id = 2;
    pub const request = struct {
        pub fn bind() void {
        }
    };

    pub const event = struct {
        pub const global = struct {
            name: u32,
            interface: []u8,
            version: u32
        };
        pub const removed_name = u32;
        pub const list = enum(u16) {
            global = 0,
            global_remove = 1,
        };

        pub fn parse_global(message: []u8) !global {
            var current_index: usize = 0;
            if (message.len == 0) {
                return error.NoMessage;
            }
            const name: u32 = value: {
                const bytes = message[current_index..][0..4];
                current_index += 4;
                const v: u32 = std.mem.readInt(u32, bytes, .little);
                break :value v;
            };

            const interface: []u8 = value: {
                const size_bytes = message[current_index..][0..4];
                current_index += 4;
                const size: u32 = std.mem.readInt(u32, size_bytes
                , .little);
                const string_bytes = message[current_index..][0..size-1];
                current_index += size;
                break :value string_bytes;
            };

            if (current_index % 4 != 0) {
                current_index = (current_index - current_index % 4) + 4;
            }

            const version: u32 = value: {
                const bytes = message[current_index..][0..4];
                const v: u32 = std.mem.readInt(u32, bytes, .little);
                break :value v;
            };

            return global{
                .name = name,
                .interface = interface,
                .version = version,
            };
        }
        
        pub fn parse_remove() void {
        }
    };
};
