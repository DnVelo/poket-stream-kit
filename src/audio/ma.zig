//! `psk_ma.c`（miniaudio の窓口）の Zig 側の宣言。
pub const Device = opaque {};

pub const Callback = *const fn (user: ?*anyopaque, out: ?[*]f32, in: ?[*]const f32, frames: c_uint, channels: c_uint) callconv(.c) void;

pub extern fn psk_ma_init() c_int;
pub extern fn psk_ma_uninit() void;
pub extern fn psk_ma_device_count(capture: c_int) c_int;
pub extern fn psk_ma_device_name(capture: c_int, index: c_int, buf: [*]u8, cap: c_int) c_int;
pub extern fn psk_ma_open(capture: c_int, name_contains: ?[*:0]const u8, channels: c_uint, cb: Callback, user: ?*anyopaque, err: *c_int) ?*Device;
pub extern fn psk_ma_sample_rate(d: *Device) c_uint;
pub extern fn psk_ma_period_frames(d: *Device) c_uint;
pub extern fn psk_ma_name(d: *Device) [*:0]const u8;
pub extern fn psk_ma_start(d: *Device) c_int;
pub extern fn psk_ma_close(d: ?*Device) void;
