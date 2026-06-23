var file: std.Io.File = undefined;
pub var enabled = false;
pub var check = bun.once(load);

pub fn write(data: []const u8) void {
    var buf: [4096]u8 = undefined;
    var writer = file.writer(bun.blockingIo(), &buf);
    writer.interface.writeAll(data) catch {};
    writer.flush() catch {};
}

pub fn load() void {
    if (bun.env_var.BUN_POSTGRES_SOCKET_MONITOR.get()) |monitor| {
        enabled = true;
        file = std.Io.Dir.cwd().createFile(bun.blockingIo(), monitor, .{ .truncate = true }) catch {
            enabled = false;
            return;
        };
        debug("writing to {s}", .{monitor});
    }
}

const debug = bun.Output.scoped(.Postgres, .visible);

const bun = @import("bun");
const std = @import("std");
