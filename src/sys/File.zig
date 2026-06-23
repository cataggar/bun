//! This is a similar API to std.Io.File, except it:
//! - Preserves errors from the operating system
//! - Supports normalizing BOM to UTF-8
//! - Has several optimizations somewhat specific to Bun
//! - Potentially goes through libuv on Windows
//! - Does not use unreachable in system calls.

const File = @This();

// "handle" matches std.Io.File
handle: bun.FD,

pub fn openat(dir: bun.FD, path: [:0]const u8, flags: i32, mode: bun.Mode) Maybe(File) {
    return switch (sys.openat(dir, path, flags, mode)) {
        .result => |fd| .{ .result = .{ .handle = fd } },
        .err => |err| .{ .err = err },
    };
}

pub fn open(path: [:0]const u8, flags: i32, mode: bun.Mode) Maybe(File) {
    return File.openat(bun.FD.cwd(), path, flags, mode);
}

pub fn makeOpen(path: [:0]const u8, flags: i32, mode: bun.Mode) Maybe(File) {
    return File.makeOpenat(bun.FD.cwd(), path, flags, mode);
}

pub fn makeOpenat(other: bun.FD, path: [:0]const u8, flags: i32, mode: bun.Mode) Maybe(File) {
    const fd = switch (sys.openat(other, path, flags, mode)) {
        .result => |fd| fd,
        .err => |err| fd: {
            if (std.fs.path.dirname(path)) |dir_path| {
                bun.makePath(other.stdDir(), dir_path) catch {};
                break :fd switch (sys.openat(other, path, flags, mode)) {
                    .result => |fd| fd,
                    .err => |err2| return .{ .err = err2 },
                };
            }

            return .{ .err = err };
        },
    };

    return .{ .result = .{ .handle = fd } };
}

pub fn openatOSPath(other: bun.FD, path: bun.OSPathSliceZ, flags: i32, mode: bun.Mode) Maybe(File) {
    return switch (sys.openatOSPath(other, path, flags, mode)) {
        .result => |fd| .{ .result = .{ .handle = fd } },
        .err => |err| .{ .err = err },
    };
}

pub fn from(other: anytype) File {
    const T = @TypeOf(other);

    if (T == File) {
        return other;
    }

    if (T == std.posix.fd_t) {
        return .{ .handle = .fromNative(other) };
    }

    if (T == bun.FD) {
        return .{ .handle = other };
    }

    if (T == std.Io.File) {
        return .{ .handle = .fromStdFile(other) };
    }

    if (T == std.Io.Dir) {
        return File{ .handle = .fromStdDir(other) };
    }

    if (comptime Environment.isLinux) {
        if (T == u64) {
            return File{ .handle = .fromNative(@intCast(other)) };
        }
    }

    @compileError("Unsupported type " ++ bun.meta.typeName(T));
}

pub fn write(self: File, buf: []const u8) Maybe(usize) {
    return sys.write(self.handle, buf);
}

pub fn read(self: File, buf: []u8) Maybe(usize) {
    return sys.read(self.handle, buf);
}

pub fn readAll(self: File, buf: []u8) Maybe(usize) {
    return sys.readAll(self.handle, buf);
}

pub fn pwriteAll(self: File, buf: []const u8, initial_offset: i64) Maybe(void) {
    var remain = buf;
    var offset = initial_offset;
    while (remain.len > 0) {
        const rc = sys.pwrite(self.handle, remain, offset);
        switch (rc) {
            .err => |err| return .{ .err = err },
            .result => |amt| {
                if (amt == 0) {
                    return .success;
                }
                remain = remain[amt..];
                offset += @intCast(amt);
            },
        }
    }

    return .success;
}

pub fn writeAll(self: File, buf: []const u8) Maybe(void) {
    var remain = buf;
    while (remain.len > 0) {
        const rc = sys.write(self.handle, remain);
        switch (rc) {
            .err => |err| return .{ .err = err },
            .result => |amt| {
                if (amt == 0) {
                    return .success;
                }
                remain = remain[amt..];
            },
        }
    }

    return .success;
}

