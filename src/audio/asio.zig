//! ASIO ドライバを Zig から直接呼ぶ（PSK_ENGINE §1.2・RtAudio は使わない）。Windows x64 専用。
//!
//! 64bit の Windows では ASIO のインターフェースは素の COM で、関数表の呼び出し規約は既定の x64 規約になる
//! （32bit の thiscall の問題は起きない）。関数表とコールバックの並びは ASIO SDK 2.3.4 の
//! `iasiodrv.h` / `asio.h` に合わせてある（SDK は GPLv3 を選択・自分用で配布しない・PSK_VISION §1.1）。
//!
//! ASIO のコールバックには利用者のポインタを渡す口が無いので、開いているドライバは1つだけとして
//! モジュール内の変数で持つ（ASIO 自体も1プロセス1ドライバが前提）。
const std = @import("std");
const windows = std.os.windows;

const HRESULT = windows.HRESULT;
const GUID = windows.GUID;
const HKEY = windows.HKEY;

pub const AsioBool = c_long;
pub const AsioError = c_long;
pub const ase_ok: AsioError = 0;

pub const SampleType = enum(c_long) {
    int16_msb = 0,
    int24_msb = 1,
    int32_msb = 2,
    float32_msb = 3,
    float64_msb = 4,
    int32_msb16 = 8,
    int32_msb18 = 9,
    int32_msb20 = 10,
    int32_msb24 = 11,
    int16_lsb = 16,
    int24_lsb = 17,
    int32_lsb = 18,
    float32_lsb = 19,
    float64_lsb = 20,
    int32_lsb16 = 24,
    int32_lsb18 = 25,
    int32_lsb20 = 26,
    int32_lsb24 = 27,
    _,
};

const BufferInfo = extern struct {
    is_input: AsioBool,
    channel_num: c_long,
    buffers: [2]?*anyopaque,
};

const ChannelInfo = extern struct {
    channel: c_long,
    is_input: AsioBool,
    is_active: AsioBool,
    channel_group: c_long,
    sample_type: SampleType,
    name: [32]u8,
};

const Callbacks = extern struct {
    buffer_switch: *const fn (c_long, AsioBool) callconv(.c) void,
    sample_rate_did_change: *const fn (f64) callconv(.c) void,
    asio_message: *const fn (c_long, c_long, ?*anyopaque, ?*f64) callconv(.c) c_long,
    buffer_switch_time_info: *const fn (?*anyopaque, c_long, AsioBool) callconv(.c) ?*anyopaque,
};

const IAsio = extern struct {
    vtbl: *const Vtbl,

    const Vtbl = extern struct {
        query_interface: *const fn (*IAsio, *const GUID, *?*anyopaque) callconv(.c) HRESULT,
        add_ref: *const fn (*IAsio) callconv(.c) u32,
        release: *const fn (*IAsio) callconv(.c) u32,
        init: *const fn (*IAsio, ?*anyopaque) callconv(.c) AsioBool,
        get_driver_name: *const fn (*IAsio, [*]u8) callconv(.c) void,
        get_driver_version: *const fn (*IAsio) callconv(.c) c_long,
        get_error_message: *const fn (*IAsio, [*]u8) callconv(.c) void,
        start: *const fn (*IAsio) callconv(.c) AsioError,
        stop: *const fn (*IAsio) callconv(.c) AsioError,
        get_channels: *const fn (*IAsio, *c_long, *c_long) callconv(.c) AsioError,
        get_latencies: *const fn (*IAsio, *c_long, *c_long) callconv(.c) AsioError,
        get_buffer_size: *const fn (*IAsio, *c_long, *c_long, *c_long, *c_long) callconv(.c) AsioError,
        can_sample_rate: *const fn (*IAsio, f64) callconv(.c) AsioError,
        get_sample_rate: *const fn (*IAsio, *f64) callconv(.c) AsioError,
        set_sample_rate: *const fn (*IAsio, f64) callconv(.c) AsioError,
        get_clock_sources: *const fn (*IAsio, ?*anyopaque, *c_long) callconv(.c) AsioError,
        set_clock_source: *const fn (*IAsio, c_long) callconv(.c) AsioError,
        get_sample_position: *const fn (*IAsio, ?*anyopaque, ?*anyopaque) callconv(.c) AsioError,
        get_channel_info: *const fn (*IAsio, *ChannelInfo) callconv(.c) AsioError,
        create_buffers: *const fn (*IAsio, [*]BufferInfo, c_long, c_long, *const Callbacks) callconv(.c) AsioError,
        dispose_buffers: *const fn (*IAsio) callconv(.c) AsioError,
        control_panel: *const fn (*IAsio) callconv(.c) AsioError,
        future: *const fn (*IAsio, c_long, ?*anyopaque) callconv(.c) AsioError,
        output_ready: *const fn (*IAsio) callconv(.c) AsioError,
    };
};

