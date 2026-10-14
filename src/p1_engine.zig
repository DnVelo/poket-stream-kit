//! P1 の音の部分（PSK_IMPLEMENTATION_STATUS §1.5）。コマンド版（p1_main.zig）と画面版（p1_gui.zig）で共有する。
//!
//! ASIO の入力1チャンネルを全出力へ素通しし、同じ音をクロックの橋渡しを通して VB-CABLE へ出す。
//! 共有モードのテスト音（ASIO を開く前に Windows 側で鳴らし始める）も持つ。
//!
//! スレッド: start / stop / tick / log はメインスレッドだけから呼ぶ。音のコールバックは
//! Ctx の原子変数と橋渡しの FIFO だけを触る（PSK_ENGINE §4 の約束）。
const std = @import("std");
const asio = @import("audio/asio.zig");
const ma = @import("audio/ma.zig");
const DriftFifo = @import("audio/drift_fifo.zig").DriftFifo;

pub const Config = struct {
    buffer: ?u32 = null, // null ならドライバの推奨値
    rate: f64 = 48000,
    in_ch: u32 = 0,
    gain_db: f32 = 0,
    cable: ?[]const u8 = "CABLE Input", // 名前の一部。null なら出さない
    target_ms: f64 = 30,
    shared_test: ?[]const u8 = null, // 名前の一部。null なら鳴らさない
    sys_handle: ?*anyopaque = null,
};

// ---- ログ（呼び出し側の出力先と、exe の隣の psk-p1.log の両方へ） ----

pub var sink: *const fn ([]const u8) void = defaultSink;
var log_file: ?std.fs.File = null;

fn defaultSink(s: []const u8) void {
    std.debug.print("{s}", .{s});
}

pub fn log(comptime fmt: []const u8, args: anytype) void {
    var buf: [2048]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch return;
    sink(s);
    if (log_file) |f| f.writeAll(s) catch {};
}

/// exe と同じフォルダに psk-p1.log を作る（ダブルクリック起動でも場所が変わらないように）。
/// exe の場所は GetModuleFileNameW で直接調べる（Zig 標準の selfExeDirPath は Wine で Unexpected になった）。
/// それでも分からなければ、今いるフォルダに作る。
pub fn openLogFile(alloc: std.mem.Allocator) void {
    _ = alloc;
    var w: [1024]u16 = undefined;
    const n = GetModuleFileNameW(null, &w, w.len);
    if (n > 0 and n < w.len) {
        var utf8: [3072]u8 = undefined;
        if (std.unicode.utf16LeToUtf8(&utf8, w[0..n])) |len| {
            if (std.fs.path.dirnameWindows(utf8[0..len])) |dir| {
                if (std.fs.openDirAbsolute(dir, .{})) |d_| {
                    var d = d_;
                    defer d.close();
                    if (d.createFile("psk-p1.log", .{})) |f| {
                        log_file = f;
                        return;
                    } else |_| {}
                } else |_| {}
            }
        } else |_| {}
    }
    log_file = std.fs.cwd().createFile("psk-p1.log", .{}) catch |e| blk: {
        log("[ログ] psk-p1.log を作れません: {s}\n", .{@errorName(e)});
        break :blk null;
    };
}

extern "kernel32" fn GetModuleFileNameW(module: ?*anyopaque, buf: [*]u16, size: u32) callconv(.winapi) u32;

pub fn closeLogFile() void {
    if (log_file) |f| f.close();
    log_file = null;
}

// ---- 音のスレッドで使う状態 ----

const max_pull = 4096;

const Ctx = struct {
    fifo: DriftFifo,
    gain_bits: std.atomic.Value(u32) = .init(@bitCast(@as(f32, 1))),
    push_enabled: std.atomic.Value(bool) = .init(false), // ケーブルを開いたときだけ橋渡しへ入れる（読み手がいないと全部あふれる）
    in_peak_bits: std.atomic.Value(u32) = .init(0),
    cable_frames: std.atomic.Value(u64) = .init(0), // ケーブルが読んだ総フレーム数（実際の速さを見る）
    pull_l: [max_pull]f32 = undefined,
    pull_r: [max_pull]f32 = undefined,
    tone_phase: f64 = 0,
    tone_rate: f64 = 48000,
};

