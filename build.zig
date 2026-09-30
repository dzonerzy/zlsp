//! Build script for zlsp
//!
//! You can use this directly with `zig build`, or use `pyoz build` for
//! automatic Python configuration detection.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Strip option (can be set via -Dstrip=true or from pyoz CLI)
    const strip = b.option(bool, "strip", "Strip debug symbols from the binary") orelse false;

    // Python Stable ABI (abi3): one wheel for CPython 3.10+. `pyoz build`
    // enables it from `abi3 = true` in pyproject.toml; with plain
    // `zig build`, pass -Dabi3=true.
    const abi3 = b.option(bool, "abi3", "Build for the Python Stable ABI (abi3)") orelse false;

    // Get PyOZ dependency
    const pyoz_dep = b.dependency("PyOZ", .{
        .target = target,
        .optimize = optimize,
        .abi3 = abi3,
    });

    // Create the user's lib module
    const user_lib_mod = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
        // libc is required for the Python C API
        .link_libc = true,
        .imports = &.{
            .{ .name = "PyOZ", .module = pyoz_dep.module("PyOZ") },
        },
    });

    // Single source for the version string returned by zlsp.version()
    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", @import("build.zig.zon").version);
    user_lib_mod.addOptions("build_options", build_options);

    // Build the Python extension as a dynamic library
    const lib = b.addLibrary(.{
        .name = "zlsp",
        .linkage = .dynamic,
        .root_module = user_lib_mod,
    });

    // Extensions get the Python C API from the interpreter at load time, not
    // from a library: macOS needs this (-undefined dynamic_lookup).
    if (target.result.os.tag == .macos) lib.linker_allow_shlib_undefined = true;

    // On Windows, link against the Python stable ABI library (python3.lib).
    // These options are passed automatically by `pyoz build`.
    // For manual `zig build` on Windows, pass: -Dpython-lib-dir=<path> -Dpython-lib-name=python3
    if (b.option([]const u8, "python-lib-dir", "Python library directory")) |lib_dir| {
        user_lib_mod.addLibraryPath(.{ .cwd_relative = lib_dir });
    }
    if (b.option([]const u8, "python-lib-name", "Python library name")) |lib_name| {
        user_lib_mod.linkSystemLibrary(lib_name, .{ .use_pkg_config = .no });
    }

    // Extension depends on the *target* OS (.pyd for Windows, .so otherwise),
    // so cross-compiling from Linux to Windows produces a correct .pyd
    const ext = if (target.result.os.tag == .windows) ".pyd" else ".so";

    // Install the shared library
    const install = b.addInstallArtifact(lib, .{
        .dest_sub_path = b.fmt("zlsp{s}", .{ext}),
    });
    b.getInstallStep().dependOn(&install.step);

}
