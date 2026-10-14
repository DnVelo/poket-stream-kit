//! P1 確認用プログラムの画面版（psk-p1-gui）。音の部分は p1_engine.zig でコマンド版と共通。
//!
//! 作りは Gear-vk の gear-gui と同じ（PSK_ENGINE §6.2）: 純 Zig ＋ 素の Win32 の標準コントロール、依存ゼロ、
//! API は extern で直接呼ぶ、GPU は使わない。できることはコマンド版と同じで、操作をクリックにしただけ。
//!
//! 試験用の引数: `--autostart <秒>` … 起動直後に「開始」を押し、指定秒で停止して閉じる（Wine での通し確認用）。
const std = @import("std");
const asio = @import("audio/asio.zig");
const ma = @import("audio/ma.zig");
const engine = @import("p1_engine.zig");
const pickDriver = @import("p1_main.zig").pickDriver;

const windows = std.os.windows;
const WINAPI: std.builtin.CallingConvention = .winapi;
const HWND = windows.HWND;
const HINSTANCE = windows.HINSTANCE;
const HMENU = windows.HMENU;
const LRESULT = windows.LRESULT;
const WPARAM = windows.WPARAM;
const LPARAM = windows.LPARAM;
const UINT = windows.UINT;
const DWORD = windows.DWORD;
const BOOL = windows.BOOL;

const WS_OVERLAPPEDWINDOW: DWORD = 0x00CF0000;
const WS_VISIBLE: DWORD = 0x10000000;
const WS_CHILD: DWORD = 0x40000000;
const WS_VSCROLL: DWORD = 0x00200000;
const WS_HSCROLL: DWORD = 0x00100000;
const WS_TABSTOP: DWORD = 0x00010000;
const WS_EX_CLIENTEDGE: DWORD = 0x00000200;
const BS_PUSHBUTTON: DWORD = 0x00000000;
const ES_MULTILINE: DWORD = 0x0004;
const ES_READONLY: DWORD = 0x0800;
const ES_AUTOVSCROLL: DWORD = 0x0040;
const ES_AUTOHSCROLL: DWORD = 0x0080;
const CBS_DROPDOWNLIST: DWORD = 0x0003;
const SS_LEFT: DWORD = 0x00000000;
const TBS_HORZ: DWORD = 0x0000;
const TBS_AUTOTICKS: DWORD = 0x0001;

const WM_SIZE: UINT = 0x0005;
const WM_SETTEXT: UINT = 0x000C;
const WM_GETTEXTLENGTH: UINT = 0x000E;
const WM_CLOSE: UINT = 0x0010;
const WM_DESTROY: UINT = 0x0002;
const WM_SETFONT: UINT = 0x0030;
const WM_COMMAND: UINT = 0x0111;
const WM_TIMER: UINT = 0x0113;
const WM_HSCROLL: UINT = 0x0114;
const CB_ADDSTRING: UINT = 0x0143;
const CB_RESETCONTENT: UINT = 0x014B;
const CB_SETCURSEL: UINT = 0x014E;
const CB_GETCURSEL: UINT = 0x0147;
const CBN_SELCHANGE: usize = 1;
const EM_SETSEL: UINT = 0x00B1;
const EM_REPLACESEL: UINT = 0x00C2;
const EM_SETLIMITTEXT: UINT = 0x00C5;
const TBM_GETPOS: UINT = 0x0400;
const TBM_SETPOS: UINT = 0x0405;
const TBM_SETRANGE: UINT = 0x0406;
const TBM_SETTICFREQ: UINT = 0x0414;

const WNDCLASSEXW = extern struct {
    cbSize: UINT,
    style: UINT,
    lpfnWndProc: *const fn (HWND, UINT, WPARAM, LPARAM) callconv(WINAPI) LRESULT,
    cbClsExtra: i32,
    cbWndExtra: i32,
    hInstance: ?HINSTANCE,
    hIcon: ?*anyopaque,
    hCursor: ?*anyopaque,
    hbrBackground: ?*anyopaque,
    lpszMenuName: ?[*:0]const u16,
    lpszClassName: [*:0]const u16,
    hIconSm: ?*anyopaque,
};
const POINT = extern struct { x: i32, y: i32 };
const MSG = extern struct { hwnd: ?HWND, message: UINT, wParam: WPARAM, lParam: LPARAM, time: DWORD, pt: POINT };

