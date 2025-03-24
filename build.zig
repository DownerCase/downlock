const std = @import("std");
const Scanner = @import("zig_wayland").Scanner;

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const scanner = Scanner.create(b, .{});
    const wayland = b.createModule(.{ .root_source_file = scanner.result });
    scanner.addSystemProtocol("stable/viewporter/viewporter.xml");
    scanner.addSystemProtocol("staging/ext-session-lock/ext-session-lock-v1.xml");

    const wlr_protocols: std.Build.LazyPath = blk: {
        const pc_output = b.run(&.{ "pkg-config", "--variable=pkgdatadir", "wlr-protocols" });
        break :blk .{
            .cwd_relative = std.mem.trim(u8, pc_output, &std.ascii.whitespace),
        };
    };
    scanner.addCustomProtocol(wlr_protocols.path(b, "unstable/wlr-screencopy-unstable-v1.xml"));

    scanner.generate("wl_compositor", 5);
    scanner.generate("wl_shm", 1);
    scanner.generate("wl_seat", 5);
    scanner.generate("wl_output", 4);
    scanner.generate("wp_viewporter", 1);
    scanner.generate("ext_session_lock_manager_v1", 1);
    scanner.generate("zwlr_screencopy_manager_v1", 3);

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    exe_mod.linkSystemLibrary("wayland-client", .{});
    exe_mod.linkSystemLibrary("xkbcommon", .{});
    exe_mod.linkSystemLibrary("pam", .{});
    exe_mod.linkSystemLibrary("pangocairo", .{});

    exe_mod.addImport("wayland", wayland);

    const exe = b.addExecutable(.{
        .name = "downlock",
        .root_module = exe_mod,
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);

    const run_step = b.step("run", "Run downlock");
    run_step.dependOn(&run_cmd.step);
}
