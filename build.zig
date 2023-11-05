const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const xcb_queue_buffer_size = b.option(u64, "xcb_queue_buffer_size", "i dont know what this is. someone who knows xorg please document") orelse 16384;
    const iov_max = b.option(u64, "iov_max", "i dont know what this is. someone who knows xorg please document") orelse 16;
    const xorgproto_header_dir = b.option([]const u8, "xproto_header_dir", "header directory to use for libX11") orelse "";

    var flags = std.ArrayList([]const u8).init(b.allocator);
    defer flags.deinit();

    const xcb_queue_buffer_size_flag = std.fmt.allocPrint(b.allocator, "-DXCB_QUEUE_BUFFER_SIZE={any}", .{xcb_queue_buffer_size}) catch @panic("OOM");
    flags.append(xcb_queue_buffer_size_flag) catch @panic("OOM");
    const iov_max_flage = std.fmt.allocPrint(b.allocator, "-DIOV_MAX={any}", .{iov_max}) catch @panic("OOM");
    flags.append(iov_max_flage) catch @panic("OOM");

    // get the location of the xproto xml files for C source file generation
    const generated_c_sources = getGeneratedFiles(b, getXcbIncludeDir(b.allocator)) catch @panic("OOM");

    const lib = b.addStaticLibrary(.{
        .name = "xcb",
        .target = target,
        .optimize = optimize,
    });

    {
        const xml_files_abs_paths = getAbsolutePathsToXMLFiles(b.allocator, getXcbIncludeDir(b.allocator)) catch |err| {
            std.log.err("failed with {any}", .{err});
            @panic("failed to generate absolute paths to xml files");
        };
        addSystemCommandsForGeneratingSourceFiles(
            b,
            &lib.step,
            b.allocator,
            getOutputDirectory(b) catch @panic("OOM"),
            xml_files_abs_paths,
        ) catch |err| {
            std.log.err("failed with {any}", .{err});
            @panic("failed while generating source files");
        };
    }

    lib.addCSourceFiles(&.{
        "src/xcb_auth.c",
        "src/xcb_conn.c",
        "src/xcb_ext.c",
        "src/xcb_in.c",
        "src/xcb_list.c",
        "src/xcb_out.c",
        "src/xcb_util.c",
        "src/xcb_xid.c",
    }, b.allocator.dupe([]const u8, flags.items) catch @panic("OOM"));

    lib.addIncludePath(.{ .path = "src" });
    lib.addIncludePath(.{ .path = xorgproto_header_dir });

    lib.linkLibrary(b.dependency("xau", .{
        .target = target,
        .optimize = optimize,
        .xproto_header_dir = xorgproto_header_dir,
    }).artifact("Xau"));

    if (generated_c_sources.len > 0) {
        const dirname = std.fs.path.dirname(generated_c_sources[0]) orelse @panic("c source file path not absolute?");
        lib.addIncludePath(.{ .path = dirname });
    }

    lib.addCSourceFiles(generated_c_sources, b.allocator.dupe([]const u8, flags.items) catch @panic("OOM"));

    lib.linkLibC();

    b.installArtifact(lib);
}

/// Figures out what the files that result from the xml files will be. these files
/// are not generated yet!
fn getGeneratedFiles(b: *std.Build, xml_files_dir: []const u8) ![]const []const u8 {
    const xml_files_abs_paths = try getAbsolutePathsToXMLFiles(b.allocator, xml_files_dir);

    // before generating files, create the output directory and change our CWD to it
    const output_dir = try getOutputDirectory(b);

    var generated_files = std.ArrayList([]const u8).init(b.allocator);
    defer generated_files.deinit();

    for (xml_files_abs_paths) |xml_file| {
        const c_file = try std.fmt.allocPrint(b.allocator, "{s}/{s}.c", .{ output_dir, std.fs.path.stem(xml_file) });
        try generated_files.append(c_file);
    }

    return generated_files.toOwnedSlice();
}

fn getOutputDirectory(b: *std.Build) ![]const u8 {
    return try b.global_cache_root.join(b.allocator, &.{"libxcb_gen"});
}

fn addSystemCommandsForGeneratingSourceFiles(
    b: *std.Build,
    step: *std.Build.Step,
    ally: std.mem.Allocator,
    output_dir: []const u8,
    xml_files_abs_paths: []const []const u8,
) !void {
    std.fs.makeDirAbsolute(output_dir) catch |err| block: {
        // TODO: maybe delete the old output and recreate it every time?
        switch (err) {
            std.os.MakeDirError.PathAlreadyExists => break :block,
            else => return err,
        }
    };

    // also make the man subdir
    std.fs.makeDirAbsolute(try std.fs.path.join(ally, &.{ output_dir, "man" })) catch |err| block: {
        // TODO: maybe delete the old output and recreate it every time?
        switch (err) {
            std.os.MakeDirError.PathAlreadyExists => break :block,
            else => return err,
        }
    };

    const generator_script = b.build_root.join(ally, &.{ "src", "c_client.py" }) catch @panic("OOM");

    // run the generator script on all the xml files
    for (xml_files_abs_paths) |xml_file| {
        const cmd = b.addSystemCommand(&.{
            "python",
            generator_script,
            "-e",
            output_dir,
            "-p",
            output_dir,
            "-c",
            "dummy_CENTER",
            "-l",
            "dummy_LEFTFOOTER",
            "-s",
            std.fs.path.stem(xml_file),
            xml_file,
        });
        step.dependOn(&cmd.step);
    }
}

/// returns a slice of strings which are the absolute paths to all the XML files in directory xml_files_dir
fn getAbsolutePathsToXMLFiles(ally: std.mem.Allocator, xml_files_dir: []const u8) ![]const []const u8 {
    // basically do the ls command
    var xml_file_names = std.ArrayList([]const u8).init(ally);
    defer xml_file_names.deinit();
    var xml_dir_handle = std.fs.openIterableDirAbsolute(xml_files_dir, .{}) catch |err| {
        std.log.err("failed to open {s}, the expected location of the xml files for xproto generation. Error {any}", .{ xml_files_dir, err });
        @panic("Directory open failed");
    };
    var walker = try xml_dir_handle.walk(ally);
    defer {
        walker.deinit();
        xml_dir_handle.close();
    }

    // FIXME: should catch other errors. returning a non-memory related error will still cause a @panic("OOM")
    while (try walker.next()) |entry| {
        if (entry.kind != .file) {
            std.log.warn("found non-file in xml files directory of type {any}: {s}", .{ entry.kind, entry.path });
            continue;
        }
        if (std.mem.eql(u8, std.fs.path.extension(entry.path), ".xml")) {
            try xml_file_names.append(try std.fs.path.join(ally, &.{ xml_files_dir, entry.path }));
        }
    }
    return try xml_file_names.toOwnedSlice();
}

/// Makes a call to pkg-config to get the include directory of xcb-proto
fn getXcbIncludeDir(ally: std.mem.Allocator) []const u8 {
    const r = std.ChildProcess.exec(.{
        .allocator = ally,
        .argv = &.{ "pkg-config", "--variable=xcbincludedir", "xcb-proto" },
    }) catch @panic("failed to exec child process");
    defer {
        ally.free(r.stderr);
        ally.free(r.stdout);
    }
    const index = std.mem.indexOfScalar(u8, r.stdout, '\n') orelse r.stdout.len - 1;
    const dir = r.stdout[0..index];
    return ally.dupe(u8, dir) catch @panic("OOM");
}