// asioMessage のセレクタ（asio.h の列挙の順）
const sel_selector_supported = 1;
const sel_engine_version = 2;
const sel_reset_request = 3;
const sel_resync_request = 5;
const sel_latencies_changed = 6;
const sel_supports_time_info = 7;
const sel_overload = 15;

extern "ole32" fn CoInitializeEx(reserved: ?*anyopaque, coinit: u32) callconv(.winapi) HRESULT;
extern "ole32" fn CoUninitialize() callconv(.winapi) void;
extern "ole32" fn CoCreateInstance(clsid: *const GUID, outer: ?*anyopaque, ctx: u32, iid: *const GUID, out: *?*anyopaque) callconv(.winapi) HRESULT;
extern "ole32" fn CLSIDFromString(sz: [*:0]const u16, clsid: *GUID) callconv(.winapi) HRESULT;
extern "advapi32" fn RegEnumKeyExW(key: HKEY, index: u32, name: [*]u16, name_len: *u32, reserved: ?*u32, class: ?[*]u16, class_len: ?*u32, last_write: ?*anyopaque) callconv(.winapi) i32;
extern "kernel32" fn GetConsoleWindow() callconv(.winapi) ?windows.HWND;

const coinit_apartmentthreaded = 0x2;
const clsctx_inproc_server = 0x1;
const rrf_rt_reg_sz = 0x2;
const max_channels = 8;
const max_frames = 8192;

// ---- ドライバの列挙 ----

pub const DriverEntry = struct {
    name: [128]u8 = undefined,
    name_len: usize = 0,
    clsid: GUID = undefined,

    pub fn nameSlice(self: *const DriverEntry) []const u8 {
        return self.name[0..self.name_len];
    }
};

/// `HKLM\SOFTWARE\ASIO` に登録されたドライバを列挙する。CLSID が読めないものは飛ばす。
pub fn listDrivers(out: []DriverEntry) usize {
    const root_path = std.unicode.utf8ToUtf16LeStringLiteral("SOFTWARE\\ASIO");
    var root: HKEY = undefined;
    if (windows.advapi32.RegOpenKeyExW(windows.HKEY_LOCAL_MACHINE, root_path, 0, windows.KEY_READ, &root) != 0) return 0;
    defer _ = windows.advapi32.RegCloseKey(root);

    var count: usize = 0;
    var index: u32 = 0;
    while (count < out.len) : (index += 1) {
        var name16: [128]u16 = undefined;
        var name_len: u32 = name16.len;
        if (RegEnumKeyExW(root, index, &name16, &name_len, null, null, null, null) != 0) break;
        name16[@min(name_len, name16.len - 1)] = 0;

        var clsid16: [64]u16 = undefined;
        var clsid_bytes: u32 = @sizeOf(@TypeOf(clsid16));
        const value_name = std.unicode.utf8ToUtf16LeStringLiteral("CLSID");
        if (windows.advapi32.RegGetValueW(root, @ptrCast(&name16), value_name, rrf_rt_reg_sz, null, &clsid16, &clsid_bytes) != 0) continue;

        var entry = DriverEntry{};
        if (CLSIDFromString(@ptrCast(&clsid16), &entry.clsid) < 0) continue;
        entry.name_len = std.unicode.utf16LeToUtf8(&entry.name, name16[0..name_len]) catch continue;
        out[count] = entry;
        count += 1;
    }
    return count;
}

