// Implementation based on this blogpost : https://pbat.ch/sndkit/dcblocker/
const std = @import("std");

const Self = @This();

x: f32 = 0,
y: f32 = 0,

const R = 0.99;

pub inline fn tick(self: *Self, in: f32) f32 {
    self.y = in - self.x + R * self.y;
    self.x = in;
    return self.y;
}
