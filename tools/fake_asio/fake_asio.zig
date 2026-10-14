//! テスト用の偽 ASIO ドライバ（COM の in-proc サーバーの DLL）。実機の無い環境（Wine）で
//! `src/audio/asio.zig` の関数表の並び・構造体の配置・コールバックの往復を確かめるためのもの。配布しない。
//!
//! 入力0 に 1kHz・-6dBFS の正弦波（Int32LSB）を流し、ホストが出力0 に書いた値を次の周期で読み返して、
//! 「入力 × 期待する倍率」と一致したブロック数を数える。結果は stop 時に標準エラーへ出す。
//!
//! 登録（Wine の例）:
//!   reg add "HKLM\SOFTWARE\ASIO\Fake ASIO" /v CLSID /d "{8F2E7A51-3C1B-4E5A-9B7D-2A6C1E0F4D33}"
//!   reg add "HKCR\CLSID\{8F2E7A51-3C1B-4E5A-9B7D-2A6C1E0F4D33}\InprocServer32" /ve /d "<パス>\fake_asio.dll"
const std = @import("std");
const windows = std.os.windows;
const GUID = windows.GUID;
const HRESULT = windows.HRESULT;

const clsid_fake = GUID{ .Data1 = 0x8F2E7A51, .Data2 = 0x3C1B, .Data3 = 0x4E5A, .Data4 = .{ 0x9B, 0x7D, 0x2A, 0x6C, 0x1E, 0x0F, 0x4D, 0x33 } };
const iid_iunknown = GUID{ .Data1 = 0, .Data2 = 0, .Data3 = 0, .Data4 = .{ 0xC0, 0, 0, 0, 0, 0, 0, 0x46 } };
const iid_iclassfactory = GUID{ .Data1 = 1, .Data2 = 0, .Data3 = 0, .Data4 = .{ 0xC0, 0, 0, 0, 0, 0, 0, 0x46 } };

const S_OK: HRESULT = 0;
const S_FALSE: HRESULT = 1;
const E_NOINTERFACE: HRESULT = @bitCast(@as(u32, 0x80004002));
const CLASS_E_CLASSNOTAVAILABLE: HRESULT = @bitCast(@as(u32, 0x80040111));
const ase_ok: c_long = 0;
const ase_invalid_parameter: c_long = -998;

const BufferInfo = extern struct { is_input: c_long, channel_num: c_long, buffers: [2]?*anyopaque };
const ChannelInfo = extern struct { channel: c_long, is_input: c_long, is_active: c_long, channel_group: c_long, sample_type: c_long, name: [32]u8 };
const Callbacks = extern struct {
    buffer_switch: *const fn (c_long, c_long) callconv(.c) void,
    sample_rate_did_change: *const fn (f64) callconv(.c) void,
    asio_message: *const fn (c_long, c_long, ?*anyopaque, ?*f64) callconv(.c) c_long,
    buffer_switch_time_info: *const fn (?*anyopaque, c_long, c_long) callconv(.c) ?*anyopaque,
};

const frames_pref = 128;
const max_bufs = 8;

// ---- ドライバ本体（1つだけ） ----

const Driver = extern struct { vtbl: *const anyopaque };

var driver = Driver{ .vtbl = @ptrCast(&asio_vtbl) };
var rate: f64 = 48000;
var frames: usize = frames_pref;
var cbs: ?Callbacks = null;
var bufs: [max_bufs]BufferInfo = undefined;
var nbufs: usize = 0;
var storage: [max_bufs][2][4096]i32 = undefined;
var thread: ?std.Thread = null;
var running = std.atomic.Value(bool).init(false);
var phase: f64 = 0;
var switches: u64 = 0;
var matched: u64 = 0;
var checked: u64 = 0;
var last_input: [4096]i32 = undefined;

