const Synth = @import("synth.zig");

const ADSR = @This();

attack: f32 = 0.0001,
decay: f32 = 0.2,
sustain: f32 = 0.5,
release: f32 = 0.2,

timer: f32 = 0,
attack_time: f32 = 0.1 * Synth.sampleRate,

a: f32 = 0,
b: f32 = 0,
x: f32 = 0,
y: f32 = 0,

memory: f32 = 0,

mode: Mode = .Clear,

pub fn tick(self: *ADSR, gate: f32) f32 {
    var out: f32 = 0.0;

    if (self.memory < gate and self.mode != .Decay) {
        self.mode = .Attack;
        self.timer = 0.0;
        var pole = tau2pole(self.attack * 0.6);
        self.a = pole;
        self.b = 1.0 - pole;
    } else if (self.memory > gate) {
        self.mode = .Release;
        var pole = tau2pole(self.release);
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
                var pole = tau2pole(self.decay);
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

pub fn tau2pole(tau: f32) f32 {
    return @exp(-1.0 / (tau * Synth.sampleRate));
}

const Mode = enum { Clear, Attack, Decay, Release };
