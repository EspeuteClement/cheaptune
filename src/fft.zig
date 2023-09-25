const std = @import("std");

pub const Cp = std.math.Complex(f32);

pub fn fft(vector: []Cp, n: usize, temp: []Cp, comptime inverse: bool) void {
    if (n > 1) {
        const half = n / 2;
        var ve = temp[0..half];
        var vo = temp[half..n];
        for (ve, vo, 0..) |*e, *o, i| {
            e.* = vector[i * 2];
            o.* = vector[i * 2 + 1];
        }

        fft(ve, n / 2, vector, inverse);
        fft(vo, n / 2, vector, inverse);

        for (0..half) |m| {
            var m_over_n: f32 = @as(f32, @floatFromInt(m)) / @as(f32, @floatFromInt(n));
            var w: Cp = Cp{
                .re = std.math.cos(std.math.tau * m_over_n),
                .im = std.math.sin(std.math.tau * m_over_n) * if (inverse) 1.0 else -1.0,
            };

            var z = w.mul(vo[m]);

            vector[m].re = ve[m].re + z.re;
            vector[m].im = ve[m].im + z.im;

            vector[m + half].re = ve[m].re - z.re;
            vector[m + n / 2].im = ve[m].im - z.im;
        }
    }
}