fn qi(self: *anyopaque, iid: *const GUID, out: *?*anyopaque) callconv(.c) HRESULT {
    _ = iid;
    out.* = self;
    return S_OK;
}
fn addRef(_: *anyopaque) callconv(.c) u32 {
    return 1;
}
fn release(_: *anyopaque) callconv(.c) u32 {
    return 0;
}
fn init(_: *anyopaque, _: ?*anyopaque) callconv(.c) c_long {
    return 1;
}
fn getDriverName(_: *anyopaque, name: [*]u8) callconv(.c) void {
    const s = "Fake ASIO";
    @memcpy(name[0..s.len], s);
    name[s.len] = 0;
}
fn getDriverVersion(_: *anyopaque) callconv(.c) c_long {
    return 1;
}
fn getErrorMessage(_: *anyopaque, s: [*]u8) callconv(.c) void {
    s[0] = 0;
}
fn start(_: *anyopaque) callconv(.c) c_long {
    running.store(true, .release);
    thread = std.Thread.spawn(.{}, run, .{}) catch return -1000;
    return ase_ok;
}
fn stop(_: *anyopaque) callconv(.c) c_long {
    running.store(false, .release);
    if (thread) |t| t.join();
    thread = null;
    std.debug.print("[fake asio] bufferSwitch {d} 回・素通しの照合 {d}/{d} ブロック一致\n", .{ switches, matched, checked });
    return ase_ok;
}
fn getChannels(_: *anyopaque, i: *c_long, o: *c_long) callconv(.c) c_long {
    i.* = 2;
    o.* = 2;
    return ase_ok;
}
fn getLatencies(_: *anyopaque, i: *c_long, o: *c_long) callconv(.c) c_long {
    i.* = @intCast(frames);
    o.* = @intCast(frames * 2);
    return ase_ok;
}
fn getBufferSize(_: *anyopaque, mn: *c_long, mx: *c_long, pref: *c_long, gran: *c_long) callconv(.c) c_long {
    mn.* = 32;
    mx.* = 2048;
    pref.* = frames_pref;
    gran.* = -1;
    return ase_ok;
}
fn canSampleRate(_: *anyopaque, r: f64) callconv(.c) c_long {
    return if (r == 44100 or r == 48000) ase_ok else -995;
}
fn getSampleRate(_: *anyopaque, r: *f64) callconv(.c) c_long {
    r.* = rate;
    return ase_ok;
}
fn setSampleRate(_: *anyopaque, r: f64) callconv(.c) c_long {
    rate = r;
    return ase_ok;
}
fn getClockSources(_: *anyopaque, _: ?*anyopaque, n: *c_long) callconv(.c) c_long {
    n.* = 0;
    return ase_ok;
}
fn setClockSource(_: *anyopaque, _: c_long) callconv(.c) c_long {
    return ase_ok;
}
fn getSamplePosition(_: *anyopaque, _: ?*anyopaque, _: ?*anyopaque) callconv(.c) c_long {
    return ase_ok;
}
fn getChannelInfo(_: *anyopaque, ci: *ChannelInfo) callconv(.c) c_long {
    ci.is_active = 1;
    ci.channel_group = 0;
    ci.sample_type = 18; // Int32LSB
    const s = if (ci.is_input != 0) "Fake In" else "Fake Out";
    @memcpy(ci.name[0..s.len], s);
    ci.name[s.len] = 0;
    return ase_ok;
}
fn createBuffers(_: *anyopaque, infos: [*]BufferInfo, n: c_long, size: c_long, cb: *const Callbacks) callconv(.c) c_long {
    if (n <= 0 or n > max_bufs or size <= 0 or size > 4096) return ase_invalid_parameter;
    nbufs = @intCast(n);
    frames = @intCast(size);
    for (0..nbufs) |i| {
        infos[i].buffers = .{ &storage[i][0], &storage[i][1] };
        @memset(&storage[i][0], 0);
        @memset(&storage[i][1], 0);
        bufs[i] = infos[i];
    }
    cbs = cb.*;
    // ホストが申告どおりのメッセージに答えるか
    const v = cb.asio_message(2, 0, null, null);
    std.debug.print("[fake asio] createBuffers {d} ch × {d} フレーム・engineVersion={d}\n", .{ nbufs, frames, v });
    return ase_ok;
}
fn disposeBuffers(_: *anyopaque) callconv(.c) c_long {
    cbs = null;
    return ase_ok;
}
fn controlPanel(_: *anyopaque) callconv(.c) c_long {
    return ase_ok;
}
fn future(_: *anyopaque, _: c_long, _: ?*anyopaque) callconv(.c) c_long {
    return ase_invalid_parameter;
}
fn outputReady(_: *anyopaque) callconv(.c) c_long {
    return ase_ok;
}

