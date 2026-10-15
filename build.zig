const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("zigfmt", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "zigfmt",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zigfmt", .module = mod },
            },
        }),
    });

    // `zig build` builds into zig-out for development.
    const dev_step = b.step("dev", "Build zigfmt into zig-out");
    dev_step.dependOn(&b.addInstallArtifact(exe, .{}).step);
    b.default_step = dev_step;

    // `zig build install` copies zigfmt to `<prefix>/bin`. The build
    // system's `--prefix` can't be given another default than zig-out, so
    // this uses its own option.
    b.install_tls.description = "Install zigfmt to <prefix>/bin (see -Dprefix)";
    const installer = b.addExecutable(.{
        .name = "install",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/install.zig"),
            .target = b.graph.host,
        }),
    });
    const install_cmd = b.addRunArtifact(installer);
    install_cmd.addArtifactArg(exe);
    // The default, ~/.local, is resolved by the installer (see tools/install.zig).
    if (b.option([]const u8, "prefix", "Where `zig build install` puts bin/zigfmt (default: ~/.local)")) |prefix| {
        install_cmd.addArg(prefix);
    }
    install_cmd.has_side_effects = true;
    b.getInstallStep().dependOn(&install_cmd.step);

    const run_step = b.step("run", "Run zigfmt");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.addPassthruArgs();

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = mod })).step);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = exe.root_module })).step);

    // Formats every file under the given directories with several configs
    // and checks the results (see tools/corpus.zig). For example:
    //     zig build corpus -Doptimize=ReleaseSafe -- /path/to/zig/lib
    const corpus = b.addExecutable(.{
        .name = "corpus",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/corpus.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zigfmt", .module = mod },
            },
        }),
    });
    const corpus_cmd = b.addRunArtifact(corpus);
    corpus_cmd.addPassthruArgs();
    b.step("corpus", "Check formatter invariants over a directory of Zig files").dependOn(&corpus_cmd.step);
}