// ---- 開いたドライバ ----

/// 音のスレッドで呼ばれる処理。inputs / outputs は浮動小数（-1..1）に変換済みのチャンネルごとの列。
pub const ProcessFn = *const fn (user: ?*anyopaque, inputs: []const []const f32, outputs: []const []f32) void;

pub const OpenOptions = struct {
    sample_rate: f64 = 48000,
    buffer_frames: ?u32 = null, // null ならドライバの推奨値
    input_channels: []const u32 = &.{0},
    output_channels: []const u32 = &.{ 0, 1 },
    /// ドライバの init に渡すウィンドウ（画面のある版はメインウィンドウ・null ならコンソールの窓）
    sys_handle: ?*anyopaque = null,
};

/// 開かずに調べられる、ドライバの能力。
pub const Caps = struct {
    num_inputs: c_long = 0,
    num_outputs: c_long = 0,
    min_frames: c_long = 0,
    max_frames: c_long = 0,
    preferred_frames: c_long = 0,
    granularity: c_long = 0,
    sample_rate: f64 = 0,
    input_names: [max_query_inputs][32]u8 = std.mem.zeroes([max_query_inputs][32]u8),

    pub fn inputName(self: *const Caps, ch: usize) []const u8 {
        return std.mem.sliceTo(&self.input_names[ch], 0);
    }

    /// 受け付けるバッファサイズの候補を out に書き、個数を返す（刻み -1＝2のべき乗・0＝推奨値だけ）。
    pub fn bufferChoices(self: *const Caps, out: []u32) usize {
        var n: usize = 0;
        const lo: u32 = @intCast(@max(self.min_frames, 1));
        const hi: u32 = @intCast(@max(self.max_frames, self.min_frames));
        if (self.granularity == -1) {
            var v: u32 = 1;
            while (v <= hi and n < out.len) : (v *= 2) {
                if (v >= lo) {
                    out[n] = v;
                    n += 1;
                }
            }
        } else if (self.granularity > 0) {
            var v = lo;
            while (v <= hi and n < out.len) : (v += @intCast(self.granularity)) {
                out[n] = v;
                n += 1;
            }
        }
        if (n == 0 and out.len > 0 and self.preferred_frames > 0) {
            out[0] = @intCast(self.preferred_frames);
            n = 1;
        }
        return n;
    }
};

pub const max_query_inputs = 16;

/// ドライバを作って init し、能力を読んで手放す（音は出さない）。ドライバを開いている間は呼ばない。
pub fn query(entry: *const DriverEntry, sys_handle: ?*anyopaque) OpenError!Caps {
    if (g_state != null) return error.CreateFailed;
    if (!com_ready) return error.ComInitFailed;
    var obj: ?*anyopaque = null;
    if (CoCreateInstance(&entry.clsid, null, clsctx_inproc_server, &entry.clsid, &obj) < 0 or obj == null) return error.CreateFailed;
    const drv: *IAsio = @ptrCast(@alignCast(obj.?));
    defer _ = drv.vtbl.release(drv);
    if (drv.vtbl.init(drv, sys_handle orelse GetConsoleWindow()) == 0) {
        drv.vtbl.get_error_message(drv, &last_error_message);
        return error.InitFailed;
    }
    var caps = Caps{};
    _ = drv.vtbl.get_channels(drv, &caps.num_inputs, &caps.num_outputs);
    _ = drv.vtbl.get_buffer_size(drv, &caps.min_frames, &caps.max_frames, &caps.preferred_frames, &caps.granularity);
    _ = drv.vtbl.get_sample_rate(drv, &caps.sample_rate);
    const n: usize = @intCast(@min(@max(caps.num_inputs, 0), max_query_inputs));
    for (0..n) |ch| {
        var ci = ChannelInfo{ .channel = @intCast(ch), .is_input = 1, .is_active = 0, .channel_group = 0, .sample_type = .int32_lsb, .name = std.mem.zeroes([32]u8) };
        if (drv.vtbl.get_channel_info(drv, &ci) == ase_ok) caps.input_names[ch] = ci.name;
    }
    return caps;
}

