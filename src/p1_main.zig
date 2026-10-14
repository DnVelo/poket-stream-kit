//! P1 確認用プログラム（PSK_IMPLEMENTATION_STATUS §1.5）。
//!
//! Creative ASIO を Zig から直接開いてマイクをヘッドホンへ素通しし、同時に miniaudio で
//! VB-CABLE へ同じ音を出す。1秒ごとに ASIO とクロック橋渡しの統計を出し、`psk-p1.log` にも残す。
//!
//! 確かめること: ASIO の直叩きが動くか・詰められるバッファの下限・ASIO とケーブルの同時運用・
//! 橋渡しの音切れとずれ・Creative ASIO の排他性（`--shared-test`）。
const std = @import("std");
const asio = @import("audio/asio.zig");
const ma = @import("audio/ma.zig");
const DriftFifo = @import("audio/drift_fifo.zig").DriftFifo;

extern "kernel32" fn SetConsoleOutputCP(cp: c_uint) callconv(.winapi) c_int;

const usage =
    \\psk-p1 — P1 確認用プログラム
    \\
    \\  psk-p1 --list                    ASIO ドライバと、再生・録音デバイスの一覧
    \\  psk-p1 [オプション]               マイクをヘッドホンへ素通しし、同じ音を VB-CABLE へ出す
    \\
    \\  --driver <名前の一部>   ASIO ドライバ（既定: 名前に Creative を含むもの → 無ければ最初のもの）
    \\  --buffer <フレーム数>   ASIO のバッファ（既定: ドライバの推奨値）
    \\  --rate <Hz>             ASIO のサンプルレート（既定: 48000）
    \\  --in-ch <番号>          使う ASIO 入力チャンネル（既定: 0）
    \\  --gain-db <dB>          ヘッドホンとケーブルへ出す音量（既定: 0）
    \\  --cable <名前の一部>    出力先の仮想ケーブル（既定: "CABLE Input"）
    \\  --no-cable              ケーブルへは出さない（ASIO だけを試す）
    \\  --target-ms <ms>        橋渡しの目標の水位（既定: 30）
    \\  --shared-test <名前の一部>
    \\                          ASIO を開く前に、そのデバイスで小さな 440Hz を共有モードで鳴らし始める
    \\                          （Creative ASIO と Windows の音が同時に鳴るかの確認）
    \\  --seconds <秒>          指定秒で終わる（既定: Enter を押すまで）
    \\
;

const Options = struct {
    list: bool = false,
    driver: ?[]const u8 = null,
    buffer: ?u32 = null,
    rate: f64 = 48000,
    in_ch: u32 = 0,
    gain_db: f32 = 0,
    cable: ?[]const u8 = "CABLE Input",
    target_ms: f64 = 30,
    shared_test: ?[]const u8 = null,
    seconds: ?u32 = null,
};

// ---- ログ（画面と psk-p1.log の両方へ） ----

var log_file: ?std.fs.File = null;

