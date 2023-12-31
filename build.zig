const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const xcb_queue_buffer_size = b.option(u64, "xcb_queue_buffer_size", "i dont know what this is. someone who knows xorg please document") orelse 16384;
    const iov_max = b.option(u64, "iov_max", "i dont know what this is. someone who knows xorg please document") orelse 16;
    const use_pkg_config_for_xproto = b.option(bool, "use_pkg_config_to_find_xproto_spec", "Whether to invoke pkg-config to find the location of xproto XML files") orelse false;
    // TODO: support passing settings such as this to libxau. currently this specific setting can be passed by setting the XPROTO_INCLUDE_DIR environment variable
    // const xproto_header_dir = b.option([]const u8, "xproto_header_dir", "header directory to use for libX11");

    // TODO: get rid of this. this is duplicated code from libxau build.zig
    const xproto_header_dir = b.option([]const u8, "xproto_header_dir", "Include directory to append, intended to contain X11/Xfuncproto.h") orelse block: {
        var envmap = std.process.getEnvMap(b.allocator) catch @panic("OOM");
        defer envmap.deinit();

        if (envmap.get("XPROTO_INCLUDE_DIR")) |dir| {
            break :block b.allocator.dupe(u8, dir) catch @panic("OOM");
        }

        break :block null;
    };

    const xau_dep = if (xproto_header_dir) |dir| b.dependency("xau", .{
        .target = target,
        .optimize = optimize,
        .xproto_header_dir = dir,
    }) else b.dependency("xau", .{
        .target = target,
        .optimize = optimize,
    });
    const xau = xau_dep.artifact("Xau");

    var flags = std.ArrayList([]const u8).init(b.allocator);
    defer flags.deinit();

    const xcb_queue_buffer_size_flag = std.fmt.allocPrint(b.allocator, "-DXCB_QUEUE_BUFFER_SIZE={any}", .{xcb_queue_buffer_size}) catch @panic("OOM");
    flags.append(xcb_queue_buffer_size_flag) catch @panic("OOM");
    const iov_max_flage = std.fmt.allocPrint(b.allocator, "-DIOV_MAX={any}", .{iov_max}) catch @panic("OOM");
    flags.append(iov_max_flage) catch @panic("OOM");

    // get the location of the xproto xml files for C source file generation
    const xml_file_location = if (use_pkg_config_for_xproto) getXcbIncludeDir(b.allocator) else b.build_root.join(b.allocator, &.{"xml_fallback"}) catch @panic("OOM");
    const generated = getGeneratedFiles(b, xml_file_location) catch @panic("OOM");
    const generated_c_sources = generated.c_files;
    const generated_headers = generated.header_files;

    const lib = b.addStaticLibrary(.{
        .name = "xcb",
        .target = target,
        .optimize = optimize,
    });

    // TODO: make an issue on zig issue tracker about this? i should not have to do this
    std.fs.makeDirAbsolute(b.install_prefix) catch {};
    std.fs.makeDirAbsolute(std.fs.path.join(b.allocator, &.{ b.install_prefix, "include" }) catch @panic("OOM")) catch {};
    std.fs.makeDirAbsolute(std.fs.path.join(b.allocator, &.{ b.install_prefix, "include", "xcb" }) catch @panic("OOM")) catch {};

    lib.installHeader("src/xcb.h", "xcb/xcb.h");
    lib.installHeader("src/xcbext.h", "xcb/xcbext.h");
    lib.installHeader("src/xcbint.h", "xcb/xcbint.h");
    lib.installHeader("src/xcb_windefs.h", "xcb/xcb_windefs.h");

    // generated headers dont use the xcb/ prefix for these
    lib.installHeader("src/xcb.h", "xcb.h");
    lib.installHeader("src/xcbext.h", "xcbext.h");
    lib.installHeader("src/xcbint.h", "xcbint.h");
    lib.installHeader("src/xcb_windefs.h", "xcb_windefs.h");

    // make dummy step
    var generated_headers_step = b.allocator.create(std.Build.Step) catch @panic("Allocation failure, probably OOM");
    generated_headers_step.* = std.Build.Step.init(.{
        .id = .custom,
        .name = "cc_file",
        .owner = b,
    });

    // make that step depend on the generation of the headers
    {
        const xml_files_abs_paths = getAbsolutePathsToXMLFiles(b.allocator, xml_file_location) catch |err| {
            std.log.err("failed with {any}", .{err});
            @panic("failed to generate absolute paths to xml files");
        };
        addSystemCommandsForGeneratingSourceFiles(
            b,
            generated_headers_step,
            b.allocator,
            getOutputDirectory(b) catch @panic("OOM"),
            xml_files_abs_paths,
        ) catch |err| {
            std.log.err("failed with {any}", .{err});
            @panic("failed while generating source files");
        };
    }

    // install all the generated header files directly in include/
    for (generated_headers) |header_path| {
        const install_file = b.addInstallHeaderFile(header_path, std.fs.path.basename(header_path));
        b.getInstallStep().dependOn(&install_file.step);
        // you have to generate the header file before this install step can run
        install_file.step.dependOn(generated_headers_step);
        lib.installed_headers.append(&install_file.step) catch @panic("OOM");
    }

    // lib also needs to depend on generated headers. the installed_headers
    // has it so the lib install step will depend on it, but the actual compilation
    // of the library also needs to wait until generation
    lib.step.dependOn(generated_headers_step);

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
    // TODO: evil hardcoding. just put libxau and libxcb in the same repo?
    lib.addIncludePath(.{ .path = xproto_header_dir orelse xau_dep.builder.build_root.join(b.allocator, &.{"xproto_header_fallback"}) catch @panic("OOM") });

    lib.linkLibrary(xau);
    lib.installLibraryHeaders(xau);

    if (generated_c_sources.len > 0) {
        const dirname = std.fs.path.dirname(generated_c_sources[0]) orelse @panic("c source file path not absolute?");
        lib.addIncludePath(.{ .path = dirname });
    }

    lib.addCSourceFiles(generated_c_sources, b.allocator.dupe([]const u8, flags.items) catch @panic("OOM"));

    lib.linkLibC();

    b.installArtifact(lib);
}

const GeneratedFiles = struct {
    header_files: []const []const u8,
    c_files: []const []const u8,
};

/// Figures out what the files that result from the xml files will be. these files
/// are not generated yet!
fn getGeneratedFiles(b: *std.Build, xml_files_dir: []const u8) !GeneratedFiles {
    const xml_files_abs_paths = try getAbsolutePathsToXMLFiles(b.allocator, xml_files_dir);

    // before generating files, create the output directory and change our CWD to it
    const output_dir = try getOutputDirectory(b);

    var c_files = std.ArrayList([]const u8).init(b.allocator);
    defer c_files.deinit();
    var header_files = std.ArrayList([]const u8).init(b.allocator);
    defer header_files.deinit();

    for (xml_files_abs_paths) |xml_file| {
        const c_file = try std.fmt.allocPrint(b.allocator, "{s}/{s}.c", .{ output_dir, std.fs.path.stem(xml_file) });
        const header_file = try std.fmt.allocPrint(b.allocator, "{s}/{s}.h", .{ output_dir, std.fs.path.stem(xml_file) });
        try c_files.append(c_file);
        try header_files.append(header_file);
    }

    return .{
        .c_files = try c_files.toOwnedSlice(),
        .header_files = try header_files.toOwnedSlice(),
    };
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