fn storePeak(v: *std.atomic.Value(u32), x: f32) void {
    const old: f32 = @bitCast(v.load(.monotonic));
    if (x > old) v.store(@bitCast(x), .monotonic);
}

/// ASIO のコールバック: 入力1チャンネルを全出力へ素通しし、同じ音を橋渡しの FIFO へ入れる。
fn asioProcess(user: ?*anyopaque, inputs: []const []const f32, outputs: []const []f32) void {
    const ctx: *Ctx = @ptrCast(@alignCast(user.?));
    const gain: f32 = @bitCast(ctx.gain_bits.load(.monotonic));
    if (outputs.len == 0) return;
    const out0 = outputs[0];

    if (inputs.len == 0) {
        @memset(out0, 0);
    } else {
        var peak: f32 = 0;
        for (out0, inputs[0]) |*o, s| {
            peak = @max(peak, @abs(s));
            o.* = s * gain;
        }
        storePeak(&ctx.in_peak_bits, peak);
    }
    for (outputs[1..]) |o| @memcpy(o, out0);
    if (ctx.push_enabled.load(.monotonic)) ctx.fifo.push(out0, out0);
}

/// ケーブル（miniaudio の再生）: 橋渡しの FIFO から読んで、インターリーブで書く。
fn cableCallback(user: ?*anyopaque, out: ?[*]f32, in: ?[*]const f32, frames: c_uint, channels: c_uint) callconv(.c) void {
    _ = in;
    const ctx: *Ctx = @ptrCast(@alignCast(user.?));
    const dst = out orelse return;
    _ = ctx.cable_frames.fetchAdd(frames, .monotonic);
    var done: usize = 0;
    while (done < frames) {
        const n = @min(@as(usize, frames) - done, max_pull);
        ctx.fifo.pull(ctx.pull_l[0..n], ctx.pull_r[0..n]);
        for (0..n) |i| {
            const base = (done + i) * channels;
            dst[base] = ctx.pull_l[i];
            if (channels > 1) dst[base + 1] = ctx.pull_r[i];
            var c: usize = 2;
            while (c < channels) : (c += 1) dst[base + c] = 0;
        }
        done += n;
    }
}

/// 共有モードのテスト音: 小さな 440Hz を鳴らし続ける。
fn toneCallback(user: ?*anyopaque, out: ?[*]f32, in: ?[*]const f32, frames: c_uint, channels: c_uint) callconv(.c) void {
    _ = in;
    const ctx: *Ctx = @ptrCast(@alignCast(user.?));
    const dst = out orelse return;
    const amp: f32 = 0.1; // -20 dBFS
    for (0..frames) |i| {
        const s: f32 = amp * @as(f32, @floatCast(@sin(ctx.tone_phase)));
        ctx.tone_phase += 2.0 * std.math.pi * 440.0 / ctx.tone_rate;
        if (ctx.tone_phase > 2.0 * std.math.pi) ctx.tone_phase -= 2.0 * std.math.pi;
        for (0..channels) |c| dst[i * channels + c] = s;
    }
}

// ---- エンジン ----