fn log(comptime fmt: []const u8, args: anytype) void {
    var buf: [2048]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch return;
    std.debug.print("{s}", .{s});
    if (log_file) |f| f.writeAll(s) catch {};
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

/// `--shared-test`: 共有モードで小さな 440Hz を鳴らし続ける。
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

// ---- 終了の合図（Enter） ----

var quit = std.atomic.Value(bool).init(false);

fn waitEnter() void {
    var buf: [64]u8 = undefined;
    _ = std.fs.File.stdin().read(&buf) catch {};
    quit.store(true, .release);
}

// ---- 本体 ----

pub fn main() !void {
    _ = SetConsoleOutputCP(65001);
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);
    const opts = parseArgs(args) catch {
        std.debug.print("{s}", .{usage});
        return;
    };

    log_file = std.fs.cwd().createFile("psk-p1.log", .{}) catch null;
    defer if (log_file) |f| f.close();

    // COM の初期化は ASIO（STA）を miniaudio より先に（asio.initCom の説明）
    if (!asio.initCom()) log("COM の初期化（STA）に失敗しました。ASIO は開けません。\n", .{});
    defer asio.deinitCom();

    if (ma.psk_ma_init() != 0) {
        log("miniaudio の初期化に失敗しました\n", .{});
        return;
    }
    defer ma.psk_ma_uninit();

    var drivers: [16]asio.DriverEntry = undefined;
    const ndrv = asio.listDrivers(&drivers);

    if (opts.list) {
        printList(drivers[0..ndrv]);
        return;
    }

    const entry = pickDriver(drivers[0..ndrv], opts.driver) orelse {
        log("ASIO ドライバが見つかりません。--list で一覧を確認してください。\n", .{});
        printList(drivers[0..ndrv]);
        return;
    };

    const ctx = try alloc.create(Ctx);
    defer alloc.destroy(ctx);
    ctx.* = .{ .fifo = try DriftFifo.init(alloc, 1 << 15) };
    defer ctx.fifo.deinit(alloc);
    ctx.gain_bits.store(@bitCast(std.math.pow(f32, 10.0, opts.gain_db / 20.0)), .monotonic);
    ctx.fifo.setTargetLatencyMs(opts.target_ms);

    // 1) 共有モードのテスト音（ASIO より先に鳴らす）
    var tone_dev: ?*ma.Device = null;
    defer ma.psk_ma_close(tone_dev);
    if (opts.shared_test) |name| {
        var zname: [256:0]u8 = undefined;
        var err: c_int = 0;
        tone_dev = ma.psk_ma_open(0, toZ(&zname, name), 2, toneCallback, ctx, &err);
        if (tone_dev) |d| {
            ctx.tone_rate = @floatFromInt(ma.psk_ma_sample_rate(d));
            const r = ma.psk_ma_start(d);
            log("[共有テスト] {s} で 440Hz を鳴らし始めました（start={d}）\n", .{ ma.psk_ma_name(d), r });
        } else {
            log("[共有テスト] \"{s}\" を開けませんでした（err={d}）\n", .{ name, err });
        }
    }

    // 2) ケーブル（miniaudio の再生）
    var cable_dev: ?*ma.Device = null;
    defer ma.psk_ma_close(cable_dev);
    if (opts.cable) |name| {
        var zname: [256:0]u8 = undefined;
        var err: c_int = 0;
        cable_dev = ma.psk_ma_open(0, toZ(&zname, name), 2, cableCallback, ctx, &err);
        if (cable_dev) |d| {
            ctx.fifo.setReaderSampleRate(@floatFromInt(ma.psk_ma_sample_rate(d)));
            log("[ケーブル] {s}  {d} Hz  周期 {d} フレーム\n", .{ ma.psk_ma_name(d), ma.psk_ma_sample_rate(d), ma.psk_ma_period_frames(d) });
        } else {
            log("[ケーブル] \"{s}\" を開けませんでした（err={d}）。--list で名前を確認してください。\n", .{ name, err });
        }
    }

    // 3) ASIO
    const in_chs = [_]u32{opts.in_ch};
    const info = asio.open(alloc, entry, .{
        .sample_rate = opts.rate,
        .buffer_frames = opts.buffer,
        .input_channels = &in_chs,
        .output_channels = &.{ 0, 1 },
    }, asioProcess, ctx) catch |e| {
        log("[ASIO] {s} を開けませんでした: {s}  {s}\n", .{ entry.nameSlice(), @errorName(e), std.mem.sliceTo(&asio.last_error_message, 0) });
        return;
    };
    defer asio.close(alloc);
    ctx.fifo.setWriterSampleRate(info.sample_rate);

    const sr = info.sample_rate;
    log("[ASIO] {s}（{s}）\n", .{ entry.nameSlice(), std.mem.sliceTo(&info.driver_name, 0) });
    log("       入力 {d} ch / 出力 {d} ch  サンプルレート {d:.0} Hz\n", .{ info.num_inputs, info.num_outputs, sr });
    log("       バッファ 最小 {d} / 最大 {d} / 推奨 {d} / 刻み {d} → 使用 {d}（{d:.2} ms）\n", .{ info.min_frames, info.max_frames, info.preferred_frames, info.granularity, info.buffer_frames, @as(f64, @floatFromInt(info.buffer_frames)) * 1000.0 / sr });
    log("       ドライバ申告の遅延 入力 {d} / 出力 {d} フレーム（往復 {d:.2} ms）\n", .{ info.input_latency, info.output_latency, @as(f64, @floatFromInt(info.input_latency + info.output_latency)) * 1000.0 / sr });
    log("       サンプル形式 入力 {s} / 出力 {s}  outputReady {s}\n", .{ asio.sampleTypeName(info.input_type), asio.sampleTypeName(info.output_type), if (info.output_ready_supported) "あり" else "なし" });

    if (cable_dev) |d| {
        const r = ma.psk_ma_start(d);
        if (r != 0) log("[ケーブル] 開始に失敗（{d}）\n", .{r}) else ctx.push_enabled.store(true, .release);
    }

    if (opts.seconds == null) {
        log("動作中。Enter で終了します。\n", .{});
        const t = try std.Thread.spawn(.{}, waitEnter, .{});
        t.detach();
    }

    // 4) 1秒ごとの統計
    const expected_cb = sr / @as(f64, @floatFromInt(info.buffer_frames));
    var last_cb: u64 = 0;
    var last_cable: u64 = 0;
    var elapsed: u32 = 0;
    log("秒  コールバック/秒(期待)  最大間隔ms  最大処理us  入力ピークdBFS | 橋渡し 水位ms  補正ppm  音切れ  あふれ  ケーブル読み取り/秒\n", .{});
    while (!quit.load(.acquire)) {
        std.Thread.sleep(std.time.ns_per_s);
        elapsed += 1;
        const cb = asio.stats.callbacks.load(.monotonic);
        const gap_ms = @as(f64, @floatFromInt(asio.stats.max_gap_ns.swap(0, .monotonic))) / 1e6;
        const proc_us = @as(f64, @floatFromInt(asio.stats.max_process_ns.swap(0, .monotonic))) / 1e3;
        const peak: f32 = @bitCast(ctx.in_peak_bits.swap(0, .monotonic));
        const peak_db = if (peak > 0) 20.0 * std.math.log10(peak) else -120.0;
        const cable_now = ctx.cable_frames.load(.monotonic);
        log("{d:>3}  {d:>6} ({d:>6.1})  {d:>8.2}  {d:>9.1}  {d:>8.1} | {d:>6.1}{s}  {d:>6.0}  {d:>5}  {d:>5}  {d:>8}\n", .{
            elapsed,                             cb - last_cb,                     expected_cb,
            gap_ms,                              proc_us,                          peak_db,
            ctx.fifo.fillMs(),                   if (ctx.fifo.isBuffering()) "*" else " ",
            ctx.fifo.correctionPpm(),            ctx.fifo.underruns.load(.monotonic),
            ctx.fifo.overruns.load(.monotonic), cable_now - last_cable,
        });
        last_cb = cb;
        last_cable = cable_now;
        if (asio.stats.reset_requested.swap(false, .acq_rel)) log("[ASIO] ドライバがリセットを要求しました\n", .{});
        if (asio.stats.rate_changed.swap(false, .acq_rel)) log("[ASIO] サンプルレートが変わりました\n", .{});
        if (opts.seconds) |s| if (elapsed >= s) break;
    }

    log("終了。再同期 {d} 回・過負荷 {d} 回・橋渡しの音切れ {d} 回・あふれ {d} 回\n", .{
        asio.stats.resyncs.load(.monotonic), asio.stats.overloads.load(.monotonic),
        ctx.fifo.underruns.load(.monotonic), ctx.fifo.overruns.load(.monotonic),
    });
}

