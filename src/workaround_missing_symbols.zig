pub const linux = struct {

    // On linux, bun overrides the libc symbols for various functions.
    // This is to compensate for older glibc versions.

    fn simulateLibcErrno(rc: usize) c_int {
        const signed: isize = @bitCast(rc);
        const int: c_int = @intCast(if (signed > -4096 and signed < 0) -signed else 0);
        std.c._errno().* = int;
        return if (signed > -4096 and signed < 0) -1 else int;
    }

    const statx_mask: std.os.linux.STATX = .{
        .TYPE = true,
        .MODE = true,
        .NLINK = true,
        .UID = true,
        .GID = true,
        .ATIME = true,
        .MTIME = true,
        .CTIME = true,
        .INO = true,
        .SIZE = true,
        .BLOCKS = true,
        .BTIME = true,
    };

    inline fn makedev(major: u32, minor: u32) u64 {
        const maj: u64 = major & 0xFFF;
        const min: u64 = minor & 0xFFFFF;
        return (maj << 8) | (min & 0xFF) | ((min & 0xFFF00) << 12);
    }

    fn statxToPosix(stx: *const std.os.linux.Statx) PosixStat {
        return .{
            .dev = makedev(stx.dev_major, stx.dev_minor),
            .ino = stx.ino,
            .mode = stx.mode,
            .nlink = stx.nlink,
            .uid = stx.uid,
            .gid = stx.gid,
            .rdev = makedev(stx.rdev_major, stx.rdev_minor),
            .size = stx.size,
            .blksize = stx.blksize,
            .blocks = stx.blocks,
            .atim = .{ .sec = stx.atime.sec, .nsec = stx.atime.nsec },
            .mtim = .{ .sec = stx.mtime.sec, .nsec = stx.mtime.nsec },
            .ctim = .{ .sec = stx.ctime.sec, .nsec = stx.ctime.nsec },
            .birthtim = if (stx.mask.BTIME)
                .{ .sec = stx.btime.sec, .nsec = stx.btime.nsec }
            else
                .epoch,
        };
    }

    fn statxAsPosix(dirfd: i32, path: [*:0]const u8, flags: u32, buf: *PosixStat) usize {
        var stx = std.mem.zeroes(std.os.linux.Statx);
        const rc = std.os.linux.statx(dirfd, path, flags, statx_mask, &stx);
        if (rc == 0) {
            buf.* = statxToPosix(&stx);
        }
        return rc;
    }

    pub export fn stat(path: [*:0]const u8, buf: *PosixStat) c_int {
        // https://git.musl-libc.org/cgit/musl/tree/src/stat/stat.c
        const rc = statxAsPosix(std.os.linux.AT.FDCWD, path, 0, buf);
        return simulateLibcErrno(rc);
    }

    pub const stat64 = stat;
    pub const lstat64 = lstat;
    pub const fstat64 = fstat;
    pub const fstatat64 = fstatat;

    pub export fn lstat(path: [*:0]const u8, buf: *PosixStat) c_int {
        // https://git.musl-libc.org/cgit/musl/tree/src/stat/lstat.c
        const rc = statxAsPosix(std.os.linux.AT.FDCWD, path, std.os.linux.AT.SYMLINK_NOFOLLOW, buf);
        return simulateLibcErrno(rc);
    }

    pub export fn fstat(fd: c_int, buf: *PosixStat) c_int {
        const rc = statxAsPosix(fd, "", std.os.linux.AT.EMPTY_PATH, buf);
        return simulateLibcErrno(rc);
    }

    pub export fn fstatat(dirfd: i32, path: [*:0]const u8, buf: *PosixStat, flags: u32) c_int {
        const rc = statxAsPosix(dirfd, path, flags, buf);
        return simulateLibcErrno(rc);
    }

    pub export fn statx(dirfd: i32, path: [*:0]const u8, flags: u32, mask: u32, buf: *std.os.linux.Statx) c_int {
        const rc = std.os.linux.statx(dirfd, path, flags, @bitCast(mask), buf);
        return simulateLibcErrno(rc);
    }

    pub const memmem = bun.c.memmem;

    comptime {
        _ = stat;
        _ = stat64;
        _ = lstat;
        _ = lstat64;
        _ = fstat;
        _ = fstat64;
        _ = fstatat;
        _ = statx;
        @export(&stat, .{ .name = "stat64" });
        @export(&lstat, .{ .name = "lstat64" });
        @export(&fstat, .{ .name = "fstat64" });
        @export(&fstatat, .{ .name = "fstatat64" });
    }
};
pub const darwin = struct {
    pub const memmem = bun.c.memmem;

    // The symbol name depends on the arch.

    pub const lstat = blk: {
        const T = *const fn (?[*:0]const u8, ?*bun.Stat) callconv(.c) c_int;
        break :blk @extern(T, .{ .name = if (bun.Environment.isAarch64) "lstat" else "lstat64" });
    };
    pub const fstat = blk: {
        const T = *const fn (i32, ?*bun.Stat) callconv(.c) c_int;
        break :blk @extern(T, .{ .name = if (bun.Environment.isAarch64) "fstat" else "fstat64" });
    };
    pub const stat = blk: {
        const T = *const fn (?[*:0]const u8, ?*bun.Stat) callconv(.c) c_int;
        break :blk @extern(T, .{ .name = if (bun.Environment.isAarch64) "stat" else "stat64" });
    };
};
pub const windows = struct {
    /// Windows doesn't have memmem, so we need to implement it
    /// This is used in src/string/immutable.zig
    pub export fn memmem(haystack: ?[*]const u8, haystacklen: usize, needle: ?[*]const u8, needlelen: usize) ?[*]const u8 {
        // Handle null pointers
        if (haystack == null or needle == null) return null;

        // Handle empty needle case
        if (needlelen == 0) return haystack;

        // Handle case where needle is longer than haystack
        if (needlelen > haystacklen) return null;

        const hay = haystack.?[0..haystacklen];
        const nee = needle.?[0..needlelen];

        const i = std.mem.indexOf(u8, hay, nee) orelse return null;
        return hay.ptr + i;
    }

    /// lstat is implemented in workaround-missing-symbols.cpp
    pub const lstat = blk: {
        const T = *const fn ([*c]const u8, [*c]std.c.Stat) callconv(.c) c_int;
        break :blk @extern(T, .{ .name = "lstat64" });
    };
    /// fstat is implemented in workaround-missing-symbols.cpp
    pub const fstat = blk: {
        const T = *const fn ([*c]const u8, [*c]std.c.Stat) callconv(.c) c_int;
        break :blk @extern(T, .{ .name = "fstat64" });
    };
    /// stat is implemented in workaround-missing-symbols.cpp
    pub const stat = blk: {
        const T = *const fn ([*c]const u8, [*c]std.c.Stat) callconv(.c) c_int;
        break :blk @extern(T, .{ .name = "stat64" });
    };
};

pub const freebsd = struct {
    pub const memmem = bun.c.memmem;
    // FreeBSD has plain stat/fstat/lstat (no 64-suffix; off_t is always
    // 64-bit). Zig's std.c only exports darwin's `stat$INODE64`, so bind
    // them directly.
    pub extern "c" fn lstat(noalias path: [*:0]const u8, noalias buf: *std.c.Stat) c_int;
    pub extern "c" fn fstat(fd: c_int, buf: *std.c.Stat) c_int;
    pub extern "c" fn stat(noalias path: [*:0]const u8, noalias buf: *std.c.Stat) c_int;
};

pub const current = switch (bun.Environment.os) {
    .linux => linux,
    .windows => windows,
    .mac => darwin,
    .freebsd => freebsd,
    .wasm => struct {},
};

const bun = @import("bun");
const PosixStat = @import("./sys/PosixStat.zig").PosixStat;
const std = @import("std");