pub const Info = struct {
    driver_name: [32]u8 = std.mem.zeroes([32]u8),
    num_inputs: c_long = 0,
    num_outputs: c_long = 0,
    min_frames: c_long = 0,
    max_frames: c_long = 0,
    preferred_frames: c_long = 0,
    granularity: c_long = 0,
    buffer_frames: u32 = 0,
    sample_rate: f64 = 0,
    input_latency: c_long = 0,
    output_latency: c_long = 0,
    input_type: SampleType = .int32_lsb,
    output_type: SampleType = .int32_lsb,
    output_ready_supported: bool = false,
};

pub const Stats = struct {
    callbacks: std.atomic.Value(u64) = .init(0),
    max_gap_ns: std.atomic.Value(u64) = .init(0),
    max_process_ns: std.atomic.Value(u64) = .init(0),
    resyncs: std.atomic.Value(u32) = .init(0),
    overloads: std.atomic.Value(u32) = .init(0),
    reset_requested: std.atomic.Value(bool) = .init(false),
    rate_changed: std.atomic.Value(bool) = .init(false),
};

const State = struct {
    driver: *IAsio,
    info: Info,
    buffers: [max_channels * 2]BufferInfo = undefined,
    types: [max_channels * 2]SampleType = undefined,
    num_in: usize = 0,
    num_out: usize = 0,
    in_scratch: [max_channels][max_frames]f32 = undefined,
    out_scratch: [max_channels][max_frames]f32 = undefined,
    in_slices: [max_channels][]const f32 = undefined,
    out_slices: [max_channels][]f32 = undefined,
    process: ProcessFn,
    user: ?*anyopaque,
    last_switch: ?std.time.Instant = null,
    running: bool = false,
};

var g_state: ?*State = null;
pub var stats: Stats = .{};

/// ASIO を開くスレッドを STA で COM 初期化する。**miniaudio（psk_ma_init）より先に**呼ぶこと。
/// miniaudio は同じスレッドを MTA で初期化しようとし、先に MTA にされると ASIO 側の STA 初期化が
/// RPC_E_CHANGED_MODE で失敗する（2026-10-14 に偽ドライバで発覚）。ASIO ドライバは STA 前提のものが多い。
/// 逆に、先に STA にしておけば miniaudio は失敗を無視して進む（自前のスレッドは自分で MTA 初期化する）。
pub fn initCom() bool {
    const hr = CoInitializeEx(null, coinit_apartmentthreaded);
    com_ready = hr >= 0;
    return com_ready;
}

pub fn deinitCom() void {
    if (com_ready) CoUninitialize();
    com_ready = false;
}

var com_ready = false;

pub const OpenError = error{ ComInitFailed, CreateFailed, InitFailed, TooManyChannels, BadChannel, BufferTooLarge, CreateBuffersFailed, StartFailed, OutOfMemory };

/// エラー時に `getErrorMessage` の文字列を入れる。
pub var last_error_message: [128]u8 = std.mem.zeroes([128]u8);

