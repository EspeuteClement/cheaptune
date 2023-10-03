const std = @import("std");

pub const sampleRate = 48000;
pub const numChannels = 2;
pub const nyquist = sampleRate / 2;

const Synth = @This();

time: f64 = 0.0,
mutex: std.Thread.Mutex = .{},
note: ?u8 = null,
cur_note: ?u8 = null,

prev_note: u8 = 9,
cur_vel: f32 = 0,

pub const render = renderBandlimited;

pub fn renderNaive(self: *Self, buffer: [][numChannels]f32) void {
    if (self.mutex.tryLock()) {
        defer self.mutex.unlock();
        self.cur_note = self.note;
    }
    self.prev_note = self.cur_note orelse self.prev_note;

    const A = 440.0;
    var freq: f32 = (A / 32.0) * std.math.pow(f32, 2.0, @as(f32, @floatFromInt((self.prev_note) - 9)) / 12.0);

    var target_vel: f32 = if (self.cur_note != null) 0.50 else 0.0;
    self.cur_vel = self.cur_vel + (target_vel - self.cur_vel) * 0.1;
    for (buffer) |*frame| {
        var s: f32 = if (@mod(self.time, 1.0) > 0.5) 1.0 else -1.0;
        s *= self.cur_vel;
        inline for (frame) |*sample| {
            sample.* = s;
        }
        self.time += 1.0 / @as(f32, sampleRate) * freq;
    }
}

pub fn renderSine(self: *Self, buffer: [][numChannels]f32) void {
    if (self.mutex.tryLock()) {
        defer self.mutex.unlock();
        self.cur_note = self.note;
    }
    self.prev_note = self.cur_note orelse self.prev_note;

    const A = 440.0;
    var freq: f64 = (A / 32.0) * std.math.pow(f64, 2.0, @as(f64, @floatFromInt((self.prev_note) - 9)) / 12.0);

    var target_vel: f32 = if (self.cur_note != null) 0.50 else 0.0;
    self.cur_vel = self.cur_vel + (target_vel - self.cur_vel) * 0.1;
    for (buffer) |*frame| {
        var s: f32 = @floatCast(@sin(self.time * std.math.tau + @sin(self.time * std.math.tau * 2.0 + @sin(self.time * std.math.tau * 2.0))));
        s *= self.cur_vel;
        inline for (frame) |*sample| {
            sample.* = s;
        }
        self.time += 1.0 / @as(f64, sampleRate) * freq;
        self.time = std.math.mod(f64, self.time, 1.0) catch unreachable;
    }
}

pub fn renderBandlimited(self: *Self, buffer: [][numChannels]f32) void {
    if (self.mutex.tryLock()) {
        defer self.mutex.unlock();
        self.cur_note = self.note;
    }
    self.prev_note = self.cur_note orelse self.prev_note;

    const A = 440.0;
    var freq: f32 = (A / 32.0) * std.math.pow(f32, 2.0, @as(f32, @floatFromInt((self.prev_note) - 9)) / 12.0);

    var target_vel: f32 = if (self.cur_note != null) 0.50 else 0.0;
    self.cur_vel = self.cur_vel + (target_vel - self.cur_vel) * 0.1;

    for (buffer) |*frame| {
        var neededHarmonics: usize = @intFromFloat(@floor(nyquist / freq));
        neededHarmonics = @min(neededHarmonics, 50);
        var s: f32 = 0.0;
        for (0..std.math.shr(usize, neededHarmonics, 1)) |harmonic| {
            const fharmonic: f32 = @floatFromInt(harmonic * 2 + 1);

            s += 1.0 / (fharmonic) * @sin(@as(f32, @floatCast(self.time * std.math.tau)) * fharmonic);
        }

        s *= 4.0 / std.math.pi;

        s *= self.cur_vel;
        inline for (frame) |*sample| {
            sample.* = s;
        }
        self.time += 1.0 / @as(f32, sampleRate) * freq;
        self.time = std.math.mod(f64, self.time, 1.0) catch unreachable;
    }
}

pub inline fn blep(dt: f32, tIn: f32) f32 {
    var t = tIn;
    if (t < dt) {
        t /= dt;
        return t + t - t * t - 1.0;
    } else if (t > 1.0 - dt) {
        t = (t - 1.0) / dt;
        return t * t + t + t + 1.0;
    }
    return 0.0;
}

pub fn renderBlep(self: *Self, buffer: [][numChannels]f32) void {
    if (self.mutex.tryLock()) {
        defer self.mutex.unlock();
        self.cur_note = self.note;
    }
    self.prev_note = self.cur_note orelse self.prev_note;

    const A = 440.0;
    var freq: f32 = (A / 32.0) * std.math.pow(f32, 2.0, @as(f32, @floatFromInt((self.prev_note) - 9)) / 12.0);

    var target_vel: f32 = if (self.cur_note != null) 0.50 else 0.0;
    self.cur_vel = self.cur_vel + (target_vel - self.cur_vel) * 0.5;
    const inc: f32 = 1.0 / @as(f32, sampleRate) * freq;
    for (buffer) |*frame| {
        var v: f32 = if (self.time < 0.5) 1.0 else -1.0;

        v += blep(inc, @floatCast(self.time));
        v -= blep(inc, @floatCast(@mod(self.time + 0.5, 1.0)));

        var s = v;
        s *= self.cur_vel;
        inline for (frame) |*sample| {
            sample.* = s;
        }
        self.time += @floatCast(inc);
        self.time = std.math.mod(f64, self.time, 1.0) catch unreachable;
    }
}

pub const renderers = [_]struct { name: []const u8, cb: *const fn (*Self, [][2]f32) void }{
    .{ .name = "PolyBlep", .cb = &renderBlep },
    .{ .name = "Naive", .cb = &renderNaive },
    .{ .name = "Sine", .cb = &renderSine },
    .{ .name = "Band Limited", .cb = &renderBandlimited },
};

pub fn playNote(self: *Self, wanted_note: ?u8) void {
    self.mutex.lock();
    defer self.mutex.unlock();
    self.note = wanted_note;
}

const Self = @This();
