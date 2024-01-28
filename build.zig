const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const uriparser = b.dependency("uriparser", .{});
    const lib = try buildUriparser(b, uriparser, target, optimize);
    b.installArtifact(lib);

    const module = b.addModule(
        "uriparser",
        .{
            .root_source_file = .{
                .path = "src/root.zig",
            },
            .target = target,
            .optimize = optimize,
        },
    );

    module.addIncludePath(uriparser.path("include"));

    if (target.query.isNative()) {
        const tests = b.addTest(.{
            .root_source_file = .{ .path = "src/root.zig" },
            .target = target,
            .optimize = optimize,
        });

        tests.linkLibrary(lib);
        const test_run = b.addRunArtifact(tests);

        const test_step = b.step("test", "Run unit tests");
        test_step.dependOn(&test_run.step);
    }
}

fn buildUriparser(
    b: *std.Build,
    upstream: *std.Build.Dependency,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) !*std.Build.Step.Compile {
    const lib = b.addStaticLibrary(.{
        .name = "uriparser",
        .target = target,
        .optimize = optimize,
    });

    lib.linkLibC();
    lib.addIncludePath(upstream.path("include"));

    lib.addConfigHeader(
        b.addConfigHeader(
            .{
                .style = .{
                    .cmake = upstream.path("src/UriConfig.h.in"),
                },
            },
            .{
                .PACKAGE_VERSION = "0.9.7",
                .HAVE_WPRINTF = true,
                .HAVE_REALLOCARRAY = false,
            },
        ),
    );

    var flags = std.ArrayList([]const u8).init(b.allocator);
    defer flags.deinit();
    try flags.appendSlice(&.{});

    lib.addCSourceFiles(
        .{
            .dependency = upstream,
            .flags = flags.items,
            .files = &.{
                "src/UriCommon.c",
                "src/UriCompare.c",
                "src/UriEscape.c",
                "src/UriFile.c",
                "src/UriIp4Base.c",
                "src/UriIp4.c",
                "src/UriMemory.c",
                "src/UriNormalizeBase.c",
                "src/UriNormalize.c",
                "src/UriParseBase.c",
                "src/UriParse.c",
                "src/UriQuery.c",
                "src/UriRecompose.c",
                "src/UriResolve.c",
                "src/UriShorten.c",
            },
        },
    );

    lib.installHeadersDirectoryOptions(
        .{
            .source_dir = upstream.path("include/uriparser"),
            .install_dir = .header,
            .install_subdir = "",
            .include_extensions = &.{".h"},
        },
    );

    return lib;
}
