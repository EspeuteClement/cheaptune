const Synth = @import("synth.zig");

const ADSR = @This();

attack: f32 = 0.0001,
decay: f32 = 0.2,
sustain: f32 = 0.5,
release: f32 = 0.2,

timer: f32 = 0,

sample_rate: u32 = Synth.sampleRate,
attack_time: f32 = 0.1 * Synth.sampleRate,

a: f32 = 0,
b: f32 = 0,
x: f32 = 0,
y: f32 = 0,

memory: f32 = 0,

mode: Mode = .Clear,

pub fn setSampleRate(self: *ADSR, sample_rate: u32) void {
    self.sample_rate = sample_rate;
    self.attack_time = 0.1 * @as(f32, @floatFromInt(sample_rate));
}

pub const parameters = [_][]const u8{ "attack", "decay", "sustain", "release" };

pub inline fn tick(self: *ADSR, gate: f32) f32 {
    var out: f32 = 0.0;

    if (self.memory < gate and self.mode != .Decay) {
        self.mode = .Attack;
        self.timer = 0.0;
        var pole = self.tau2pole(self.attack * 0.6);
        self.a = pole;
        self.b = 1.0 - pole;
    } else if (self.memory > gate) {
        self.mode = .Release;
        var pole = self.tau2pole(self.release);
        self.a = pole;
        self.b = 1.0 - pole;
    }

    self.x = gate;
    self.memory = gate;

    switch (self.mode) {
        .Clear => {
            out = 0.0;
        },
        .Attack => {
            self.timer += 1;
            out = self.filter();
            if (out > 0.99) {
                self.mode = .Decay;
                var pole = self.tau2pole(self.decay);
                self.a = pole;
                self.b = 1.0 - pole;
            }
        },
        .Decay, .Release => {
            self.x *= self.sustain;
            out = self.filter();
            if (out < 0.01) {
                self.mode = .Clear;
            }
        },
    }
    return out;
}

fn filter(self: *ADSR) f32 {
    self.y = self.b * self.x + self.a * self.y;
    return self.y;
}

inline fn tau2pole(self: *ADSR, tau: f32) f32 {
    return @exp(-1.0 / (tau * @as(f32, @floatFromInt(self.sample_rate))));
}

const Mode = enum { Clear, Attack, Decay, Release };
