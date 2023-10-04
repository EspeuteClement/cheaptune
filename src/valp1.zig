// Implementation based on this blogpost : https://pbat.ch/sndkit/valp1/
const std = @import("std");

const Valp1 = @This();

freq: f32,
sampleMemory: f32 = 0.0,
gain: f32 = 0.0,
T: f32,

pub fn init(baseFreq: f32, sampleRate: f32) Valp1 {
    var ret = Valp1{ .freq = undefined, .T = 1.0 / sampleRate };

    ret.setFreq(baseFreq);

    return ret;
}

pub fn setFreq(self: *Valp1, freq: f32) void {
    self.freq = freq;
    var wc = std.math.tau * self.freq;
    var wa = (2.0 / self.T) * std.math.tan(wc * self.T * 0.5);
    var g = wa * self.T * 0.5;
    self.gain = g / (1.0 + g);
}

pub inline fn tick(self: *Valp1, in: f32) f32 {
    var v = (in - self.sampleMemory) * self.gain;
    var out = v + self.sampleMemory;
    self.sampleMemory = out + v;
    return out;
}