pub fn open(allocator: std.mem.Allocator, entry: *const DriverEntry, opts: OpenOptions, process: ProcessFn, user: ?*anyopaque) OpenError!Info {
    if (g_state != null) close(allocator);
    if (opts.input_channels.len > max_channels or opts.output_channels.len > max_channels) return error.TooManyChannels;
    if (!com_ready) return error.ComInitFailed; // initCom() を先に呼んでいない

    // ASIO の慣例: インターフェース ID にもドライバの CLSID を渡す
    var obj: ?*anyopaque = null;
    if (CoCreateInstance(&entry.clsid, null, clsctx_inproc_server, &entry.clsid, &obj) < 0 or obj == null) return error.CreateFailed;
    const drv: *IAsio = @ptrCast(@alignCast(obj.?));
    errdefer _ = drv.vtbl.release(drv);

    if (drv.vtbl.init(drv, opts.sys_handle orelse GetConsoleWindow()) == 0) {
        drv.vtbl.get_error_message(drv, &last_error_message);
        return error.InitFailed;
    }

    const st = try allocator.create(State);
    errdefer allocator.destroy(st);
    st.* = .{ .driver = drv, .info = .{}, .process = process, .user = user };
    var info = &st.info;

    drv.vtbl.get_driver_name(drv, &info.driver_name);
    _ = drv.vtbl.get_channels(drv, &info.num_inputs, &info.num_outputs);
    _ = drv.vtbl.get_buffer_size(drv, &info.min_frames, &info.max_frames, &info.preferred_frames, &info.granularity);

    if (drv.vtbl.can_sample_rate(drv, opts.sample_rate) == ase_ok) _ = drv.vtbl.set_sample_rate(drv, opts.sample_rate);
    _ = drv.vtbl.get_sample_rate(drv, &info.sample_rate);

    var frames: c_long = info.preferred_frames;
    if (opts.buffer_frames) |want| {
        const w: c_long = @intCast(want);
        if (w >= info.min_frames and w <= info.max_frames) frames = w;
    }
    if (frames > max_frames) return error.BufferTooLarge;
    info.buffer_frames = @intCast(frames);

    var n: usize = 0;
    for (opts.input_channels) |ch| {
        if (ch >= info.num_inputs) return error.BadChannel;
        st.buffers[n] = .{ .is_input = 1, .channel_num = @intCast(ch), .buffers = .{ null, null } };
        n += 1;
    }
    for (opts.output_channels) |ch| {
        if (ch >= info.num_outputs) return error.BadChannel;
        st.buffers[n] = .{ .is_input = 0, .channel_num = @intCast(ch), .buffers = .{ null, null } };
        n += 1;
    }
    st.num_in = opts.input_channels.len;
    st.num_out = opts.output_channels.len;

    g_state = st;
    errdefer g_state = null;
    if (drv.vtbl.create_buffers(drv, &st.buffers, @intCast(n), frames, &callbacks) != ase_ok) {
        drv.vtbl.get_error_message(drv, &last_error_message);
        return error.CreateBuffersFailed;
    }
    errdefer _ = drv.vtbl.dispose_buffers(drv);

    for (0..n) |i| {
        var ci = ChannelInfo{ .channel = st.buffers[i].channel_num, .is_input = st.buffers[i].is_input, .is_active = 0, .channel_group = 0, .sample_type = .int32_lsb, .name = std.mem.zeroes([32]u8) };
        _ = drv.vtbl.get_channel_info(drv, &ci);
        st.types[i] = ci.sample_type;
    }
    if (st.num_in > 0) info.input_type = st.types[0];
    if (st.num_out > 0) info.output_type = st.types[st.num_in];
    _ = drv.vtbl.get_latencies(drv, &info.input_latency, &info.output_latency);

    const f: usize = @intCast(frames);
    for (0..st.num_in) |c| st.in_slices[c] = st.in_scratch[c][0..f];
    for (0..st.num_out) |c| st.out_slices[c] = st.out_scratch[c][0..f];

    // outputReady は createBuffers の後に1回試し、ASE_OK なら以後バッファごとに呼ぶ（asio.h の約束）
    info.output_ready_supported = drv.vtbl.output_ready(drv) == ase_ok;

    stats = .{};
    if (drv.vtbl.start(drv) != ase_ok) {
        drv.vtbl.get_error_message(drv, &last_error_message);
        return error.StartFailed;
    }
    st.running = true;
    return info.*;
}

pub fn close(allocator: std.mem.Allocator) void {
    const st = g_state orelse return;
    const drv = st.driver;
    if (st.running) _ = drv.vtbl.stop(drv);
    _ = drv.vtbl.dispose_buffers(drv);
    _ = drv.vtbl.release(drv);
    g_state = null;
    allocator.destroy(st);
}

pub fn openControlPanel() void {
    if (g_state) |st| _ = st.driver.vtbl.control_panel(st.driver);
}

// ---- コールバック（ドライバのスレッド） ----

const callbacks = Callbacks{
    .buffer_switch = bufferSwitch,
    .sample_rate_did_change = sampleRateDidChange,
    .asio_message = asioMessage,
    .buffer_switch_time_info = bufferSwitchTimeInfo,
};

