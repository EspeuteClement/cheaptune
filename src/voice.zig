const std = @import("std");
const Synth = @import("synth.zig");
const Valp1 = @import("valp1.zig");
const ADSR = @import("adsr.zig");

const Self = @This();

const numChannels = Synth.numChannels;
const sampleRate = Synth.sampleRate;
const nyquist = Synth.nyquist;

pub const Instrument = struct {
    adsr_params: ADSR.Parameters = .{},
    pulse_width: f32 = 0.5,
    mult: f32 = 1.0,
};

const default_instrument: Instrument = .{};

time: f32 = 0.0,
time_lfo: f32 = 0.0,
lfo_scale: f32 = 0.01,
lfo_speed: f32 = 5.0 / @as(comptime_float, sampleRate),

current_instrument: Instrument = .{},

note: u8 = 9,
cur_freq: f32 = 0.0,
cur_step: f32 = 0.0,
cur_pulse_width: f32 = 0.5,

velocity: f32 = 0.0,
gate: f32 = 0.0,

playing_time: u32 = 0.0,

low_pass: [numChannels]Valp1 = [_]Valp1{Valp1.init(22000.0, sampleRate)} ** numChannels,
adsr: ADSR = .{},

pub fn playNote(self: *Self, note: u8, vel: f32, instrument: Instrument) void {
    self.current_instrument = instrument;

    self.note = note;
    self.velocity = vel;
    self.gate = 1.0;
    self.time_lfo = 0;

    const A = 440.0;
    self.cur_freq = (A / 32.0) * std.math.pow(f32, 2.0, @as(f32, @floatFromInt((self.note) - 9)) / 12.0);

    self.playing_time = 0;
}

pub fn release(self: *Self) void {
    self.gate = 0.0;
}

pub fn setFilter(self: *Self, freq: f32) void {
    for (&self.low_pass) |*filter| {
        filter.setFreq(freq);
    }
}

pub fn renderCommon(self: *Self, buffer: [][numChannels]f32) void {
    _ = buffer;

    self.cur_step = std.math.clamp(1.0 / @as(f32, sampleRate) * self.cur_freq * self.current_instrument.mult, 0.0, 0.5);
}

pub fn renderCommonEnd(self: *Self, buffer: [][numChannels]f32) void {
    self.playing_time +|= 1;

    const adsr_params = self.current_instrument.adsr_params;

    for (buffer) |*frame| {
        var mult = self.adsr.tick(self.gate, adsr_params) * self.velocity;
        inline for (frame) |*sample| {
            sample.* *= mult;
        }
    }

    // for (buffer) |*frame| {
    //     inline for (frame, &self.low_pass) |*sample, *filter| {
    //         sample.* = filter.tick(sample.*);
    //     }
    // }
}

pub fn renderNaive(self: *Self, buffer: [][numChannels]f32) void {
    self.renderCommon(buffer);
    defer self.renderCommonEnd(buffer);

    for (buffer) |*frame| {
        var s: f32 = if (self.time > self.current_instrument.pulse_width) 1.0 else -1.0;
        inline for (frame) |*sample| {
            sample.* = s;
        }

        self.tickTime();
    }
}

pub fn renderConst(_: *Self, buffer: [][numChannels]f32) void {
    //self.renderCommon(buffer);
    //defer self.renderCommonEnd(buffer);

    for (buffer) |*frame| {
        inline for (frame) |*sample| {
            sample.* = 0.01;
        }
    }
}

inline fn tickTime(self: *Self) void {
    self.time += self.cur_step;
    self.time += sinLUT(self.time_lfo, 8) * self.lfo_scale * self.cur_step;

    self.time_lfo += self.lfo_speed;
    if (self.time_lfo >= 1.0)
        self.time_lfo -= 1.0;

    if (self.time >= 1.0) {
        self.time -= 1.0;
        self.cur_pulse_width = self.current_instrument.pulse_width;
    }
}

pub fn renderTrace(self: *Self, buffer: [][numChannels]f32) void {
    for (buffer) |_| {
        std.debug.print("{d}\n", .{self.time});
        self.tickTime();
    }
}

pub fn renderSine(self: *Self, buffer: [][numChannels]f32) void {
    self.renderCommon(buffer);
    defer self.renderCommonEnd(buffer);

    for (buffer) |*frame| {
        var s: f32 = @floatCast(@sin(self.time * std.math.tau));
        inline for (frame) |*sample| {
            sample.* = s;
        }
        self.time += 1.0 / @as(f32, sampleRate) * self.cur_freq;
        self.time = std.math.mod(f32, self.time, 1.0) catch unreachable;
    }
}