fn parseArgs(args: []const [:0]u8) !Options {
    var o = Options{};
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--list")) {
            o.list = true;
        } else if (std.mem.eql(u8, a, "--no-cable")) {
            o.cable = null;
        } else {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            const v = args[i];
            if (std.mem.eql(u8, a, "--driver")) o.driver = v
            else if (std.mem.eql(u8, a, "--buffer")) o.buffer = try std.fmt.parseInt(u32, v, 10)
            else if (std.mem.eql(u8, a, "--rate")) o.rate = try std.fmt.parseFloat(f64, v)
            else if (std.mem.eql(u8, a, "--in-ch")) o.in_ch = try std.fmt.parseInt(u32, v, 10)
            else if (std.mem.eql(u8, a, "--gain-db")) o.gain_db = try std.fmt.parseFloat(f32, v)
            else if (std.mem.eql(u8, a, "--cable")) o.cable = v
            else if (std.mem.eql(u8, a, "--target-ms")) o.target_ms = try std.fmt.parseFloat(f64, v)
            else if (std.mem.eql(u8, a, "--shared-test")) o.shared_test = v
            else if (std.mem.eql(u8, a, "--seconds")) o.seconds = try std.fmt.parseInt(u32, v, 10)
            else return error.UnknownOption;
        }
    }
    return o;
}

fn pickDriver(drivers: []asio.DriverEntry, want: ?[]const u8) ?*asio.DriverEntry {
    const needle = want orelse "Creative";
    for (drivers) |*d| if (std.mem.indexOf(u8, d.nameSlice(), needle) != null) return d;
    if (want == null and drivers.len > 0) return &drivers[0];
    return null;
}

fn printList(drivers: []const asio.DriverEntry) void {
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
