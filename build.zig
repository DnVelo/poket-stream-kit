const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    // 既定は ReleaseSafe。Gear-vk では -Doptimize 未指定のままずっと Debug で測っていた（同リポの記憶 builds-were-debug-until-0825）。
    const optimize = b.option(std.builtin.OptimizeMode, "optimize", "最適化（既定: ReleaseSafe）") orelse .ReleaseSafe;

    // ---- テスト（どの OS でも回る部分） ----
    const test_step = b.step("test", "単体テストを回す");
    for ([_][]const u8{ "src/audio/drift_fifo.zig", "src/audio/asio.zig" }) |path| {
        const t = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path(path),
            .target = target,
            .optimize = optimize,
        }) });
        test_step.dependOn(&b.addRunArtifact(t).step);
    }

    // ---- P1 確認用プログラム（Windows 専用: ASIO を直接呼ぶ） ----
    if (target.result.os.tag == .windows) {
        const mod = b.createModule(.{
            .root_source_file = b.path("src/p1_main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        mod.addCSourceFile(.{ .file = b.path("src/audio/psk_ma.c"), .flags = &.{"-std=c99"} });
        mod.addIncludePath(b.path("src/third_party/miniaudio"));
        mod.linkSystemLibrary("ole32", .{});
        mod.linkSystemLibrary("advapi32", .{});
        const exe = b.addExecutable(.{ .name = "psk-p1", .root_module = mod });
        b.installArtifact(exe);

        const run = b.addRunArtifact(exe);
        if (b.args) |a| run.addArgs(a);
        b.step("p1", "P1 確認用プログラムを動かす（引数は -- の後ろ）").dependOn(&run.step);

        // テスト用の偽 ASIO ドライバ（実機の無い環境で asio.zig を確かめる・配布しない）
        const fake = b.addLibrary(.{ .name = "fake_asio", .linkage = .dynamic, .root_module = b.createModule(.{
            .root_source_file = b.path("tools/fake_asio/fake_asio.zig"),
            .target = target,
            .optimize = optimize,
        }) });
        const install_fake = b.addInstallArtifact(fake, .{});
        b.step("fake-asio", "テスト用の偽 ASIO ドライバを作る").dependOn(&install_fake.step);
    }
}
