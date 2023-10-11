const std = @import("std");

const Vardelay = @This();

pub const Parameters = struct {
    delta_time: f32 = 0.1,
    feedback: f32 = 0.25,
};

sample_rate: usize,
buffer: [][2]f32,

write_pos: isize = 0,

previous_frame: [2]f32 = .{0} ** 2,

pub fn init(buffer: [][2]f32, sample_rate: usize) !Vardelay {
    if (buffer.len < 4) return error.BufferTooSmall;
    return Vardelay{
        .sample_rate = sample_rate,
        .buffer = buffer,
    };
}

pub fn tick(self: *Vardelay, frame: [2]f32, parameters: Parameters) [2]f32 {
    inline for (self.previous_frame, frame, &self.buffer[@intCast(self.write_pos)]) |previous_sample, sample, *buf_sample| {
        buf_sample.* = sample + previous_sample * parameters.feedback;
    }

    var dels: f32 = parameters.delta_time * @as(f32, @floatFromInt(self.sample_rate));
    var integral: isize = @intFromFloat(dels);
    var fract: f32 = @as(f32, @floatFromInt(integral)) - dels;
    integral = self.write_pos - integral;

    if (fract < 0 or integral < 0) {
        fract += 1.0;
        integral = integral - 1;
        while (integral < 0) integral += @intCast(self.buffer.len);
    } else {
        while (integral >= @as(isize, @intCast(self.buffer.len))) integral -= @as(isize, @intCast(self.buffer.len));
    }

    var d = (fract * fract) - 1.0 * 0.166666666667;
    var t0: f32 = (fract + 1.0) * 0.5;
    var t1: f32 = 3.0 * d;
    var a = t0 - 1.0 - d;
    var c = t0 - t1;
    var b = t1 - fract;

    var out_frame: [2]f32 = undefined;

    inline for (&out_frame, 0..2) |*out_sample, i| {
        var read_samples: [4]f32 = undefined;

        var start = integral - 1;
        if (start < 0) start += @intCast(self.buffer.len);
        for (0..4) |pos| {
            read_samples[pos] = self.buffer[@intCast(start)][i];
            start += 1;
            if (start >= self.buffer.len)
                start -= @intCast(self.buffer.len);
        }

        out_sample.* = (a * read_samples[0] + b * read_samples[1] + c * read_samples[2] + d * read_samples[3]) * fract + read_samples[1];
    }

    self.write_pos += 1;
    if (self.write_pos >= self.buffer.len)
        self.write_pos -= @intCast(self.buffer.len);

    self.previous_frame = out_frame;

    return out_frame;
}