extern "user32" fn RegisterClassExW(*const WNDCLASSEXW) callconv(WINAPI) u16;
extern "user32" fn CreateWindowExW(DWORD, ?[*:0]const u16, ?[*:0]const u16, DWORD, i32, i32, i32, i32, ?HWND, ?HMENU, ?HINSTANCE, ?*anyopaque) callconv(WINAPI) ?HWND;
extern "user32" fn DefWindowProcW(HWND, UINT, WPARAM, LPARAM) callconv(WINAPI) LRESULT;
extern "user32" fn GetMessageW(*MSG, ?HWND, UINT, UINT) callconv(WINAPI) i32;
extern "user32" fn TranslateMessage(*const MSG) callconv(WINAPI) BOOL;
extern "user32" fn DispatchMessageW(*const MSG) callconv(WINAPI) LRESULT;
extern "user32" fn PostQuitMessage(i32) callconv(WINAPI) void;
extern "user32" fn SendMessageW(HWND, UINT, WPARAM, LPARAM) callconv(WINAPI) LRESULT;
extern "user32" fn PostMessageW(HWND, UINT, WPARAM, LPARAM) callconv(WINAPI) BOOL;
extern "user32" fn SetTimer(HWND, usize, UINT, ?*anyopaque) callconv(WINAPI) usize;
extern "user32" fn KillTimer(HWND, usize) callconv(WINAPI) BOOL;
extern "user32" fn EnableWindow(HWND, BOOL) callconv(WINAPI) BOOL;
extern "user32" fn DestroyWindow(HWND) callconv(WINAPI) BOOL;
extern "user32" fn SetWindowTextW(HWND, [*:0]const u16) callconv(WINAPI) BOOL;
extern "user32" fn MoveWindow(HWND, i32, i32, i32, i32, BOOL) callconv(WINAPI) BOOL;
extern "user32" fn LoadCursorW(?HINSTANCE, usize) callconv(WINAPI) ?*anyopaque;
extern "gdi32" fn GetStockObject(i32) callconv(WINAPI) ?*anyopaque;
extern "gdi32" fn CreateFontW(i32, i32, i32, i32, i32, DWORD, DWORD, DWORD, DWORD, DWORD, DWORD, DWORD, DWORD, [*:0]const u16) callconv(WINAPI) ?*anyopaque;
extern "kernel32" fn GetModuleHandleW(?[*:0]const u16) callconv(WINAPI) ?HINSTANCE;
extern "comctl32" fn InitCommonControls() callconv(WINAPI) void;

fn L(comptime s: []const u8) [*:0]const u16 {
    return std.unicode.utf8ToUtf16LeStringLiteral(s);
}

// ---- ID ----
const ID_DRIVER: usize = 100;
const ID_BUFFER: usize = 101;
const ID_INCH: usize = 102;
const ID_CABLE: usize = 103;
const ID_SHARED: usize = 104;
const ID_GAIN: usize = 105;
const ID_START: usize = 110;
const ID_STOP: usize = 111;
const ID_REFRESH: usize = 112;
const ID_PANEL: usize = 113;
const ID_LOG: usize = 120;
const TIMER_TICK: usize = 1;

const gain_min_db = -24;
const gain_max_db = 12;
const log_top = 196;

// ---- 状態（メインスレッドだけが触る） ----
var g_alloc: std.mem.Allocator = undefined;
var g_hwnd: ?HWND = null;
var g_inst: ?HINSTANCE = null;
var g_font: ?*anyopaque = null;
var g_mono: ?*anyopaque = null;
var h_driver: HWND = undefined;
var h_buffer: HWND = undefined;
var h_inch: HWND = undefined;
var h_cable: HWND = undefined;
var h_shared: HWND = undefined;
var h_gain: HWND = undefined;
var h_gain_label: HWND = undefined;
var h_start: HWND = undefined;
var h_stop: HWND = undefined;
var h_refresh: HWND = undefined;
var h_panel: HWND = undefined;
var h_log: HWND = undefined;

var g_engine: ?*engine.Engine = null;
var g_drivers: [16]asio.DriverEntry = undefined;
var g_ndrivers: usize = 0;
var g_buffers: [32]u32 = undefined;
var g_nbuffers: usize = 0;
var g_buffer_default: usize = 0;
var g_ninputs: usize = 0;
const max_devices = 32;
var g_devices: [max_devices][256]u8 = undefined;
var g_device_lens: [max_devices]usize = undefined;
var g_ndevices: usize = 0;
var g_autostart: ?u32 = null;