fn bufferSwitch(index: c_long, direct: AsioBool) callconv(.c) void {
    _ = direct;
    const st = g_state orelse return;
    const t0 = std.time.Instant.now() catch null;
    if (t0) |now| {
        if (st.last_switch) |prev| _ = stats.max_gap_ns.fetchMax(now.since(prev), .monotonic);
        st.last_switch = now;
    }

    const half: usize = @intCast(index);
    const frames = st.info.buffer_frames;
    for (0..st.num_in) |c| {
        const raw = st.buffers[c].buffers[half] orelse continue;
        toFloat(st.types[c], raw, st.in_scratch[c][0..frames]);
    }
    st.process(st.user, st.in_slices[0..st.num_in], st.out_slices[0..st.num_out]);
    for (0..st.num_out) |c| {
        const i = st.num_in + c;
        const raw = st.buffers[i].buffers[half] orelse continue;
        fromFloat(st.types[i], st.out_scratch[c][0..frames], raw);
    }
    if (st.info.output_ready_supported) _ = st.driver.vtbl.output_ready(st.driver);

    _ = stats.callbacks.fetchAdd(1, .monotonic);
    if (t0) |start| {
        if (std.time.Instant.now()) |end| _ = stats.max_process_ns.fetchMax(end.since(start), .monotonic) else |_| {}
    }
}

fn bufferSwitchTimeInfo(params: ?*anyopaque, index: c_long, direct: AsioBool) callconv(.c) ?*anyopaque {
    bufferSwitch(index, direct);
    return params;
}

fn sampleRateDidChange(rate: f64) callconv(.c) void {
    _ = rate;
    stats.rate_changed.store(true, .release);
}

fn asioMessage(selector: c_long, value: c_long, message: ?*anyopaque, opt: ?*f64) callconv(.c) c_long {
    _ = message;
    _ = opt;
    return switch (selector) {
        sel_selector_supported => switch (value) {
            sel_engine_version, sel_reset_request, sel_resync_request, sel_latencies_changed, sel_overload => 1,
            else => 0,
        },
        sel_engine_version => 2,
        sel_reset_request => blk: {
            stats.reset_requested.store(true, .release);
            break :blk 1;
        },
        sel_resync_request => blk: {
            _ = stats.resyncs.fetchAdd(1, .monotonic);
            break :blk 1;
        },
        sel_latencies_changed => 1,
        sel_supports_time_info => 0, // bufferSwitch を使ってもらう
        sel_overload => blk: {
            _ = stats.overloads.fetchAdd(1, .monotonic);
            break :blk 1;
        },
        else => 0,
    };
}

// ---- サンプル形式の変換 ----

fn toFloat(t: SampleType, raw: *anyopaque, out: []f32) void {
    switch (t) {
        .int16_lsb => {
            const p: [*]const i16 = @ptrCast(@alignCast(raw));
            for (out, 0..) |*o, i| o.* = @as(f32, @floatFromInt(p[i])) * (1.0 / 32768.0);
        },
        .int24_lsb => {
            const p: [*]const u8 = @ptrCast(raw);
            for (out, 0..) |*o, i| {
                const b = p[i * 3 ..][0..3];
                const v: i32 = @as(i32, @bitCast(@as(u32, b[0]) << 8 | @as(u32, b[1]) << 16 | @as(u32, b[2]) << 24)) >> 8;
                o.* = @as(f32, @floatFromInt(v)) * (1.0 / 8388608.0);
            }
        },
        .int32_lsb, .int32_lsb16, .int32_lsb18, .int32_lsb20, .int32_lsb24 => {
            const p: [*]const i32 = @ptrCast(@alignCast(raw));
            const scale = 1.0 / @as(f32, @floatFromInt(@as(i64, 1) << @intCast(int32Bits(t) - 1)));
            for (out, 0..) |*o, i| o.* = @as(f32, @floatFromInt(p[i])) * scale;
        },
        .float32_lsb => {
            const p: [*]const f32 = @ptrCast(@alignCast(raw));
            @memcpy(out, p[0..out.len]);
        },
        .float64_lsb => {
            const p: [*]const f64 = @ptrCast(@alignCast(raw));
            for (out, 0..) |*o, i| o.* = @floatCast(p[i]);
        },
        else => @memset(out, 0), // ビッグエンディアン系は x64 の Windows では来ない
    }
}