pub fn writeFile(
    relative_dir_or_cwd: anytype,
    path: bun.OSPathSliceZ,
    data: []const u8,
) Maybe(void) {
    const file = switch (File.openatOSPath(relative_dir_or_cwd, path, bun.O.WRONLY | bun.O.CREAT | bun.O.TRUNC, 0o664)) {
        .err => |err| return .{ .err = err },
        .result => |fd| fd,
    };
    defer file.close();
    switch (file.writeAll(data)) {
        .err => |err| return .{ .err = err },
        .result => {},
    }
    return .success;
}

pub const ReadError = anyerror;

pub fn closeAndMoveTo(this: File, src: [:0]const u8, dest: [:0]const u8) !void {
    // On POSIX, close the file after moving it.
    defer if (Environment.isPosix) this.close();
    // On Windows, close the file before moving it.
    if (Environment.isWindows) this.close();
    const cwd = bun.FD.cwd();
    try bun.sys.moveFileZWithHandle(this.handle, cwd, src, cwd, dest);
}

fn stdIoRead(this: File, buf: []u8) ReadError!usize {
    return try this.read(buf).unwrap();
}

pub const Reader = struct {
    context: File,

    pub const Error = ReadError;

    pub fn read(self: Reader, buf: []u8) ReadError!usize {
        return stdIoRead(self.context, buf);
    }

    pub fn readAll(self: Reader, buf: []u8) ReadError!void {
        var remain = buf;
        while (remain.len > 0) {
            const amt = try self.read(remain);
            if (amt == 0) return error.EndOfStream;
            remain = remain[amt..];
        }
    }

    pub fn readByte(self: Reader) ReadError!u8 {
        var byte: [1]u8 = undefined;
        try self.readAll(&byte);
        return byte[0];
    }

    pub fn readInt(self: Reader, comptime T: type, endian: std.builtin.Endian) ReadError!T {
        var bytes: [@divExact(@typeInfo(T).int.bits, 8)]u8 = undefined;
        try self.readAll(&bytes);
        return std.mem.readInt(T, &bytes, endian);
    }

    pub const Adapter = struct {
        context: File,
        new_interface: std.Io.Reader,

        pub fn init(context: File, buffer: []u8) Adapter {
            return .{
                .context = context,
                .new_interface = .{
                    .vtable = &.{
                        .stream = stream,
                    },
                    .buffer = buffer,
                    .seek = 0,
                    .end = 0,
                },
            };
        }

        fn stream(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
            if (limit == .nothing) return 0;
            const this: *Adapter = @fieldParentPtr("new_interface", r);
            const dest = limit.slice(w.writableSliceGreedy(1) catch return error.WriteFailed);
            const amt = this.context.read(dest).unwrap() catch return error.ReadFailed;
            if (amt == 0) return error.EndOfStream;
            w.advance(amt);
            return amt;
        }
    };

    fn bufferFrom(buffer: anytype) []u8 {
        return switch (@typeInfo(@TypeOf(buffer))) {
            .pointer => |ptr| switch (ptr.size) {
                .one => switch (@typeInfo(ptr.child)) {
                    .array => |array| @constCast(buffer)[0..array.len],
                    else => @as([*]u8, @ptrCast(@constCast(buffer)))[0..1],
                },
                .slice => @constCast(buffer),
                else => @compileError("expected a buffer slice or pointer to an array"),
            },
            else => @compileError("expected a buffer slice or pointer to an array"),
        };
    }

    pub fn adaptToNewApi(self: Reader, buffer: anytype) Adapter {
        return Adapter.init(self.context, bufferFrom(buffer));
    }
};

pub fn reader(self: File) Reader {
    return Reader{ .context = self };
}

pub const WriteError = anyerror;
fn stdIoWrite(this: File, bytes: []const u8) WriteError!usize {
    try this.writeAll(bytes).unwrap();

    return bytes.len;
}

fn stdIoWriteQuietDebug(this: File, bytes: []const u8) WriteError!usize {
    bun.Output.disableScopedDebugWriter();
    defer bun.Output.enableScopedDebugWriter();
    try this.writeAll(bytes).unwrap();

    return bytes.len;
}