// ---- ログの出力先（エディットへ追記・"\n" を "\r\n" に） ----

fn guiSink(s: []const u8) void {
    const h = h_log;
    var tmp: [4096]u8 = undefined;
    var n: usize = 0;
    for (s) |c| {
        if (n + 2 >= tmp.len) break;
        if (c == '\n') {
            tmp[n] = '\r';
            n += 1;
        }
        tmp[n] = c;
        n += 1;
    }
    const w = std.unicode.utf8ToUtf16LeAllocZ(g_alloc, tmp[0..n]) catch return;
    defer g_alloc.free(w);
    if (SendMessageW(h, WM_GETTEXTLENGTH, 0, 0) > 400_000) _ = SendMessageW(h, WM_SETTEXT, 0, @bitCast(@intFromPtr(L(""))));
    const len: usize = @intCast(SendMessageW(h, WM_GETTEXTLENGTH, 0, 0));
    _ = SendMessageW(h, EM_SETSEL, len, @intCast(len));
    _ = SendMessageW(h, EM_REPLACESEL, 0, @bitCast(@intFromPtr(w.ptr)));
}

// ---- 部品 ----

fn mkChild(ex: DWORD, class: [*:0]const u16, text: ?[*:0]const u16, style: DWORD, x: i32, y: i32, w: i32, h: i32, id: usize, font: ?*anyopaque) HWND {
    const hw = CreateWindowExW(ex, class, text, WS_CHILD | WS_VISIBLE | style, x, y, w, h, g_hwnd, @ptrFromInt(id), g_inst, null).?;
    if (font) |f| _ = SendMessageW(hw, WM_SETFONT, @intFromPtr(f), 1);
    return hw;
}

fn comboAdd(h: HWND, text: []const u8) void {
    const w = std.unicode.utf8ToUtf16LeAllocZ(g_alloc, text) catch return;
    defer g_alloc.free(w);
    _ = SendMessageW(h, CB_ADDSTRING, 0, @bitCast(@intFromPtr(w.ptr)));
}

fn comboSel(h: HWND) ?usize {
    const r = SendMessageW(h, CB_GETCURSEL, 0, 0);
    return if (r < 0) null else @intCast(r);
}

fn deviceName(i: usize) []const u8 {
    return g_devices[i][0..g_device_lens[i]];
}

// ---- 中身を埋める ----

fn refreshDevices() void {
    g_ndrivers = asio.listDrivers(&g_drivers);
    _ = SendMessageW(h_driver, CB_RESETCONTENT, 0, 0);
    for (g_drivers[0..g_ndrivers]) |*d| comboAdd(h_driver, d.nameSlice());
    if (g_ndrivers == 0) comboAdd(h_driver, "（ASIO ドライバが見つかりません）");
    var drv_sel: usize = 0;
    if (pickDriver(g_drivers[0..g_ndrivers], null)) |p| drv_sel = (@intFromPtr(p) - @intFromPtr(&g_drivers[0])) / @sizeOf(asio.DriverEntry);
    _ = SendMessageW(h_driver, CB_SETCURSEL, drv_sel, 0);

    // 再生デバイス（ケーブルと共有テストの両方の候補）
    g_ndevices = 0;
    const n: usize = @intCast(@max(ma.psk_ma_device_count(0), 0));
    var i: usize = 0;
    while (i < n and g_ndevices < max_devices) : (i += 1) {
        const len = ma.psk_ma_device_name(0, @intCast(i), &g_devices[g_ndevices], 256);
        if (len <= 0) continue;
        g_device_lens[g_ndevices] = @intCast(len);
        g_ndevices += 1;
    }
    _ = SendMessageW(h_cable, CB_RESETCONTENT, 0, 0);
    _ = SendMessageW(h_shared, CB_RESETCONTENT, 0, 0);
    comboAdd(h_cable, "（出さない）");
    comboAdd(h_shared, "（なし）");
    var cable_sel: usize = 0;
    for (0..g_ndevices) |k| {
        comboAdd(h_cable, deviceName(k));
        comboAdd(h_shared, deviceName(k));
        if (cable_sel == 0 and std.mem.indexOf(u8, deviceName(k), "CABLE Input") != null) cable_sel = k + 1;
    }
    _ = SendMessageW(h_cable, CB_SETCURSEL, cable_sel, 0);
    _ = SendMessageW(h_shared, CB_SETCURSEL, 0, 0);

    queryDriver();
}