fn fromFloat(t: SampleType, in: []const f32, raw: *anyopaque) void {
    switch (t) {
        .int16_lsb => {
            const p: [*]i16 = @ptrCast(@alignCast(raw));
            for (in, 0..) |s, i| p[i] = @intFromFloat(std.math.clamp(s, -1.0, 1.0) * 32767.0);
        },
        .int24_lsb => {
            const p: [*]u8 = @ptrCast(raw);
            for (in, 0..) |s, i| {
                const v: i32 = @intFromFloat(std.math.clamp(s, -1.0, 1.0) * 8388607.0);
                const u: u32 = @bitCast(v);
                p[i * 3] = @truncate(u);
                p[i * 3 + 1] = @truncate(u >> 8);
                p[i * 3 + 2] = @truncate(u >> 16);
            }
        },
        .int32_lsb, .int32_lsb16, .int32_lsb18, .int32_lsb20, .int32_lsb24 => {
            const p: [*]i32 = @ptrCast(@alignCast(raw));
            const full: f64 = @floatFromInt((@as(i64, 1) << @intCast(int32Bits(t) - 1)) - 1);
            for (in, 0..) |s, i| p[i] = @intFromFloat(@as(f64, std.math.clamp(s, -1.0, 1.0)) * full);
        },
        .float32_lsb => {
            const p: [*]f32 = @ptrCast(@alignCast(raw));
            @memcpy(p[0..in.len], in);
        },
        .float64_lsb => {
            const p: [*]f64 = @ptrCast(@alignCast(raw));
            for (in, 0..) |s, i| p[i] = s;
        },
        else => {},
    }
}

/// 32bit 容器のうち、実際に使われている下位ビット数。
fn int32Bits(t: SampleType) u6 {
    return switch (t) {
        .int32_lsb16 => 16,
        .int32_lsb18 => 18,
        .int32_lsb20 => 20,
        .int32_lsb24 => 24,
        else => 32,
    };
}

pub fn sampleTypeName(t: SampleType) []const u8 {
    return switch (t) {
        .int16_lsb => "Int16LSB",
        .int24_lsb => "Int24LSB",
        .int32_lsb => "Int32LSB",
        .float32_lsb => "Float32LSB",
        .float64_lsb => "Float64LSB",
        .int32_lsb16 => "Int32LSB16",
        .int32_lsb18 => "Int32LSB18",
        .int32_lsb20 => "Int32LSB20",
        .int32_lsb24 => "Int32LSB24",
        else => "(未対応)",
    };
}

test "バッファサイズの候補" {
    var out: [32]u32 = undefined;
    const pow2 = Caps{ .min_frames = 32, .max_frames = 2048, .preferred_frames = 128, .granularity = -1 };
    const n1 = pow2.bufferChoices(&out);
    try std.testing.expectEqualSlices(u32, &.{ 32, 64, 128, 256, 512, 1024, 2048 }, out[0..n1]);
    const step = Caps{ .min_frames = 48, .max_frames = 192, .preferred_frames = 96, .granularity = 48 };
    const n2 = step.bufferChoices(&out);
    try std.testing.expectEqualSlices(u32, &.{ 48, 96, 144, 192 }, out[0..n2]);
    const fixed = Caps{ .min_frames = 256, .max_frames = 256, .preferred_frames = 256, .granularity = 0 };
    const n3 = fixed.bufferChoices(&out);
    try std.testing.expectEqualSlices(u32, &.{256}, out[0..n3]);
}

test "サンプル形式の往復変換" {
    var raw: [16]i32 = undefined;
    const src = [_]f32{ 0, 0.5, -0.5, 0.999, -1.0, 0.25, -0.125, 0.75 };
    var back: [8]f32 = undefined;
    for ([_]SampleType{ .int16_lsb, .int24_lsb, .int32_lsb, .int32_lsb24, .float32_lsb, .float64_lsb }) |t| {
        fromFloat(t, &src, &raw);
        toFloat(t, &raw, &back);
        for (src, back) |a, b| try std.testing.expectApproxEqAbs(a, b, 1.0 / 16384.0);
    }
}
