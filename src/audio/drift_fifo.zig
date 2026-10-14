//! 独立したクロックで動く2つのデバイスを橋渡しする、書き手1・読み手1のステレオ FIFO（PSK_ENGINE §3.2）。
//!
//! 読み手側で4点エルミート補間のリサンプラーを回し、再生速度を「公称レート比 ×（1＋補正）」にする。
//! 補正は FIFO の水位の誤差に対する PI 制御で決める。公称レートの違い（48k⇔44.1k）と
//! 水晶のずれ（数十〜数百 ppm）を同じ仕組みで吸収し、ブロックの間引き・複製によるプチノイズを出さない。
//!
//! 音のスレッドの約束（PSK_ENGINE §4）: push / pull はメモリを確保せず、ロックで待たない。
const std = @import("std");

// 制御の係数と上限は叩き台から持ち込んだ値で、根拠は無い（実機で決める・PSK_ENGINE §3.2）。
const kp: f64 = 0.002; // 正規化した水位誤差に対する比例ゲイン
const ki: f64 = 0.0005; // 積分ゲイン（毎秒）
const max_correction: f64 = 0.002; // ±2000ppm
const fill_smoothing: f64 = 0.05; // pull 1回ごとの水位の平滑化係数
const max_local = 1 << 14; // 読み手側の作業バッファ（フレーム）