/// 選ばれたドライバの能力を調べ、バッファと入力チャンネルの候補を埋める。
fn queryDriver() void {
    _ = SendMessageW(h_buffer, CB_RESETCONTENT, 0, 0);
    _ = SendMessageW(h_inch, CB_RESETCONTENT, 0, 0);
    g_nbuffers = 0;
    g_ninputs = 0;
    const sel = comboSel(h_driver) orelse return;
    if (sel >= g_ndrivers) return;
    const entry = &g_drivers[sel];
    const caps = asio.query(entry, g_hwnd) catch |e| {
        engine.log("[ASIO] {s} の情報を読めませんでした: {s}  {s}\n", .{ entry.nameSlice(), @errorName(e), std.mem.sliceTo(&asio.last_error_message, 0) });
        return;
    };
    engine.log("[ASIO] {s}: 入力 {d} ch / 出力 {d} ch・バッファ 最小 {d} / 最大 {d} / 推奨 {d} / 刻み {d}・{d:.0} Hz\n", .{ entry.nameSlice(), caps.num_inputs, caps.num_outputs, caps.min_frames, caps.max_frames, caps.preferred_frames, caps.granularity, caps.sample_rate });

    g_nbuffers = caps.bufferChoices(&g_buffers);
    g_buffer_default = 0;
    for (g_buffers[0..g_nbuffers], 0..) |b, k| {
        var buf: [64]u8 = undefined;
        const ms = @as(f64, @floatFromInt(b)) * 1000.0 / (if (caps.sample_rate > 0) caps.sample_rate else 48000.0);
        const pref = b == caps.preferred_frames;
        const text = std.fmt.bufPrint(&buf, "{d}（{d:.2} ms）{s}", .{ b, ms, if (pref) " 推奨" else "" }) catch continue;
        comboAdd(h_buffer, text);
        if (pref) g_buffer_default = k;
    }
    _ = SendMessageW(h_buffer, CB_SETCURSEL, g_buffer_default, 0);

    g_ninputs = @intCast(@min(@max(caps.num_inputs, 0), asio.max_query_inputs));
    for (0..g_ninputs) |ch| {
        var buf: [64]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "{d}: {s}", .{ ch, caps.inputName(ch) }) catch continue;
        comboAdd(h_inch, text);
    }
    _ = SendMessageW(h_inch, CB_SETCURSEL, 0, 0);
}

fn gainDb() f32 {
    const pos: i32 = @intCast(SendMessageW(h_gain, TBM_GETPOS, 0, 0));
    return @floatFromInt(pos + gain_min_db);
}

fn updateGainLabel() void {
    var buf: [32]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "{d:.0} dB", .{gainDb()}) catch return;
    const w = std.unicode.utf8ToUtf16LeAllocZ(g_alloc, text) catch return;
    defer g_alloc.free(w);
    _ = SetWindowTextW(h_gain_label, w.ptr);
}

fn setRunning(running: bool) void {
    const on: BOOL = if (running) 0 else 1;
    for ([_]HWND{ h_driver, h_buffer, h_inch, h_cable, h_shared, h_start, h_refresh }) |h| _ = EnableWindow(h, on);
    _ = EnableWindow(h_stop, if (running) 1 else 0);
    _ = EnableWindow(h_panel, if (running) 1 else 0);
}

// ---- 開始・停止 ----

fn startEngine() void {
    const eng = g_engine orelse return;
    const dsel = comboSel(h_driver) orelse return;
    if (dsel >= g_ndrivers) {
        engine.log("ASIO ドライバが選ばれていません\n", .{});
        return;
    }
    var cfg = engine.Config{ .sys_handle = g_hwnd, .gain_db = gainDb() };
    if (comboSel(h_buffer)) |b| if (b < g_nbuffers) {
        cfg.buffer = g_buffers[b];
    };
    if (comboSel(h_inch)) |c| cfg.in_ch = @intCast(c);
    cfg.cable = if (comboSel(h_cable)) |c| (if (c == 0 or c > g_ndevices) null else deviceName(c - 1)) else null;
    cfg.shared_test = if (comboSel(h_shared)) |c| (if (c == 0 or c > g_ndevices) null else deviceName(c - 1)) else null;

    if (eng.start(&g_drivers[dsel], cfg)) {
        setRunning(true);
        _ = SetTimer(g_hwnd.?, TIMER_TICK, 1000, null);
    }
}