pub fn renderSineLUT(self: *Self, buffer: [][numChannels]f32) void {
    self.renderCommon(buffer);
    defer self.renderCommonEnd(buffer);

    for (buffer) |*frame| {
        var s: f32 = sinLUT(@floatCast(self.time), 8);
        inline for (frame) |*sample| {
            sample.* = s;
        }

        self.tickTime();
    }
}

inline fn sinLUT(time: f32, comptime tableSizePow: comptime_int) f32 {
    const size = 1 << tableSizePow;
    const LUT: [size]f32 = comptime brk: {
        var LUT: [size]f32 = undefined;
        for (&LUT, 0..) |*s, i| {
            var t: f32 = @floatFromInt(i);
            t *= std.math.tau;
            t /= @floatFromInt(size);

            s.* = @sin(t);
        }
        break :brk LUT;
    };

    var index: usize = @intFromFloat(time * size);
    //var frac: f32 = time * size - @as(f32, @floatFromInt(index));
    index &= size - 1;
    var a = LUT[index];
    //var b = LUT[(index + 1) & (size - 1)];
    return a; //+ (b - a) * frac;
}

pub fn renderBandlimited(self: *Self, buffer: [][numChannels]f32) void {
    self.renderCommon(buffer);
    defer self.renderCommonEnd(buffer);

    if (self.cur_freq == 0)
        return;

    for (buffer) |*frame| {
        var neededHarmonics: usize = @intFromFloat(@floor(nyquist / self.cur_freq));
        neededHarmonics = @min(neededHarmonics, 50);
        var s: f32 = 0.0;
        for (0..std.math.shr(usize, neededHarmonics, 1)) |harmonic| {
            const fharmonic: f32 = @floatFromInt(harmonic * 2 + 1);

            s += 1.0 / (fharmonic) * @sin(@as(f32, @floatCast(self.time * std.math.tau)) * fharmonic);
        }

        s *= 4.0 / std.math.pi;

        inline for (frame) |*sample| {
            sample.* = s;
        }
        self.time += 1.0 / @as(f32, sampleRate) * self.cur_freq;
        self.time = std.math.mod(f32, self.time, 1.0) catch unreachable;
    }
}

pub fn renderBandlimitedLUT(self: *Self, buffer: [][numChannels]f32) void {
    self.renderCommon(buffer);
    defer self.renderCommonEnd(buffer);

    if (self.cur_freq == 0)
        return;

    for (buffer) |*frame| {
        var neededHarmonics: usize = @intFromFloat(@floor(nyquist / self.cur_freq));
        neededHarmonics = @min(neededHarmonics, 200);
        var s: f32 = 0.0;
        for (0..std.math.shr(usize, neededHarmonics, 1)) |harmonic| {
            const fharmonic: f32 = @floatFromInt(harmonic * 2 + 1);

            s += 1.0 / (fharmonic) * sinLUT(@floatCast(self.time * fharmonic), 8);
        }

        s *= 4.0 / std.math.pi;

        inline for (frame) |*sample| {
            sample.* = s;
        }
        self.time += 1.0 / @as(f32, sampleRate) * self.cur_freq;
        self.time = std.math.mod(f32, self.time, 1.0) catch unreachable;
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
    self.renderCommon(buffer);
    defer self.renderCommonEnd(buffer);

    const inc: f32 = self.cur_step;
    for (buffer) |*frame| {
        var v: f32 = if (self.time < self.cur_pulse_width) 1.0 else -1.0;

        v += blep(inc, @floatCast(self.time));
        var tmp: f32 = @floatCast(self.time + (1.0 - self.cur_pulse_width));
        if (tmp >= 1.0)
            tmp -= 1.0;
        v -= blep(inc, tmp);

        var s = v;
        inline for (frame) |*sample| {
            sample.* = s;
        }

        self.tickTime();
    }
}

pub const renderers = [_]struct { name: []const u8, cb: *const fn (*Self, [][2]f32) void }{
    .{ .name = "PolyBlep", .cb = &renderBlep },
    .{ .name = "Naive", .cb = &renderNaive },
    .{ .name = "Sine", .cb = &renderSine },
    .{ .name = "SineLUT", .cb = &renderSineLUT },
    .{ .name = "Band Limited", .cb = &renderBandlimited },
    .{ .name = "Band Limited LUT", .cb = &renderBandlimitedLUT },
    .{ .name = "Const", .cb = &renderConst },
};
