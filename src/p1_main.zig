//! P1 確認用プログラムのコマンド版（PSK_IMPLEMENTATION_STATUS §1.5・§1.6）。音の部分は p1_engine.zig。
const std = @import("std");
const asio = @import("audio/asio.zig");
const ma = @import("audio/ma.zig");
const engine = @import("p1_engine.zig");

extern "kernel32" fn SetConsoleOutputCP(cp: c_uint) callconv(.winapi) c_int;

const usage =
    \\psk-p1 — P1 確認用プログラム（画面版は psk-p1-gui）
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
    seconds: ?u32 = null,
    cfg: engine.Config = .{},
};

var quit = std.atomic.Value(bool).init(false);

fn waitEnter() void {
    var buf: [64]u8 = undefined;
    _ = std.fs.File.stdin().read(&buf) catch {};
    quit.store(true, .release);
}

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

    engine.openLogFile(alloc);
    defer engine.closeLogFile();

    // COM の初期化は ASIO（STA）を miniaudio より先に（asio.initCom の説明）
    if (!asio.initCom()) engine.log("COM の初期化（STA）に失敗しました。ASIO は開けません。\n", .{});
    defer asio.deinitCom();
    if (ma.psk_ma_init() != 0) {
        engine.log("miniaudio の初期化に失敗しました\n", .{});
        return;
    }
    defer ma.psk_ma_uninit();

    var drivers: [16]asio.DriverEntry = undefined;
    const ndrv = asio.listDrivers(&drivers);
    if (opts.list) {
        engine.printList(drivers[0..ndrv]);
        return;
    }
    const entry = pickDriver(drivers[0..ndrv], opts.driver) orelse {
        engine.log("ASIO ドライバが見つかりません。\n", .{});
        engine.printList(drivers[0..ndrv]);
        return;
    };

    const eng = try engine.Engine.create(alloc);
    defer eng.destroy();
    if (!eng.start(entry, opts.cfg)) return;

    if (opts.seconds == null) {
        engine.log("動作中。Enter で終了します。\n", .{});
        const t = try std.Thread.spawn(.{}, waitEnter, .{});
        t.detach();
    }
    while (!quit.load(.acquire)) {
        std.Thread.sleep(std.time.ns_per_s);
        eng.tick();
        if (opts.seconds) |s| if (eng.elapsed >= s) break;
    }
    eng.stop();
}

fn parseArgs(args: []const [:0]u8) !Options {
    var o = Options{};
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--list")) {
            o.list = true;
        } else if (std.mem.eql(u8, a, "--no-cable")) {
            o.cfg.cable = null;
        } else {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            const v = args[i];
            if (std.mem.eql(u8, a, "--driver")) o.driver = v
            else if (std.mem.eql(u8, a, "--buffer")) o.cfg.buffer = try std.fmt.parseInt(u32, v, 10)
            else if (std.mem.eql(u8, a, "--rate")) o.cfg.rate = try std.fmt.parseFloat(f64, v)
            else if (std.mem.eql(u8, a, "--in-ch")) o.cfg.in_ch = try std.fmt.parseInt(u32, v, 10)
            else if (std.mem.eql(u8, a, "--gain-db")) o.cfg.gain_db = try std.fmt.parseFloat(f32, v)
            else if (std.mem.eql(u8, a, "--cable")) o.cfg.cable = v
            else if (std.mem.eql(u8, a, "--target-ms")) o.cfg.target_ms = try std.fmt.parseFloat(f64, v)
            else if (std.mem.eql(u8, a, "--shared-test")) o.cfg.shared_test = v
            else if (std.mem.eql(u8, a, "--seconds")) o.seconds = try std.fmt.parseInt(u32, v, 10)
            else return error.UnknownOption;
        }
    }
    return o;
}

pub fn pickDriver(drivers: []asio.DriverEntry, want: ?[]const u8) ?*asio.DriverEntry {
    const needle = want orelse "Creative";
    for (drivers) |*d| if (std.mem.indexOf(u8, d.nameSlice(), needle) != null) return d;
    if (want == null and drivers.len > 0) return &drivers[0];
    return null;
}