const asio_vtbl = [_]*const anyopaque{
    @ptrCast(&qi),             @ptrCast(&addRef),         @ptrCast(&release),
    @ptrCast(&init),           @ptrCast(&getDriverName),  @ptrCast(&getDriverVersion),
    @ptrCast(&getErrorMessage), @ptrCast(&start),         @ptrCast(&stop),
    @ptrCast(&getChannels),    @ptrCast(&getLatencies),   @ptrCast(&getBufferSize),
    @ptrCast(&canSampleRate),  @ptrCast(&getSampleRate),  @ptrCast(&setSampleRate),
    @ptrCast(&getClockSources), @ptrCast(&setClockSource), @ptrCast(&getSamplePosition),
    @ptrCast(&getChannelInfo), @ptrCast(&createBuffers),  @ptrCast(&disposeBuffers),
    @ptrCast(&controlPanel),   @ptrCast(&future),         @ptrCast(&outputReady),
};

/// 期待する倍率（P1 を --gain-db 0 で動かす前提＝1.0）で、出力0 が直前の入力0 と一致するか。
fn verifyOutput(half: usize) void {
    var out_idx: ?usize = null;
    for (bufs[0..nbufs], 0..) |b, i| {
        if (b.is_input == 0 and b.channel_num == 0) out_idx = i;
    }
    const oi = out_idx orelse return;
    checked += 1;
    const out = storage[oi][half][0..frames];
    for (out, last_input[0..frames]) |o, src| {
        // Int32 → float → Int32 の往復で最下位が数ビットずれるのは許す
        if (@abs(@as(i64, o) - @as(i64, src)) > 256) return;
    }
    matched += 1;
}

fn run() void {
    var half: usize = 0;
    const period_ns: f64 = @as(f64, @floatFromInt(frames)) / rate * 1e9;
    // 絶対時刻で次の周期を待つ（sleep を積み重ねると Wine では周期が 25% ずれた）
    const t0 = std.time.Instant.now() catch return;
    while (running.load(.acquire)) {
        const cb = cbs orelse break;
        // 前の周期にホストが書いた出力を確かめてから、次の入力を作る
        if (switches > 0) verifyOutput(half ^ 1);
        for (bufs[0..nbufs], 0..) |b, i| {
            if (b.is_input == 0) continue;
            for (storage[i][half][0..frames], 0..) |*s, k| {
                const v: i32 = @intFromFloat(@sin(phase + @as(f64, @floatFromInt(k)) * 2.0 * std.math.pi * 1000.0 / rate) * 0.5 * 2147483647.0);
                s.* = v;
                if (b.channel_num == 0) last_input[k] = v;
            }
        }
        phase += @as(f64, @floatFromInt(frames)) * 2.0 * std.math.pi * 1000.0 / rate;
        cb.buffer_switch(@intCast(half), 1);
        switches += 1;
        half ^= 1;
        const due: u64 = @intFromFloat(@as(f64, @floatFromInt(switches)) * period_ns);
        const now = std.time.Instant.now() catch return;
        const elapsed = now.since(t0);
        if (due > elapsed) std.Thread.sleep(due - elapsed);
    }
}

// ---- クラスファクトリと DLL の入口 ----

const Factory = extern struct { vtbl: *const anyopaque };
var factory = Factory{ .vtbl = @ptrCast(&factory_vtbl) };

fn fCreateInstance(_: *anyopaque, outer: ?*anyopaque, iid: *const GUID, out: *?*anyopaque) callconv(.c) HRESULT {
    _ = outer;
    _ = iid;
    out.* = &driver;
    return S_OK;
}
fn fLockServer(_: *anyopaque, _: c_int) callconv(.c) HRESULT {
    return S_OK;
}
const factory_vtbl = [_]*const anyopaque{ @ptrCast(&qi), @ptrCast(&addRef), @ptrCast(&release), @ptrCast(&fCreateInstance), @ptrCast(&fLockServer) };

export fn DllGetClassObject(clsid: *const GUID, iid: *const GUID, out: *?*anyopaque) callconv(.winapi) HRESULT {
    if (!std.mem.eql(u8, std.mem.asBytes(clsid), std.mem.asBytes(&clsid_fake))) return CLASS_E_CLASSNOTAVAILABLE;
    if (!std.mem.eql(u8, std.mem.asBytes(iid), std.mem.asBytes(&iid_iclassfactory)) and
        !std.mem.eql(u8, std.mem.asBytes(iid), std.mem.asBytes(&iid_iunknown))) return E_NOINTERFACE;
    out.* = &factory;
    return S_OK;
}

export fn DllCanUnloadNow() callconv(.winapi) HRESULT {
    return S_FALSE;
}
