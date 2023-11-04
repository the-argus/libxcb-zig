const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addStaticLibrary(.{
        .name = "xcb",
        .target = target,
        .optimize = optimize,
    });

    exe.addCSourceFiles(&.{
        "src/xcb_auth.c",
        "src/xcb_conn.c",
        "src/xcb_ext.c",
        "src/xcb_in.c",
        "src/xcb_list.c",
        "src/xcb_out.c",
        "src/xcb_util.c",
        "src/xcb_xid.c",
    }, &.{});

    exe.addIncludePath(.{ .path = "src" });

    exe.linkLibC();

    b.installArtifact(exe);
}