fn stopEngine() void {
    const eng = g_engine orelse return;
    _ = KillTimer(g_hwnd.?, TIMER_TICK);
    eng.stop();
    setRunning(false);
}

// ---- ウィンドウ ----

fn wndProc(hwnd: HWND, msg: UINT, wp: WPARAM, lp: LPARAM) callconv(WINAPI) LRESULT {
    switch (msg) {
        WM_COMMAND => {
            const id: usize = wp & 0xFFFF;
            const code: usize = (wp >> 16) & 0xFFFF;
            switch (id) {
                ID_START => startEngine(),
                ID_STOP => stopEngine(),
                ID_REFRESH => refreshDevices(),
                ID_PANEL => asio.openControlPanel(),
                ID_DRIVER => if (code == CBN_SELCHANGE) queryDriver(),
                else => {},
            }
            return 0;
        },
        WM_HSCROLL => {
            if (lp == @as(LPARAM, @bitCast(@intFromPtr(h_gain)))) {
                updateGainLabel();
                if (g_engine) |e| e.setGainDb(gainDb()); // 動作中でもすぐ効く
            }
            return 0;
        },
        WM_TIMER => {
            if (wp == TIMER_TICK) {
                if (g_engine) |e| {
                    e.tick();
                    if (g_autostart) |s| if (e.elapsed >= s) {
                        stopEngine();
                        _ = PostMessageW(hwnd, WM_CLOSE, 0, 0);
                    };
                }
            }
            return 0;
        },
        WM_SIZE => {
            const w: i32 = @intCast(lp & 0xFFFF);
            const h: i32 = @intCast((lp >> 16) & 0xFFFF);
            _ = MoveWindow(h_log, 8, log_top, @max(w - 16, 100), @max(h - log_top - 8, 60), 1);
            return 0;
        },
        WM_CLOSE => {
            stopEngine();
            _ = DestroyWindow(hwnd);
            return 0;
        },
        WM_DESTROY => {
            PostQuitMessage(0);
            return 0;
        },
        else => return DefWindowProcW(hwnd, msg, wp, lp),
    }
}