pub const Engine = struct {
    alloc: std.mem.Allocator,
    ctx: *Ctx,
    tone_dev: ?*ma.Device = null,
    cable_dev: ?*ma.Device = null,
    running: bool = false,
    info: asio.Info = .{},
    elapsed: u32 = 0,
    last_cb: u64 = 0,
    last_cable: u64 = 0,

    pub fn create(alloc: std.mem.Allocator) !*Engine {
        const ctx = try alloc.create(Ctx);
        errdefer alloc.destroy(ctx);
        ctx.* = .{ .fifo = try DriftFifo.init(alloc, 1 << 15) };
        const self = try alloc.create(Engine);
        self.* = .{ .alloc = alloc, .ctx = ctx };
        return self;
    }

    pub fn destroy(self: *Engine) void {
        self.stop();
        self.ctx.fifo.deinit(self.alloc);
        self.alloc.destroy(self.ctx);
        self.alloc.destroy(self);
    }

    pub fn setGainDb(self: *Engine, db: f32) void {
        self.ctx.gain_bits.store(@bitCast(std.math.pow(f32, 10.0, db / 20.0)), .monotonic);
    }

    /// 開始する。失敗したら開いたものを閉じて false を返す（理由はログに出す）。
    pub fn start(self: *Engine, entry: *const asio.DriverEntry, cfg: Config) bool {
        if (self.running) return true;
        const ctx = self.ctx;
        ctx.push_enabled.store(false, .release);
        ctx.fifo.underruns.store(0, .monotonic);
        ctx.fifo.overruns.store(0, .monotonic);
        ctx.cable_frames.store(0, .monotonic);
        ctx.fifo.setTargetLatencyMs(cfg.target_ms);
        self.setGainDb(cfg.gain_db);
        self.elapsed = 0;
        self.last_cb = 0;
        self.last_cable = 0;

        // 1) 共有モードのテスト音（ASIO より先に鳴らす）
        if (cfg.shared_test) |name| {
            var zname: [256:0]u8 = undefined;
            var err: c_int = 0;
            self.tone_dev = ma.psk_ma_open(0, toZ(&zname, name), 2, toneCallback, ctx, &err);
            if (self.tone_dev) |d| {
                ctx.tone_rate = @floatFromInt(ma.psk_ma_sample_rate(d));
                const r = ma.psk_ma_start(d);
                log("[共有テスト] {s} で 440Hz を鳴らし始めました（start={d}）\n", .{ ma.psk_ma_name(d), r });
            } else {
                log("[共有テスト] \"{s}\" を開けませんでした（err={d}）\n", .{ name, err });
            }
        }

        // 2) ケーブル（miniaudio の再生）
        if (cfg.cable) |name| {
            var zname: [256:0]u8 = undefined;
            var err: c_int = 0;
            self.cable_dev = ma.psk_ma_open(0, toZ(&zname, name), 2, cableCallback, ctx, &err);
            if (self.cable_dev) |d| {
                ctx.fifo.setReaderSampleRate(@floatFromInt(ma.psk_ma_sample_rate(d)));
                log("[ケーブル] {s}  {d} Hz  周期 {d} フレーム\n", .{ ma.psk_ma_name(d), ma.psk_ma_sample_rate(d), ma.psk_ma_period_frames(d) });
            } else {
                log("[ケーブル] \"{s}\" を開けませんでした（err={d}）\n", .{ name, err });
            }
        }

        // 3) ASIO
        const in_chs = [_]u32{cfg.in_ch};
        self.info = asio.open(self.alloc, entry, .{
            .sample_rate = cfg.rate,
            .buffer_frames = cfg.buffer,
            .input_channels = &in_chs,
            .output_channels = &.{ 0, 1 },
            .sys_handle = cfg.sys_handle,
        }, asioProcess, ctx) catch |e| {
            log("[ASIO] {s} を開けませんでした: {s}  {s}\n", .{ entry.nameSlice(), @errorName(e), std.mem.sliceTo(&asio.last_error_message, 0) });
            self.closeDevices();
            return false;
        };
        ctx.fifo.setWriterSampleRate(self.info.sample_rate);
        self.running = true;

        const info = &self.info;
        const sr = info.sample_rate;
        log("[ASIO] {s}（{s}）\n", .{ entry.nameSlice(), std.mem.sliceTo(&info.driver_name, 0) });
        log("       入力 {d} ch / 出力 {d} ch  サンプルレート {d:.0} Hz  使う入力 ch {d}  音量 {d:.1} dB\n", .{ info.num_inputs, info.num_outputs, sr, cfg.in_ch, cfg.gain_db });
        log("       バッファ 最小 {d} / 最大 {d} / 推奨 {d} / 刻み {d} → 使用 {d}（{d:.2} ms）\n", .{ info.min_frames, info.max_frames, info.preferred_frames, info.granularity, info.buffer_frames, @as(f64, @floatFromInt(info.buffer_frames)) * 1000.0 / sr });
        log("       ドライバ申告の遅延 入力 {d} / 出力 {d} フレーム（往復 {d:.2} ms）\n", .{ info.input_latency, info.output_latency, @as(f64, @floatFromInt(info.input_latency + info.output_latency)) * 1000.0 / sr });
        log("       サンプル形式 入力 {s} / 出力 {s}  outputReady {s}\n", .{ asio.sampleTypeName(info.input_type), asio.sampleTypeName(info.output_type), if (info.output_ready_supported) "あり" else "なし" });

        if (self.cable_dev) |d| {
            const r = ma.psk_ma_start(d);
            if (r != 0) log("[ケーブル] 開始に失敗（{d}）\n", .{r}) else ctx.push_enabled.store(true, .release);
        }
        log("秒  コールバック/秒(期待)  最大間隔ms  最大処理us  入力ピークdBFS | 橋渡し 水位ms  補正ppm  音切れ  あふれ  ケーブル読み取り/秒\n", .{});
        return true;
    }

    /// 1秒ごとに呼ぶ。統計を1行ログへ出す。
    pub fn tick(self: *Engine) void {
        if (!self.running) return;
        const ctx = self.ctx;
        self.elapsed += 1;
        const expected_cb = self.info.sample_rate / @as(f64, @floatFromInt(self.info.buffer_frames));
        const cb = asio.stats.callbacks.load(.monotonic);
        const gap_ms = @as(f64, @floatFromInt(asio.stats.max_gap_ns.swap(0, .monotonic))) / 1e6;
        const proc_us = @as(f64, @floatFromInt(asio.stats.max_process_ns.swap(0, .monotonic))) / 1e3;
        const peak: f32 = @bitCast(ctx.in_peak_bits.swap(0, .monotonic));
        const peak_db = if (peak > 0) 20.0 * std.math.log10(peak) else -120.0;
        const cable_now = ctx.cable_frames.load(.monotonic);
        log("{d:>3}  {d:>6} ({d:>6.1})  {d:>8.2}  {d:>9.1}  {d:>8.1} | {d:>6.1}{s}  {d:>6.0}  {d:>5}  {d:>5}  {d:>8}\n", .{
            self.elapsed,                        cb - self.last_cb,                expected_cb,
            gap_ms,                              proc_us,                          peak_db,
            ctx.fifo.fillMs(),                   if (ctx.fifo.isBuffering()) "*" else " ",
            ctx.fifo.correctionPpm(),            ctx.fifo.underruns.load(.monotonic),
            ctx.fifo.overruns.load(.monotonic), cable_now - self.last_cable,
        });
        self.last_cb = cb;
        self.last_cable = cable_now;
        if (asio.stats.reset_requested.swap(false, .acq_rel)) log("[ASIO] ドライバがリセットを要求しました\n", .{});
        if (asio.stats.rate_changed.swap(false, .acq_rel)) log("[ASIO] サンプルレートが変わりました\n", .{});
    }

    pub fn stop(self: *Engine) void {
        if (!self.running) {
            self.closeDevices();
            return;
        }
        self.ctx.push_enabled.store(false, .release);
        asio.close(self.alloc);
        self.running = false;
        log("停止。再同期 {d} 回・過負荷 {d} 回・橋渡しの音切れ {d} 回・あふれ {d} 回\n", .{
            asio.stats.resyncs.load(.monotonic),        asio.stats.overloads.load(.monotonic),
            self.ctx.fifo.underruns.load(.monotonic), self.ctx.fifo.overruns.load(.monotonic),
        });
        self.closeDevices();
    }

    fn closeDevices(self: *Engine) void {
        ma.psk_ma_close(self.cable_dev);
        self.cable_dev = null;
        ma.psk_ma_close(self.tone_dev);
        self.tone_dev = null;
    }
};

// ---- 一覧 ----

pub fn printList(drivers: []const asio.DriverEntry) void {
    log("ASIO ドライバ（{d} 件）\n", .{drivers.len});
    for (drivers) |*d| log("  {s}\n", .{d.nameSlice()});
    for ([_]c_int{ 0, 1 }) |capture| {
        const n = ma.psk_ma_device_count(capture);
        log("{s}デバイス（{d} 件）\n", .{ if (capture == 1) "録音" else "再生", n });
        var i: c_int = 0;
        while (i < n) : (i += 1) {
            var buf: [256]u8 = undefined;
            const len = ma.psk_ma_device_name(capture, i, &buf, buf.len);
            if (len > 0) log("  {s}\n", .{buf[0..@intCast(len)]});
        }
    }
}

fn toZ(buf: *[256:0]u8, s: []const u8) [*:0]const u8 {
    const n = @min(s.len, buf.len);
    @memcpy(buf[0..n], s[0..n]);
    buf[n] = 0;
    return buf;
}
