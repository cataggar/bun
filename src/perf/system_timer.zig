fn NewTimer() type {
    if (Environment.isWasm) {
        return struct {
            pub fn start() anyerror!@This() {
                return @This(){};
            }

            pub fn read(_: anytype) u64 {
                @compileError("FeatureFlags.tracing should be disabled in WASM");
            }

            pub fn lap(_: anytype) u64 {
                @compileError("FeatureFlags.tracing should be disabled in WASM");
            }

            pub fn reset(_: anytype) void {
                @compileError("FeatureFlags.tracing should be disabled in WASM");
            }
        };
    }

    return struct {
        started: std.Io.Timestamp,
        previous: std.Io.Timestamp,

        const clock: std.Io.Clock = .awake;

        pub fn start() !@This() {
            const now = nowTimestamp(clock);
            return .{
                .started = now,
                .previous = now,
            };
        }

        pub fn read(this: @This()) u64 {
            return elapsed(this.started, nowTimestamp(clock));
        }

        pub fn lap(this: *@This()) u64 {
            const now = nowTimestamp(clock);
            defer this.previous = now;
            return elapsed(this.previous, now);
        }

        pub fn reset(this: *@This()) void {
            const now = nowTimestamp(clock);
            this.started = now;
            this.previous = now;
        }
    };
}
pub const Timer = NewTimer();

pub fn nanoTimestamp() i128 {
    return @intCast(nowTimestamp(.awake).toNanoseconds());
}

pub fn milliTimestamp() i64 {
    return nowTimestamp(.real).toMilliseconds();
}

pub fn timestamp() i64 {
    return nowTimestamp(.real).toSeconds();
}

fn nowTimestamp(clock: std.Io.Clock) std.Io.Timestamp {
    return std.Io.Timestamp.now(bun.blockingIo(), clock);
}

fn elapsed(started: std.Io.Timestamp, ended: std.Io.Timestamp) u64 {
    const elapsed_ns = started.durationTo(ended).toNanoseconds();
    if (elapsed_ns <= 0) return 0;
    return std.math.cast(u64, elapsed_ns) orelse std.math.maxInt(u64);
}

const bun = @import("bun");
const Environment = @import("../bun_core/env.zig");
const std = @import("std");
