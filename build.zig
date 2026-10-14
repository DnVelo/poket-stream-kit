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

        // P1 の画面版（素の Win32・PSK_ENGINE §6.2）
        const gui_mod = b.createModule(.{
            .root_source_file = b.path("src/p1_gui.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        gui_mod.addCSourceFile(.{ .file = b.path("src/audio/psk_ma.c"), .flags = &.{"-std=c99"} });
        gui_mod.addIncludePath(b.path("src/third_party/miniaudio"));
        for ([_][]const u8{ "ole32", "advapi32", "user32", "gdi32", "comctl32" }) |lib| gui_mod.linkSystemLibrary(lib, .{});
        const gui = b.addExecutable(.{ .name = "psk-p1-gui", .root_module = gui_mod });
        gui.subsystem = .Windows; // コンソール窓を出さない
        b.installArtifact(gui);
        const gui_run = b.addRunArtifact(gui);
        b.step("p1-gui", "P1 確認用プログラムの画面版を開く").dependOn(&gui_run.step);

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
