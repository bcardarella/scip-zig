const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "scip-zig",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const exe_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(exe_tests).step);

    // "index" step: self-index the project
    const index_cmd = b.addRunArtifact(exe);
    index_cmd.addArgs(&.{ "--root-path" });
    index_cmd.addDirectoryArg(b.path("."));
    index_cmd.addArgs(&.{ "--pkg", "scip-zig" });
    index_cmd.addFileArg(b.path("src/main.zig"));
    index_cmd.addArgs(&.{ "--root-pkg", "scip-zig" });
    const index_step = b.step("index", "Generate SCIP index for this project");
    index_step.dependOn(&index_cmd.step);
}

/// Helper for dependent projects to add a SCIP indexing step.
///
/// Usage in your build.zig:
/// ```zig
/// const scip_dep = b.dependency("scip-zig", .{});
/// const scip_zig = @import("scip-zig");
/// const index_step = scip_zig.addIndexStep(b, scip_dep, .{
///     .root_source_file = b.path("src/main.zig"),
///     .package_name = "my-project",
///     .extra_packages = &.{
///         .{ .name = "my-lib", .root_source_file = b.dependency("my-lib", .{}).path("src/root.zig") },
///     },
/// });
/// const step = b.step("index", "Generate SCIP index");
/// step.dependOn(&index_step.step);
/// ```
pub const PackageDescription = struct {
    name: []const u8,
    root_source_file: std.Build.LazyPath,
};

pub fn addIndexStep(
    b: *std.Build,
    dep: *std.Build.Dependency,
    options: struct {
        root_source_file: std.Build.LazyPath,
        package_name: []const u8 = "main",
        root_path: ?std.Build.LazyPath = null,
        extra_packages: []const PackageDescription = &.{},
    },
) *std.Build.Step.Run {
    const run = b.addRunArtifact(dep.artifact("scip-zig"));
    run.addArgs(&.{"--root-path"});
    run.addDirectoryArg(options.root_path orelse b.path("."));
    // Add the root package
    run.addArgs(&.{ "--pkg", options.package_name });
    run.addFileArg(options.root_source_file);
    // Add extra dependency packages
    for (options.extra_packages) |pkg| {
        run.addArgs(&.{ "--pkg", pkg.name });
        run.addFileArg(pkg.root_source_file);
    }
    run.addArgs(&.{ "--root-pkg", options.package_name });
    return run;
}