pub const DriftFifo = struct {
    ring_l: []f32,
    ring_r: []f32,
    mask: usize,
    // 書いた総フレーム数・読んだ総フレーム数（単調増加・差が溜まっている量）
    write_pos: std.atomic.Value(usize) = .init(0),
    read_pos: std.atomic.Value(usize) = .init(0),

    // 読み手だけが触る状態
    local_l: []f32,
    local_r: []f32,
    local_count: usize = 0,
    phase: f64 = 0,
    smoothed_fill: f64 = 0,
    integral: f64 = 0,
    buffering: bool = true,

    // どのスレッドからでも設定できる値（f64 はビット列で持つ）
    writer_rate_bits: std.atomic.Value(u64) = .init(@bitCast(@as(f64, 48000))),
    reader_rate_bits: std.atomic.Value(u64) = .init(@bitCast(@as(f64, 48000))),
    target_ms_bits: std.atomic.Value(u64) = .init(@bitCast(@as(f64, 30))),
    reset_flag: std.atomic.Value(bool) = .init(true),
    max_push: std.atomic.Value(usize) = .init(0), // 書き手の1回分の最大（目標の水位の下限に使う）

    // 統計（どのスレッドからでも読める）
    stat_fill_ms_bits: std.atomic.Value(u32) = .init(0),
    stat_ppm_bits: std.atomic.Value(u32) = .init(0),
    stat_buffering: std.atomic.Value(bool) = .init(true),
    underruns: std.atomic.Value(u32) = .init(0),
    overruns: std.atomic.Value(u32) = .init(0),

    /// capacity_frames は2のべき乗に切り上げる。
    pub fn init(allocator: std.mem.Allocator, capacity_frames: usize) !DriftFifo {
        const cap = std.math.ceilPowerOfTwo(usize, capacity_frames) catch return error.TooLarge;
        const ring_l = try allocator.alloc(f32, cap);
        errdefer allocator.free(ring_l);
        const ring_r = try allocator.alloc(f32, cap);
        errdefer allocator.free(ring_r);
        const local_l = try allocator.alloc(f32, max_local);
        errdefer allocator.free(local_l);
        const local_r = try allocator.alloc(f32, max_local);
        @memset(ring_l, 0);
        @memset(ring_r, 0);
        return .{ .ring_l = ring_l, .ring_r = ring_r, .mask = cap - 1, .local_l = local_l, .local_r = local_r };
    }

    pub fn deinit(self: *DriftFifo, allocator: std.mem.Allocator) void {
        allocator.free(self.ring_l);
        allocator.free(self.ring_r);
        allocator.free(self.local_l);
        allocator.free(self.local_r);
    }

    pub fn setWriterSampleRate(self: *DriftFifo, sr: f64) void {
        if (sr > 0) self.writer_rate_bits.store(@bitCast(sr), .release);
        self.requestReset();
    }

    pub fn setReaderSampleRate(self: *DriftFifo, sr: f64) void {
        if (sr > 0) self.reader_rate_bits.store(@bitCast(sr), .release);
        self.requestReset();
    }

    pub fn setTargetLatencyMs(self: *DriftFifo, ms: f64) void {
        self.target_ms_bits.store(@bitCast(ms), .release);
    }

    pub fn targetLatencyMs(self: *const DriftFifo) f64 {
        return @bitCast(self.target_ms_bits.load(.acquire));
    }

    /// 読み手に、次の pull で中身を捨てて溜め直すよう頼む。どのスレッドからでもよい。
    pub fn requestReset(self: *DriftFifo) void {
        self.reset_flag.store(true, .release);
    }

    pub fn fillMs(self: *const DriftFifo) f32 {
        return @bitCast(self.stat_fill_ms_bits.load(.monotonic));
    }

    pub fn correctionPpm(self: *const DriftFifo) f32 {
        return @bitCast(self.stat_ppm_bits.load(.monotonic));
    }

    pub fn isBuffering(self: *const DriftFifo) bool {
        return self.stat_buffering.load(.monotonic);
    }

    // ---- 書き手のスレッド ----

    pub fn push(self: *DriftFifo, left: []const f32, right: []const f32) void {
        const n = @min(left.len, right.len);
        const wp = self.write_pos.load(.monotonic);
        const rp = self.read_pos.load(.acquire);
        const free = self.ring_l.len - (wp - rp);
        const m = @min(n, free);
        if (m < n) _ = self.overruns.fetchAdd(1, .monotonic); // 読み手が止まっている: あふれた分は捨てる
        if (n > self.max_push.load(.monotonic)) self.max_push.store(n, .monotonic);

        const start = wp & self.mask;
        const first = @min(m, self.ring_l.len - start);
        @memcpy(self.ring_l[start..][0..first], left[0..first]);
        @memcpy(self.ring_r[start..][0..first], right[0..first]);
        if (m > first) {
            @memcpy(self.ring_l[0 .. m - first], left[first..m]);
            @memcpy(self.ring_r[0 .. m - first], right[first..m]);
        }
        self.write_pos.store(wp + m, .release);
    }

    // ---- 読み手のスレッド ----

    fn ready(self: *const DriftFifo) usize {
        return self.write_pos.load(.acquire) - self.read_pos.load(.monotonic);
    }

    fn discard(self: *DriftFifo, frames: usize) void {
        const rp = self.read_pos.load(.monotonic);
        self.read_pos.store(rp + @min(frames, self.ready()), .release);
    }

    fn readIntoLocal(self: *DriftFifo, frames: usize) usize {
        const rp = self.read_pos.load(.monotonic);
        const m = @min(frames, self.ready());
        const start = rp & self.mask;
        const first = @min(m, self.ring_l.len - start);
        const dst = self.local_count;
        @memcpy(self.local_l[dst..][0..first], self.ring_l[start..][0..first]);
        @memcpy(self.local_r[dst..][0..first], self.ring_r[start..][0..first]);
        if (m > first) {
            @memcpy(self.local_l[dst + first ..][0 .. m - first], self.ring_l[0 .. m - first]);
            @memcpy(self.local_r[dst + first ..][0 .. m - first], self.ring_r[0 .. m - first]);
        }
        self.read_pos.store(rp + m, .release);
        self.local_count += m;
        return m;
    }

    fn currentFill(self: *const DriftFifo) f64 {
        return @as(f64, @floatFromInt(self.ready() + self.local_count)) - self.phase;
    }

    fn storeFill(self: *DriftFifo, fill: f64, in_rate: f64) void {
        self.stat_fill_ms_bits.store(@bitCast(@as(f32, @floatCast(fill * 1000.0 / in_rate))), .monotonic);
    }

    pub fn pull(self: *DriftFifo, left: []f32, right: []f32) void {
        const n = @min(left.len, right.len);
        const in_rate: f64 = @bitCast(self.writer_rate_bits.load(.acquire));
        const out_rate: f64 = @bitCast(self.reader_rate_bits.load(.acquire));
        // 目標の水位は、指定値と「読み手の1回分＋書き手の2回分」の大きい方。読み手が1回に大きく要求する
        // デバイス（Wine の空の機器は 4800 フレーム）で、溜まった直後に足りなくなる溜め直しの繰り返しを防ぐ。
        // 書き手1回分だけだと、制御の小さな揺れで不足する瞬間が出た（テストで定常の音切れ1回）。
        const per_pull = in_rate / out_rate * @as(f64, @floatFromInt(n)) + 4.0;
        const per_push: f64 = @floatFromInt(self.max_push.load(.monotonic));
        const target = @max(@max(64.0, self.targetLatencyMs() * 0.001 * in_rate), per_pull + 2.0 * per_push);

        if (self.reset_flag.swap(false, .acq_rel)) {
            self.discard(self.ready());
            self.local_count = 0;
            self.phase = 0;
            self.integral = 0;
            self.buffering = true;
        }

        var fill = self.currentFill();

        if (self.buffering) {
            if (fill < target) {
                silence(left[0..n], right[0..n]);
                self.storeFill(fill, in_rate);
                self.stat_buffering.store(true, .monotonic);
                return;
            }
            self.discard(@intFromFloat(fill - target)); // ちょうど目標の水位から鳴らし始める
            fill = self.currentFill();
            self.smoothed_fill = fill;
            self.integral = 0;
            self.buffering = false;
        } else if (fill > target * 3.0 + 4096.0) {
            // 書き手が大きく先行した（読み手のデバイスが止まっていた等）: 目標の水位へ戻す
            self.discard(@intFromFloat(fill - target));
            fill = self.currentFill();
            self.smoothed_fill = fill;
            _ = self.overruns.fetchAdd(1, .monotonic);
        }

        self.smoothed_fill += fill_smoothing * (fill - self.smoothed_fill);
        const err = (self.smoothed_fill - target) / target;
        self.integral = std.math.clamp(self.integral + err * @as(f64, @floatFromInt(n)) / out_rate, -4.0, 4.0);
        const correction = std.math.clamp(kp * err + ki * self.integral, -max_correction, max_correction);
        const step = in_rate / out_rate * (1.0 + correction);

        const needed_f = @ceil(self.phase + step * @as(f64, @floatFromInt(n))) + 4.0;
        if (needed_f > max_local) {
            silence(left[0..n], right[0..n]); // 異常な比率・ブロック長: 作業バッファを越えるより無音を返す
            return;
        }
        const needed: usize = @intFromFloat(needed_f);

        if (self.local_count < needed) _ = self.readIntoLocal(needed - self.local_count);

        if (self.local_count < needed) {
            _ = self.underruns.fetchAdd(1, .monotonic);
            silence(left[0..n], right[0..n]);
            self.local_count = 0;
            self.phase = 0;
            self.buffering = true;
            self.stat_buffering.store(true, .monotonic);
            return;
        }

        const L = self.local_l;
        const R = self.local_r;
        var pos = self.phase;
        for (0..n) |i| {
            const idx: usize = @intFromFloat(pos);
            const t: f32 = @floatCast(pos - @as(f64, @floatFromInt(idx)));
            left[i] = hermite(L[idx], L[idx + 1], L[idx + 2], L[idx + 3], t);
            right[i] = hermite(R[idx], R[idx + 1], R[idx + 2], R[idx + 3], t);
            pos += step;
        }

        const consumed = @min(@as(usize, @intFromFloat(pos)), self.local_count);
        self.phase = pos - @as(f64, @floatFromInt(consumed));
        self.local_count -= consumed;
        if (self.local_count > 0) {
            std.mem.copyForwards(f32, self.local_l[0..self.local_count], self.local_l[consumed..][0..self.local_count]);
            std.mem.copyForwards(f32, self.local_r[0..self.local_count], self.local_r[consumed..][0..self.local_count]);
        }

        self.storeFill(self.smoothed_fill, in_rate);
        self.stat_ppm_bits.store(@bitCast(@as(f32, @floatCast(correction * 1.0e6))), .monotonic);
        self.stat_buffering.store(false, .monotonic);
    }
};

