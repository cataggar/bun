fn isOomOnlyError(comptime ErrorUnionOrSet: type) bool {
    @setEvalBranchQuota(10000);
    const ErrorSet = switch (@typeInfo(ErrorUnionOrSet)) {
        .error_union => |union_info| union_info.error_set,
        .error_set => ErrorUnionOrSet,
        else => @compileError("argument must be an error union or error set"),
    };
    for (@typeInfo(ErrorSet).error_set.error_names orelse return false) |err| {
        if (!std.mem.eql(u8, err, "OutOfMemory")) return false;
    }
    return true;
}

fn OomHandledReturn(comptime ArgType: type) type {
    const arg_info = @typeInfo(ArgType);
    if (isOomOnlyError(ArgType)) return switch (arg_info) {
        .error_union => |union_info| union_info.payload,
        .error_set => noreturn,
        else => unreachable,
    };

    return switch (arg_info) {
        .error_union => |union_info| anyerror!union_info.payload,
        .error_set => anyerror,
        else => @compileError("argument must be an error union or error set"),
    };
}

/// If `error_union_or_set` is `error.OutOfMemory`, calls `bun.outOfMemory`. Otherwise:
///
/// * If that was the only possible error, returns the non-error payload for error unions, or
///   `noreturn` for error sets.
/// * If other errors are possible, returns them in a widened error set.
///
/// Prefer this method over `catch bun.outOfMemory()`, since that could mistakenly catch
/// non-OOM-related errors.
///
/// There are two ways to use this function:
///
/// ```
/// // option 1:
/// const thing = bun.handleOom(allocateThing());
/// // option 2:
/// const thing = allocateThing() catch |err| bun.handleOom(err);
/// ```
pub fn handleOom(error_union_or_set: anytype) OomHandledReturn(@TypeOf(error_union_or_set)) {
    const ArgType = @TypeOf(error_union_or_set);
    const err = switch (comptime @typeInfo(ArgType)) {
        .error_union => if (error_union_or_set) |success| return success else |err| err,
        .error_set => error_union_or_set,
        else => unreachable,
    };
    if (comptime isOomOnlyError(ArgType)) {
        bun.outOfMemory();
    }

    return switch (err) {
        error.OutOfMemory => bun.outOfMemory(),
        else => |other_error| @as(OomHandledReturn(ArgType), other_error),
    };
}

const bun = @import("bun");
const std = @import("std");
