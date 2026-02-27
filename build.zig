// SPDX-FileCopyrightText: © 2024 Jeffrey C. Ollie
// SPDX-License-Identifier: MIT

const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const uriparser = b.dependency("uriparser", .{});

    const module = b.addModule(
        "uriparser",
        .{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
        },
    );

    module.addIncludePath(uriparser.path("include"));

    const uri_h = b.addTranslateC(.{
        .root_source_file = uriparser.path("include/uriparser/Uri.h"),
        .target = target,
        .optimize = optimize,
    });
    uri_h.addIncludePath(uriparser.path("include"));

    module.addImport("Uri.h", uri_h.createModule());

    module.addConfigHeader(
        b.addConfigHeader(
            .{
                .style = .{
                    .cmake = uriparser.path("src/UriConfig.h.in"),
                },
            },
            .{
                .PROJECT_VERSION = "0.9.7",
                .HAVE_WPRINTF = true,
                .HAVE_REALLOCARRAY = false,
            },
        ),
    );

    module.addCSourceFiles(
        .{
            .root = uriparser.path("src"),
            .flags = &.{},
            .files = &.{
                "UriCommon.c",
                "UriCompare.c",
                "UriEscape.c",
                "UriFile.c",
                "UriIp4Base.c",
                "UriIp4.c",
                "UriMemory.c",
                "UriNormalizeBase.c",
                "UriNormalize.c",
                "UriParseBase.c",
                "UriParse.c",
                "UriQuery.c",
                "UriRecompose.c",
                "UriResolve.c",
                "UriShorten.c",
            },
        },
    );

    const tests = b.addTest(.{
        .root_module = module,
    });

    const test_run = b.addRunArtifact(tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&test_run.step);
}