fn FileWriter(comptime quiet: bool) type {
    return struct {
        context: File,

        pub const Error = WriteError;

        const Self = @This();

        fn writeFn(file: File, bytes: []const u8) WriteError!usize {
            if (comptime quiet and Environment.isDebug) {
                return stdIoWriteQuietDebug(file, bytes);
            }
            return stdIoWrite(file, bytes);
        }

        pub fn write(self: Self, bytes: []const u8) WriteError!usize {
            return writeFn(self.context, bytes);
        }

        pub fn writeAll(self: Self, bytes: []const u8) WriteError!void {
            _ = try writeFn(self.context, bytes);
        }

        pub fn writeByte(self: Self, byte: u8) WriteError!void {
            try self.writeAll(&.{byte});
        }

        pub fn writeInt(self: Self, comptime T: type, value: T, endian: std.builtin.Endian) WriteError!void {
            var bytes: [@divExact(@typeInfo(T).int.bits, 8)]u8 = undefined;
            std.mem.writeInt(std.math.ByteAlignedInt(@TypeOf(value)), &bytes, value, endian);
            try self.writeAll(&bytes);
        }

        pub fn print(self: Self, comptime fmt: []const u8, args: anytype) std.Io.Writer.Error!void {
            var adapter = self.adaptToNewApi(&.{});
            try adapter.new_interface.print(fmt, args);
            try adapter.new_interface.flush();
        }

        pub const Adapter = struct {
            context: File,
            new_interface: std.Io.Writer,

            pub fn init(context: File, buffer: []u8) Adapter {
                return .{
                    .context = context,
                    .new_interface = .{
                        .vtable = &.{
                            .drain = drain,
                            .flush = std.Io.Writer.defaultFlush,
                            .rebase = std.Io.Writer.failingRebase,
                        },
                        .buffer = buffer,
                    },
                };
            }

            fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
                const this: *Adapter = @fieldParentPtr("new_interface", w);
                _ = writeFn(this.context, w.buffered()) catch return error.WriteFailed;
                w.end = 0;

                var written: usize = 0;
                for (data[0 .. data.len - 1]) |bytes| {
                    _ = writeFn(this.context, bytes) catch return error.WriteFailed;
                    written += bytes.len;
                }

                const pattern = data[data.len - 1];
                for (0..splat) |_| {
                    _ = writeFn(this.context, pattern) catch return error.WriteFailed;
                    written += pattern.len;
                }

                return written;
            }
        };

        fn bufferFrom(buffer: anytype) []u8 {
            return switch (@typeInfo(@TypeOf(buffer))) {
                .pointer => |ptr| switch (ptr.size) {
                    .one => switch (@typeInfo(ptr.child)) {
                        .array => |array| @constCast(buffer)[0..array.len],
                        else => @as([*]u8, @ptrCast(@constCast(buffer)))[0..1],
                    },
                    .slice => @constCast(buffer),
                    else => @compileError("expected a buffer slice or pointer to an array"),
                },
                else => @compileError("expected a buffer slice or pointer to an array"),
            };
        }

        pub fn adaptToNewApi(self: Self, buffer: anytype) Adapter {
            return Adapter.init(self.context, bufferFrom(buffer));
        }
    };
}

pub const Writer = FileWriter(false);
pub const QuietWriter = if (Environment.isDebug) FileWriter(true) else Writer;

pub fn writer(self: File) Writer {
    return Writer{ .context = self };
}

pub fn quietWriter(self: File) QuietWriter {
    return QuietWriter{ .context = self };
}

pub fn isTty(self: File) bool {
    return std.c.isatty(self.handle.cast()) != 0;
}

/// Asserts in debug that this File object is valid
pub fn close(self: File) void {
    self.handle.close();
}

pub fn getEndPos(self: File) Maybe(usize) {
    return getFileSize(self.handle);
}

pub fn stat(self: File) Maybe(bun.Stat) {
    return fstat(self.handle);
}