fn silence(l: []f32, r: []f32) void {
    @memset(l, 0);
    @memset(r, 0);
}

/// 4点・3次のエルミート補間（y1 と y2 の間、t は 0..1）。
inline fn hermite(y0: f32, y1: f32, y2: f32, y3: f32, t: f32) f32 {
    const c1 = 0.5 * (y2 - y0);
    const c2 = y0 - 2.5 * y1 + 2.0 * y2 - 0.5 * y3;
    const c3 = 0.5 * (y3 - y0) + 1.5 * (y1 - y2);
    return ((c3 * t + c2) * t + c1) * t + y1;
}

// ---- テスト: 独立したクロックで走る2つのデバイスをシミュレーションする ----

const SimResult = struct { fill_ms: f32, ppm: f32, steady_underruns: u32, snr_db: f64 };

/// 公称レート（デバイスが名乗る値）と実際のずれ（ppm）を分けて与える。後半を定常状態として測る。
fn simulate(in_nominal: f64, in_block: usize, out_nominal: f64, out_block: usize, seconds: f64, in_ppm: f64, out_ppm: f64) !SimResult {
    const a = std.testing.allocator;
    const in_rate = in_nominal * (1.0 + in_ppm * 1e-6);
    const out_rate = out_nominal * (1.0 + out_ppm * 1e-6);

    var fifo = try DriftFifo.init(a, 1 << 15);
    defer fifo.deinit(a);
    fifo.setWriterSampleRate(in_nominal);
    fifo.setReaderSampleRate(out_nominal);
    fifo.setTargetLatencyMs(30);

    const in_l = try a.alloc(f32, in_block);
    defer a.free(in_l);
    const out_l = try a.alloc(f32, out_block);
    defer a.free(out_l);
    const out_r = try a.alloc(f32, out_block);
    defer a.free(out_r);

    const freq = 1000.0;
    var t_in: f64 = 0;
    var t_out: f64 = 0;
    var in_phase: f64 = 0;
    var measuring = false;
    var start_underruns: u32 = 0;
    var err_sq: f64 = 0;
    var sig_sq: f64 = 0;
    // 受け側で見える周波数（書き手の実クロックで作った音を、読み手の実クロックで鳴らす）
    const w = 2.0 * std.math.pi * freq * (in_nominal / in_rate) / (out_nominal / out_rate) / out_nominal;

    while (t_out < seconds) {
        if (t_in <= t_out) {
            for (in_l) |*s| {
                s.* = @floatCast(@sin(in_phase));
                in_phase += 2.0 * std.math.pi * freq / in_rate;
            }
            fifo.push(in_l, in_l);
            t_in += @as(f64, @floatFromInt(in_block)) / in_rate;
        } else {
            fifo.pull(out_l, out_r);
            t_out += @as(f64, @floatFromInt(out_block)) / out_rate;
            if (t_out > seconds * 0.5) {
                if (!measuring) {
                    measuring = true;
                    start_underruns = fifo.underruns.load(.monotonic);
                }
                // 正弦波の漸化式 y[n] = 2cos(w)y[n-1] - y[n-2] からの外れを雑音とみなす
                for (2..out_block) |i| {
                    const pred = 2.0 * @cos(w) * out_l[i - 1] - out_l[i - 2];
                    const e = pred - out_l[i];
                    err_sq += e * e;
                    sig_sq += out_l[i] * out_l[i];
                }
            }
        }
    }
    return .{
        .fill_ms = fifo.fillMs(),
        .ppm = fifo.correctionPpm(),
        .steady_underruns = fifo.underruns.load(.monotonic) - start_underruns,
        .snr_db = 10.0 * std.math.log10(sig_sq / @max(err_sq, 1e-20)),
    };
}

