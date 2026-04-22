const std = @import("std");

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) !void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});

    const md4c = b.dependency("md4c", .{
        .target = target,
        .optimize = optimize,
    });

    const anyascii = b.dependency("anyascii", .{
        .target = target,
        .optimize = optimize,
    });

    const yaml = b.dependency("yaml", .{
        .target = target,
        .optimize = optimize,
    });

    const lexbor = b.dependency("lexbor", .{
        .target = target,
        .optimize = optimize,
    });

    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "topaz",
        .root_module = root_module,
    });

    root_module.link_libc = true;

    root_module.addIncludePath(md4c.path("src"));
    root_module.addCSourceFile(.{ .file = md4c.path("src/md4c.c") });

    root_module.addImport("yaml", yaml.module("yaml"));

    root_module.addIncludePath(anyascii.path("impl/c"));
    root_module.addCSourceFile(.{ .file = anyascii.path("impl/c/anyascii.c") });

    const src_abs = lexbor.path("source").getPath(b);
    var src_dir = try std.fs.openDirAbsolute(src_abs, .{ .iterate = true });
    var files: std.ArrayListUnmanaged([]const u8) = .empty;
    var walker = try src_dir.walk(b.allocator);
    defer walker.deinit();
    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".c")) continue;
        if (target.result.os.tag == .windows) {
            if (std.mem.indexOf(u8, entry.path, "posix") != null) continue;
        } else {
            if (std.mem.indexOf(u8, entry.path, "windows_nt") != null) continue;
        }
        try files.append(b.allocator, b.dupe(entry.path));
    }

    const lexbor_lib = b.addLibrary(.{
        .linkage = .static,
        .name = "lexbor",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    lexbor_lib.addIncludePath(lexbor.path("source"));
    lexbor_lib.addCSourceFiles(.{
        .root = lexbor.path("source"),
        .files = files.items,
        .flags = &.{ "-std=c99", "-DLEXBOR_STATIC", "-w" },
    });
    root_module.addIncludePath(lexbor.path("source"));
    root_module.linkLibrary(lexbor_lib);

    // This declares intent for the executable to be installed into the
    // standard location when the user invokes the "install" step (the default
    // step when running `zig build`).
    b.installArtifact(exe);

    // This *creates* a Run step in the build graph, to be executed when another
    // step is evaluated that depends on it. The next line below will establish
    // such a dependency.
    const run_cmd = b.addRunArtifact(exe);

    // By making the run step depend on the install step, it will be run from the
    // installation directory rather than directly from within the cache directory.
    // This is not necessary, however, if the application depends on other installed
    // files, this ensures they will be present and in the expected location.
    run_cmd.step.dependOn(b.getInstallStep());

    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // This creates a build step. It will be visible in the `zig build --help` menu,
    // and can be selected like this: `zig build run`
    // This will evaluate the `run` step rather than the default, which is "install".
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const exe_unit_tests = b.addTest(.{
        .root_module = root_module,
    });

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    // Similar to creating the run step earlier, this exposes a `test` step to
    // the `zig build --help` menu, providing a way for the user to request
    // running the unit tests.
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);
}
