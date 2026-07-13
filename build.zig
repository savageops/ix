const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe_module = createIxModule(b, target, optimize);
    const exe = b.addExecutable(.{
        .name = "ix-zig",
        .root_module = exe_module,
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run ix-zig");
    run_step.dependOn(&run_cmd.step);

    const unit_tests = b.addTest(.{
        .root_module = createIxModule(b, target, optimize),
    });

    const test_cmd = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run Zig unit tests");
    test_step.dependOn(&test_cmd.step);

    const delta_overlay_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/core/delta_overlay.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const delta_overlay_test_cmd = b.addRunArtifact(delta_overlay_tests);
    test_step.dependOn(&delta_overlay_test_cmd.step);
}

fn createIxModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        // link_libc is required because StringZilla's AVX2 headers pull in
        // immintrin.h -> xmmintrin.h -> mm_malloc.h -> stdlib.h.
        .link_libc = true,
    });

    // StringZilla SIMD search kernels are compiled from a C shim that wraps
    // the header-only library into linkable symbols for Zig's extern fn FFI.
    // -mavx2 is x86-only; gate it so the build works on ARM/AArch64.
    const arch = target.result.cpu.arch;
    const is_x86 = arch == .x86_64 or arch == .x86;
    var sz_flags: std.ArrayList([]const u8) = .empty;
    sz_flags.appendSlice(b.allocator, &.{
        "-O3",
        "-DNDEBUG",
        "-std=c11",
    }) catch unreachable;
    if (is_x86) sz_flags.append(b.allocator, "-mavx2") catch unreachable;
    root_module.addCSourceFile(.{
        .file = b.path("src/sz_shim.c"),
        .flags = sz_flags.items,
    });
    root_module.addIncludePath(b.path(".refs/stringzilla/include"));

    // PCRE2 JIT regex engine — replaces recursive backtracking for
    // regex_full strategy patterns. Compiled from vendored source with
    // JIT enabled for native machine code regex execution.
    root_module.addCSourceFiles(.{
        .files = &.{
            ".refs/pcre2/src/pcre2_auto_possess.c",
            ".refs/pcre2/src/pcre2_chartables.c",
            ".refs/pcre2/src/pcre2_chkdint.c",
            ".refs/pcre2/src/pcre2_compile.c",
            ".refs/pcre2/src/pcre2_config.c",
            ".refs/pcre2/src/pcre2_context.c",
            ".refs/pcre2/src/pcre2_convert.c",
            ".refs/pcre2/src/pcre2_dfa_match.c",
            ".refs/pcre2/src/pcre2_error.c",
            ".refs/pcre2/src/pcre2_extuni.c",
            ".refs/pcre2/src/pcre2_find_bracket.c",
            ".refs/pcre2/src/pcre2_jit_compile.c",
            ".refs/pcre2/src/pcre2_maketables.c",
            ".refs/pcre2/src/pcre2_match.c",
            ".refs/pcre2/src/pcre2_match_data.c",
            ".refs/pcre2/src/pcre2_newline.c",
            ".refs/pcre2/src/pcre2_ord2utf.c",
            ".refs/pcre2/src/pcre2_pattern_info.c",
            ".refs/pcre2/src/pcre2_script_run.c",
            ".refs/pcre2/src/pcre2_serialize.c",
            ".refs/pcre2/src/pcre2_string_utils.c",
            ".refs/pcre2/src/pcre2_study.c",
            ".refs/pcre2/src/pcre2_substitute.c",
            ".refs/pcre2/src/pcre2_substring.c",
            ".refs/pcre2/src/pcre2_tables.c",
            ".refs/pcre2/src/pcre2_ucd.c",
            ".refs/pcre2/src/pcre2_valid_utf.c",
            ".refs/pcre2/src/pcre2_xclass.c",
        },
        .flags = &.{
            "-DHAVE_CONFIG_H",
            "-DPCRE2_CODE_UNIT_WIDTH=8",
            "-DPCRE2_STATIC",
            "-O3",
            "-DNDEBUG",
        },
    });
    root_module.addIncludePath(b.path(".refs/pcre2/src"));

    return root_module;
}