/// Be careful about using this on Linux or macOS.
///
/// File calls stat() internally.
pub fn kind(self: File) Maybe(std.Io.File.Kind) {
    if (Environment.isWindows) {
        const rt = windows.GetFileType(self.handle.cast());
        if (rt == windows.FILE_TYPE_UNKNOWN) {
            switch (windows.GetLastError()) {
                .SUCCESS => {},
                else => |err| {
                    return .{ .err = Error.fromCode((SystemErrno.init(err) orelse SystemErrno.EUNKNOWN).toE(), .fstat) };
                },
            }
        }

        return .{
            .result = switch (rt) {
                windows.FILE_TYPE_CHAR => .character_device,
                windows.FILE_TYPE_REMOTE, windows.FILE_TYPE_DISK => .file,
                windows.FILE_TYPE_PIPE => .named_pipe,
                windows.FILE_TYPE_UNKNOWN => .unknown,
                else => .file,
            },
        };
    }

    const st = switch (self.stat()) {
        .err => |err| return .{ .err = err },
        .result => |s| s,
    };

    const m = st.mode & posix.S.IFMT;
    switch (m) {
        posix.S.IFBLK => return .{ .result = .block_device },
        posix.S.IFCHR => return .{ .result = .character_device },
        posix.S.IFDIR => return .{ .result = .directory },
        posix.S.IFIFO => return .{ .result = .named_pipe },
        posix.S.IFLNK => return .{ .result = .sym_link },
        posix.S.IFREG => return .{ .result = .file },
        posix.S.IFSOCK => return .{ .result = .unix_domain_socket },
        else => {
            return .{ .result = .file };
        },
    }
}

pub const ReadToEndResult = struct {
    bytes: std.array_list.Managed(u8) = std.array_list.Managed(u8).init(default_allocator),
    err: ?Error = null,

    pub fn unwrap(self: *const ReadToEndResult) ![]u8 {
        if (self.err) |err| {
            try (bun.sys.Maybe(void){ .err = err }).unwrap();
        }
        return self.bytes.items;
    }
};

pub fn readFillBuf(this: File, buf: []u8) Maybe([]u8) {
    var read_amount: usize = 0;
    while (read_amount < buf.len) {
        switch (if (comptime Environment.isPosix)
            pread(this.handle, buf[read_amount..], @intCast(read_amount))
        else
            sys.read(this.handle, buf[read_amount..])) {
            .err => |err| {
                return .{ .err = err };
            },
            .result => |bytes_read| {
                if (bytes_read == 0) {
                    break;
                }

                read_amount += bytes_read;
            },
        }
    }

    return .{ .result = buf[0..read_amount] };
}

pub fn readToEndWithArrayList(this: File, list: *std.array_list.Managed(u8), size_guess: enum { probably_small, unknown_size }) Maybe(usize) {
    if (size_guess == .probably_small) {
        bun.handleOom(list.ensureUnusedCapacity(64));
    } else {
        list.ensureTotalCapacityPrecise(
            switch (this.getEndPos()) {
                .err => |err| {
                    return .{ .err = err };
                },
                .result => |s| s,
            } + 16,
        ) catch |err| bun.handleOom(err);
    }

    var total: i64 = 0;
    while (true) {
        if (list.unusedCapacitySlice().len == 0) {
            bun.handleOom(list.ensureUnusedCapacity(16));
        }

        switch (if (comptime Environment.isPosix)
            pread(this.handle, list.unusedCapacitySlice(), total)
        else
            sys.read(this.handle, list.unusedCapacitySlice())) {
            .err => |err| {
                return .{ .err = err };
            },
            .result => |bytes_read| {
                if (bytes_read == 0) {
                    break;
                }

                list.items.len += bytes_read;
                total += @intCast(bytes_read);
            },
        }
    }

    return .{ .result = @intCast(total) };
}

/// Use this function on potentially large files.
/// Calls fstat() on the file to get the size of the file and avoids reallocations + extra read() calls.
pub fn readToEnd(this: File, allocator: std.mem.Allocator) ReadToEndResult {
    var list = std.array_list.Managed(u8).init(allocator);
    return switch (readToEndWithArrayList(this, &list, .unknown_size)) {
        .err => |err| .{ .err = err, .bytes = list },
        .result => .{ .err = null, .bytes = list },
    };
}

/// Use this function on small files <= 1024 bytes.
/// File will skip the fstat() call, preallocating 64 bytes instead of the file's size.
pub fn readToEndSmall(this: File, allocator: std.mem.Allocator) ReadToEndResult {
    var list = std.array_list.Managed(u8).init(allocator);
    return switch (readToEndWithArrayList(this, &list, .probably_small)) {
        .err => |err| .{ .err = err, .bytes = list },
        .result => .{ .err = null, .bytes = list },
    };
}

