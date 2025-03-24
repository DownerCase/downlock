const std = @import("std");

// Shared memory
pub fn create_shm_file(base_dir: []const u8) !std.posix.fd_t {
    var rand = std.crypto.random;
    var buf = [_]u8{0} ** 128;
    for (&buf) |*b| {
        b.* = rand.intRangeAtMostBiased(u8, 'a', 'z');
    }
    _ = try std.fmt.bufPrint(&buf, "{s}/downlock-shm-", .{base_dir});
    const flags: std.posix.O = .{
        .CREAT = true,
        .ACCMODE = .RDWR,
        .EXCL = true,
        .CLOEXEC = true,
    };
    const fd = try std.posix.open(&buf, @bitCast(flags), 0o600);
    try std.posix.unlink(&buf);
    return fd;
}
