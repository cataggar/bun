// translate-c is unable to translate the unsuffixed windows functions
// like `SetCurrentDirectory` since they are defined with an odd macro
// that translate-c doesn't handle.
//
//     #define SetCurrentDirectory __MINGW_NAME_AW(SetCurrentDirectory)
//
// In these cases, it's better to just reference the underlying function
// directly: SetCurrentDirectoryW. To make the error better, a post
// processing step is applied to the translate-c file.

const symbol_replacements = std.StaticStringMap([]const u8).initComptime(&.{
    &.{ "NTSTATUS", "@import(\"std\").os.windows.NTSTATUS" },
    &.{ "HANDLE", "@import(\"std\").os.windows.HANDLE" },
    &.{ "PHANDLE", "*HANDLE" },
});

pub fn main() !void {
    const gpa = std.heap.smp_allocator;
    var io_threaded: std.Io.Threaded = .init_single_threaded;
    const io = io_threaded.io();
    var args = try std.process.argsWithAllocator(gpa);
    errdefer args.deinit();
    assert(args.skip());

    const in = brk: {
        const in_path = args.next() orelse @panic("missing argument");
        break :brk try std.Io.Dir.cwd().readFileAllocOptions(io, in_path, gpa, .limited(std.math.maxInt(u32)), .of(u8), 0);
    };
    defer gpa.free(in);

    var aw = try std.Io.Writer.Allocating.initCapacity(gpa, in.len);
    defer aw.deinit();
    const w = &aw.writer;

    var i: usize = 0;
    while (mem.indexOfPos(u8, in, i, "pub const ")) |pub_i| {
        var tokenizer = std.zig.Tokenizer.init(in);
        tokenizer.index = pub_i + "pub const ".len;
        const symbol_name_token = tokenizer.next();
        assert(symbol_name_token.tag == .identifier);
        const symbol_name = in[symbol_name_token.loc.start..symbol_name_token.loc.end];
        try w.writeAll(in[i..symbol_name_token.loc.end]);
        i = symbol_name_token.loc.end;
        var end_of_line = mem.indexOfScalarPos(u8, in, symbol_name_token.loc.end, '\n') orelse in.len;
        if (in[end_of_line - 1] != ';') {
            // skip multiline decl
            try w.writeAll(in[i..end_of_line]);
            i = end_of_line;
            continue;
        }
        end_of_line += 1; // include the \n
        if (symbol_replacements.get(symbol_name)) |replace| {
            try w.print(" = {s};\n", .{replace});
        } else if (mem.startsWith(u8, in[i..], " = __MINGW_NAME_AW(")) {
            try w.print(" = @compileError(\"Use '{s}W' instead.\");\n", .{symbol_name});
        } else {
            try w.writeAll(in[i..end_of_line]);
        }
        i = end_of_line;
    }
    try w.writeAll(in[i..]);
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = args.next() orelse @panic("missing argument"),
        .data = aw.writer.buffered(),
    });
}

fn assert(cond: bool) void {
    if (!cond) @panic("unhandled");
}

const std = @import("std");
const mem = std.mem;
