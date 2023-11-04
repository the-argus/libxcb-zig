const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // get the location of the xproto xml files for C source file generation
    const generated_c_sources = block: {
        const r = std.ChildProcess.exec(.{
            .allocator = b.allocator,
            .argv = &.{ "pkg-config", "--variable=xcbincludedir", "xcb-proto" },
        }) catch @panic("failed to exec child process");
        defer {
            b.allocator.free(r.stderr);
            b.allocator.free(r.stdout);
        }
        const index = std.mem.indexOfScalar(u8, r.stdout, '\n') orelse r.stdout.len - 1;
        break :block makeCSourceFromXproto(b, r.stdout[0..index]) catch @panic("OOM");
    };

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

    if (generated_c_sources.len > 0) {
        const dirname = std.fs.path.dirname(generated_c_sources[0]) orelse @panic("c source file path not absolute?");
        exe.addIncludePath(.{ .path = dirname });
    }

    exe.addCSourceFiles(generated_c_sources, &.{});

    exe.linkLibC();

    b.installArtifact(exe);
}

/// Goes to the xml directory and creates C source files from each XML file
/// returns a slice of the generated C files
fn makeCSourceFromXproto(b: *std.Build, xml_files_dir: []const u8) ![]const []const u8 {

    // basically do the ls command
    var xml_files_abs_paths = block: {
        var xml_file_names = std.ArrayList([]const u8).init(b.allocator);
        defer xml_file_names.deinit();
        var xml_dir_handle = std.fs.openIterableDirAbsolute(xml_files_dir, .{}) catch |err| {
            std.log.err("failed to open {s}, the expected location of the xml files for xproto generation. Error {any}", .{ xml_files_dir, err });
            @panic("Directory open failed");
        };
        var walker = try xml_dir_handle.walk(b.allocator);
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
                try xml_file_names.append(try std.fs.path.join(b.allocator, &.{ xml_files_dir, entry.path }));
            }
        }
        break :block try xml_file_names.toOwnedSlice();
    };

    // before generating files, create the output directory and change our CWD to it
    const output_dir = try b.cache_root.join(b.allocator, &.{"gen"});
    std.fs.makeDirAbsolute(output_dir) catch |err| block: {
        // TODO: maybe delete the old output and recreate it every time?
        switch (err) {
            std.os.MakeDirError.PathAlreadyExists => break :block,
            else => return err,
        }
    };

    // grab original directory and return to it when the scope ends
    const original_dir = try std.process.getCwdAlloc(b.allocator);
    defer b.allocator.free(original_dir);
    var output_dir_handle = try std.fs.openDirAbsolute(output_dir, .{});
    defer {
        output_dir_handle.close();
        var o = std.fs.openDirAbsolute(original_dir, .{}) catch @panic("failed to open original working directory");
        o.setAsCwd() catch @panic("error setting working directory back to original");
        o.close();
    }

    const generator_script = try std.fs.path.join(b.allocator, &.{ original_dir, "src", "c_client.py" });

    // switch into the output dir
    output_dir_handle.setAsCwd() catch @panic("error setting path to CWD");

    // run the generator script on all the xml files
    for (xml_files_abs_paths) |xml_file| {
        const r = std.ChildProcess.exec(.{
            .allocator = b.allocator,
            .argv = &.{
                "python",
                generator_script,
                "-p",
                output_dir,
                "-c",
                "dummy_CENTER",
                "-l",
                "dummy_LEFTFOOTER",
                "-s",
                std.fs.path.stem(xml_file),
                xml_file,
            },
        }) catch @panic("failed to exec child process");
        // std.log.debug("try to convert {s} to .c file", .{xml_file});
        // std.log.debug("conversion stdout: {s}", .{r.stdout});
        // std.log.debug("conversion sterr: {s}", .{r.stderr});
        defer {
            b.allocator.free(r.stderr);
            b.allocator.free(r.stdout);
        }
    }

    var generated_files = std.ArrayList([]const u8).init(b.allocator);
    defer generated_files.deinit();

    for (xml_files_abs_paths) |xml_file| {
        const c_file = try std.fmt.allocPrint(b.allocator, "{s}/{s}.c", .{ output_dir, std.fs.path.stem(xml_file) });
        try generated_files.append(c_file);
    }

    return generated_files.toOwnedSlice();
}