pub fn getPath(this: File, out_buffer: *bun.PathBuffer) Maybe([]u8) {
    return getFdPath(this.handle, out_buffer);
}

/// 1. Normalize the file path
/// 2. Open a file for reading
/// 2. Read the file to a buffer
/// 3. Return the File handle and the buffer
pub fn readFromUserInput(dir_fd: anytype, input_path: anytype, allocator: std.mem.Allocator) Maybe([]u8) {
    var buf: bun.PathBuffer = undefined;
    const normalized = bun.path.joinAbsStringBufZ(
        bun.fs.FileSystem.instance.top_level_dir,
        &buf,
        &.{input_path},
        .loose,
    );
    return readFrom(dir_fd, normalized, allocator);
}

/// 1. Open a file for reading
/// 2. Read the file to a buffer
/// 3. Return the File handle and the buffer
pub fn readFileFrom(dir_fd: anytype, path: anytype, allocator: std.mem.Allocator) Maybe(struct { File, []u8 }) {
    const ElementType = std.meta.Elem(@TypeOf(path));

    const rc = brk: {
        if (comptime Environment.isWindows and ElementType == u16) {
            break :brk openatWindowsTMaybeNormalize(u16, from(dir_fd).handle, path, O.RDONLY, false);
        }

        if (comptime ElementType == u8 and std.meta.sentinel(@TypeOf(path)) == null) {
            break :brk sys.openatA(from(dir_fd).handle, path, O.RDONLY, 0);
        }

        break :brk sys.openat(from(dir_fd).handle, path, O.RDONLY, 0);
    };

    const this = switch (rc) {
        .err => |err| return .{ .err = err },
        .result => |fd| from(fd),
    };

    var result = this.readToEnd(allocator);

    if (result.err) |err| {
        this.close();
        result.bytes.deinit();
        return .{ .err = err };
    }

    if (result.bytes.items.len == 0) {
        // Don't allocate an empty string.
        // We won't be modifying an empty slice, anyway.
        return .{ .result = .{ this, @ptrCast(@constCast("")) } };
    }

    return .{ .result = .{ this, result.bytes.items } };
}

/// 1. Open a file for reading relative to a directory
/// 2. Read the file to a buffer
/// 3. Close the file
/// 4. Return the buffer
pub fn readFrom(dir_fd: anytype, path: anytype, allocator: std.mem.Allocator) Maybe([]u8) {
    const file, const bytes = switch (readFileFrom(dir_fd, path, allocator)) {
        .err => |err| return .{ .err = err },
        .result => |result| result,
    };

    file.close();
    return .{ .result = bytes };
}

const ToSourceOptions = struct {
    convert_bom: bool = false,
};

pub fn toSourceAt(dir_fd: anytype, path: anytype, allocator: std.mem.Allocator, opts: ToSourceOptions) Maybe(bun.logger.Source) {
    var bytes = switch (readFrom(dir_fd, path, allocator)) {
        .err => |err| return .{ .err = err },
        .result => |bytes| bytes,
    };

    if (opts.convert_bom) {
        if (bun.strings.BOM.detect(bytes)) |bom| {
            bytes = bun.handleOom(bom.removeAndConvertToUTF8AndFree(allocator, bytes));
        }
    }

    return .{ .result = bun.logger.Source.initPathString(path, bytes) };
}

pub fn toSource(path: anytype, allocator: std.mem.Allocator, opts: ToSourceOptions) Maybe(bun.logger.Source) {
    return toSourceAt(bun.FD.cwd(), path, allocator, opts);
}

const bun = @import("bun");
const Environment = bun.Environment;
const default_allocator = bun.default_allocator;
const windows = bun.windows;

const sys = bun.sys;
const Error = bun.sys.Error;
const Maybe = bun.sys.Maybe;
const O = sys.O;
const SystemErrno = bun.sys.SystemErrno;
const fstat = sys.fstat;
const getFdPath = sys.getFdPath;
const getFileSize = sys.getFileSize;
const openatWindowsTMaybeNormalize = sys.openatWindowsTMaybeNormalize;
const pread = sys.pread;

const std = @import("std");
const posix = std.posix;
