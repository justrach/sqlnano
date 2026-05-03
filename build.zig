const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lib_mod = b.createModule(.{
        .root_source_file = b.path("src/sqlnano.zig"),
        .target = target,
        .optimize = optimize,
    });

    const lib = b.addLibrary(.{
        .name = "sqlnano",
        .root_module = lib_mod,
        .linkage = .static,
    });
    b.installArtifact(lib);

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "sqlnano",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run sqlnano");
    run_step.dependOn(&run_cmd.step);

    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/sqlnano.zig"),
        .target = target,
        .optimize = optimize,
    });

    const unit_tests = b.addTest(.{
        .root_module = test_mod,
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    const catalog_comment_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/sqlnano.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .filters = &.{"parse create table columns with line comments between definitions"},
    });
    const run_catalog_comment_tests = b.addRunArtifact(catalog_comment_tests);
    const catalog_comment_step = b.step("test-catalog-comments", "Run CREATE TABLE comment parsing regression test");
    catalog_comment_step.dependOn(&run_catalog_comment_tests.step);

    const table_stop_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/sqlnano.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .filters = &.{"scan table foreach stops after caller sets stop_after"},
    });
    const run_table_stop_tests = b.addRunArtifact(table_stop_tests);
    const table_stop_step = b.step("test-table-stop", "Run row scanner early-stop regression test");
    table_stop_step.dependOn(&run_table_stop_tests.step);

    const table_overflow_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/sqlnano.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .filters = &.{"scan table foreach alloc reads overflow payload"},
    });
    const run_table_overflow_tests = b.addRunArtifact(table_overflow_tests);
    const table_overflow_step = b.step("test-table-overflow", "Run overflow row scanner regression test");
    table_overflow_step.dependOn(&run_table_overflow_tests.step);

    const fts5_bm25_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/sqlnano.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .filters = &.{"sqlite fts5 bm25"},
    });
    const run_fts5_bm25_tests = b.addRunArtifact(fts5_bm25_tests);
    const fts5_bm25_step = b.step("test-fts5-bm25", "Run SQLite FTS5 BM25 scoring regression tests");
    fts5_bm25_step.dependOn(&run_fts5_bm25_tests.step);

    const fts5_search_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/sqlnano.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .filters = &.{"sqlite fts5"},
    });
    const run_fts5_search_tests = b.addRunArtifact(fts5_search_tests);
    const fts5_search_step = b.step("test-fts5-search", "Run SQLite FTS5 search/index regression tests");
    fts5_search_step.dependOn(&run_fts5_search_tests.step);

    const atomic_step = b.step("test-atomic", "Run targeted sgjudge-read regression tests");
    atomic_step.dependOn(&run_catalog_comment_tests.step);
    atomic_step.dependOn(&run_table_stop_tests.step);
    atomic_step.dependOn(&run_table_overflow_tests.step);
    atomic_step.dependOn(&run_fts5_bm25_tests.step);
    atomic_step.dependOn(&run_fts5_search_tests.step);
}