fn expectLocked(r: SimResult) !void {
    try expectLockedAt(r, 30.0);
}

fn expectLockedAt(r: SimResult, target_ms: f32) !void {
    try std.testing.expectEqual(@as(u32, 0), r.steady_underruns);
    try std.testing.expect(@abs(r.fill_ms - target_ms) < 6.0);
    try std.testing.expect(r.snr_db > 60.0);
}

test "同じ公称レート・ずれなし" {
    try expectLocked(try simulate(48000, 128, 48000, 480, 60, 0, 0));
}

test "クロックが 200ppm 離れている" {
    try expectLocked(try simulate(48000, 128, 48000, 480, 120, 100, -100));
}

test "小さい ASIO ブロックと 441 フレームの読み手" {
    try expectLocked(try simulate(48000, 64, 48000, 441, 120, -150, 50));
}

test "48k から 44.1k へ（ずれあり）" {
    try expectLocked(try simulate(48000, 256, 44100, 441, 60, 30, -20));
}

test "44.1k から 48k へ（ずれあり）" {
    try expectLocked(try simulate(44100, 512, 48000, 480, 60, -40, 40));
}

test "読み手が1回に目標の水位より多く要求する（100ms 周期の機器）" {
    try expectLockedAt(try simulate(48000, 128, 48000, 4800, 120, 100, -100), (4800.0 + 2.0 * 128.0) * 1000.0 / 48000.0);
}

test "読み手の要求が作業バッファを越えても壊れない" {
    const a = std.testing.allocator;
    var fifo = try DriftFifo.init(a, 1 << 12);
    defer fifo.deinit(a);
    const big_l = try a.alloc(f32, max_local + 16);
    defer a.free(big_l);
    const big_r = try a.alloc(f32, max_local + 16);
    defer a.free(big_r);
    fifo.pull(big_l, big_r);
    for (big_l) |s| try std.testing.expectEqual(@as(f32, 0), s);
}
