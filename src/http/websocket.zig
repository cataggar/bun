// This code is based on https://github.com/frmdstryr/zhp/blob/a4b5700c289c3619647206144e10fb414113a888/src/websocket.zig
// Thank you @frmdstryr.

pub const Opcode = enum(u4) {
    Continue = 0x0,
    Text = 0x1,
    Binary = 0x2,
    Res3 = 0x3,
    Res4 = 0x4,
    Res5 = 0x5,
    Res6 = 0x6,
    Res7 = 0x7,
    Close = 0x8,
    Ping = 0x9,
    Pong = 0xA,
    ResB = 0xB,
    ResC = 0xC,
    ResD = 0xD,
    ResE = 0xE,
    ResF = 0xF,

    pub fn isControl(opcode: Opcode) bool {
        return @intFromEnum(opcode) & 0x8 != 0;
    }
};

pub const WebsocketHeader = packed struct(u16) {
    len: u7,
    mask: bool,
    opcode: Opcode,
    rsv: u2 = 0, //rsv2 and rsv3
    compressed: bool = false, // rsv1
    final: bool = true,

    pub fn writeHeader(header: WebsocketHeader, writer: anytype, n: usize) anyerror!void {
        // packed structs are sometimes buggy
        // lets check it worked right
        if (comptime Environment.allow_assert) {
            var buf_ = [2]u8{ 0, 0 };
            var stream = std.Io.Writer.fixed(&buf_);
            stream.writeInt(u16, @as(u16, @bitCast(header)), .big) catch unreachable;
            var reader = std.Io.Reader.fixed(&buf_);
            const casted = reader.takeInt(u16, .big) catch unreachable;
            bun.assert(casted == @as(u16, @bitCast(header)));
            bun.assert(std.meta.eql(@as(WebsocketHeader, @bitCast(casted)), header));
        }

        var header_bytes: [2]u8 = undefined;
        std.mem.writeInt(u16, &header_bytes, @as(u16, @bitCast(header)), .big);
        try writeAllBytes(writer, &header_bytes);
        bun.assert(header.len == packLength(n));
    }

    fn writeAllBytes(writer: anytype, bytes: []const u8) !void {
        const Writer = @typeInfo(@TypeOf(writer)).pointer.child;
        if (comptime @hasField(Writer, "buffer") and @hasField(Writer, "pos")) {
            @memcpy(writer.buffer[writer.pos..][0..bytes.len], bytes);
            writer.pos += bytes.len;
            return;
        }

        try writer.writeAll(bytes);
    }

    pub fn packLength(length: usize) u7 {
        return switch (length) {
            0...125 => @as(u7, @truncate(length)),
            126...0xFFFF => 126,
            else => 127,
        };
    }

    const mask_length = 4;
    const header_length = 2;

    pub fn lengthByteCount(byte_length: usize) usize {
        return switch (byte_length) {
            0...125 => 0,
            126...0xFFFF => @sizeOf(u16),
            else => @sizeOf(u64),
        };
    }

    pub fn frameSize(byte_length: usize) usize {
        return header_length + byte_length + lengthByteCount(byte_length);
    }

    pub fn frameSizeIncludingMask(byte_length: usize) usize {
        return frameSize(byte_length) + mask_length;
    }

    pub fn slice(self: WebsocketHeader) [2]u8 {
        return @as([2]u8, @bitCast(@byteSwap(@as(u16, @bitCast(self)))));
    }

    pub fn fromSlice(bytes: [2]u8) WebsocketHeader {
        return @as(WebsocketHeader, @bitCast(@byteSwap(@as(u16, @bitCast(bytes)))));
    }
};

const std = @import("std");

const bun = @import("bun");
const Environment = bun.Environment;