fn label(text: [*:0]const u16, x: i32, y: i32, w: i32) void {
    _ = mkChild(0, L("STATIC"), text, SS_LEFT, x, y + 4, w, 18, 900, g_font);
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    g_alloc = gpa.allocator();

    const args = try std.process.argsAlloc(g_alloc);
    defer std.process.argsFree(g_alloc, args);
    if (args.len >= 3 and std.mem.eql(u8, args[1], "--autostart")) g_autostart = std.fmt.parseInt(u32, args[2], 10) catch null;

    engine.openLogFile(g_alloc);
    defer engine.closeLogFile();

    InitCommonControls(); // トラックバー（msctls_trackbar32）を使うため
    g_inst = GetModuleHandleW(null);
    var wc = std.mem.zeroes(WNDCLASSEXW);
    wc.cbSize = @sizeOf(WNDCLASSEXW);
    wc.lpfnWndProc = wndProc;
    wc.hInstance = g_inst;
    wc.hCursor = LoadCursorW(null, 32512); // IDC_ARROW
    wc.hbrBackground = @ptrFromInt(16); // COLOR_BTNFACE+1
    wc.lpszClassName = L("PskP1Wnd");
    _ = RegisterClassExW(&wc);

    g_hwnd = CreateWindowExW(0, L("PskP1Wnd"), L("poket-stream-kit — P1 確認"), WS_OVERLAPPEDWINDOW | WS_VISIBLE, 100, 60, 980, 640, null, null, g_inst, null);
    g_font = GetStockObject(17); // DEFAULT_GUI_FONT
    // 統計の列が揃うよう、ログは等幅（MS ゴシック）。DEFAULT_CHARSET=1・FIXED_PITCH=1
    g_mono = CreateFontW(-12, 0, 0, 0, 400, 0, 0, 0, 1, 0, 0, 0, 1, L("MS Gothic"));

    label(L("ASIO ドライバ"), 12, 12, 96);
    h_driver = mkChild(0, L("COMBOBOX"), null, CBS_DROPDOWNLIST | WS_TABSTOP | WS_VSCROLL, 112, 12, 300, 300, ID_DRIVER, g_font);
    label(L("バッファ"), 430, 12, 60);
    h_buffer = mkChild(0, L("COMBOBOX"), null, CBS_DROPDOWNLIST | WS_TABSTOP | WS_VSCROLL, 494, 12, 200, 300, ID_BUFFER, g_font);

    label(L("入力チャンネル"), 12, 44, 96);
    h_inch = mkChild(0, L("COMBOBOX"), null, CBS_DROPDOWNLIST | WS_TABSTOP | WS_VSCROLL, 112, 44, 300, 300, ID_INCH, g_font);
    label(L("音量"), 430, 44, 60);
    h_gain = mkChild(0, L("msctls_trackbar32"), null, TBS_HORZ | TBS_AUTOTICKS | WS_TABSTOP, 490, 42, 240, 28, ID_GAIN, g_font);
    _ = SendMessageW(h_gain, TBM_SETRANGE, 1, @intCast(@as(u32, 0) | (@as(u32, gain_max_db - gain_min_db) << 16)));
    _ = SendMessageW(h_gain, TBM_SETTICFREQ, 6, 0);
    _ = SendMessageW(h_gain, TBM_SETPOS, 1, -gain_min_db); // 0 dB
    h_gain_label = mkChild(0, L("STATIC"), L("0 dB"), SS_LEFT, 736, 48, 60, 18, 901, g_font);

    label(L("出力先ケーブル"), 12, 76, 96);
    h_cable = mkChild(0, L("COMBOBOX"), null, CBS_DROPDOWNLIST | WS_TABSTOP | WS_VSCROLL, 112, 76, 420, 300, ID_CABLE, g_font);
    label(L("共有テスト"), 12, 108, 96);
    h_shared = mkChild(0, L("COMBOBOX"), null, CBS_DROPDOWNLIST | WS_TABSTOP | WS_VSCROLL, 112, 108, 420, 300, ID_SHARED, g_font);
    _ = mkChild(0, L("STATIC"), L("← 選ぶと、ASIO を開く前にそのデバイスで小さな 440Hz を鳴らし始めます（Creative ASIO と Windows の音が同時に鳴るかの確認）"), SS_LEFT, 540, 104, 420, 36, 902, g_font);

    h_start = mkChild(0, L("BUTTON"), L("開始"), BS_PUSHBUTTON | WS_TABSTOP, 112, 148, 100, 30, ID_START, g_font);
    h_stop = mkChild(0, L("BUTTON"), L("停止"), BS_PUSHBUTTON | WS_TABSTOP, 220, 148, 100, 30, ID_STOP, g_font);
    h_panel = mkChild(0, L("BUTTON"), L("ドライバの設定画面"), BS_PUSHBUTTON | WS_TABSTOP, 340, 148, 150, 30, ID_PANEL, g_font);
    h_refresh = mkChild(0, L("BUTTON"), L("デバイスを再検出"), BS_PUSHBUTTON | WS_TABSTOP, 500, 148, 140, 30, ID_REFRESH, g_font);
    _ = mkChild(0, L("STATIC"), L("ログは exe の隣の psk-p1.log にも残ります"), SS_LEFT, 660, 156, 300, 18, 903, g_font);

    h_log = mkChild(WS_EX_CLIENTEDGE, L("EDIT"), null, ES_MULTILINE | ES_READONLY | ES_AUTOVSCROLL | ES_AUTOHSCROLL | WS_VSCROLL | WS_HSCROLL, 8, log_top, 956, 400, ID_LOG, g_mono orelse g_font);
    _ = SendMessageW(h_log, EM_SETLIMITTEXT, 0, 0); // 既定の 32K 文字の上限を外す
    engine.sink = guiSink;

    // COM の初期化は ASIO（STA）を miniaudio より先に（asio.initCom の説明）
    if (!asio.initCom()) engine.log("COM の初期化（STA）に失敗しました。ASIO は開けません。\n", .{});
    defer asio.deinitCom();
    if (ma.psk_ma_init() != 0) engine.log("miniaudio の初期化に失敗しました。ケーブルと共有テストは使えません。\n", .{});
    defer ma.psk_ma_uninit();

    const eng = try engine.Engine.create(g_alloc);
    g_engine = eng;
    defer {
        g_engine = null;
        eng.destroy();
    }

    refreshDevices();
    setRunning(false);
    if (g_autostart != null) startEngine();

    var msg: MSG = undefined;
    while (GetMessageW(&msg, null, 0, 0) > 0) {
        _ = TranslateMessage(&msg);
        _ = DispatchMessageW(&msg);
    }
    engine.sink = struct {
        fn f(_: []const u8) void {}
    }.f; // ウィンドウはもう無い
}
