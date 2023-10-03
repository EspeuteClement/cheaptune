const std = @import("std");
const Synth = @import("synth.zig");

pub fn main() !void {
    const numSamples = 10 * Synth.sampleRate;
    var allocator = std.heap.c_allocator;

    var buffer = try allocator.alloc([2]f32, numSamples);
    defer allocator.free(buffer);

    std.debug.print("[ Rendering {d} samples]\n------------\n", .{numSamples});

    {
        for (Synth.renderers) |renderer| {
            var synth = Synth{};
            synth.playNote(42);

            var time = try std.time.Timer.start();
            defer {
                var end: f64 = @floatFromInt(time.read());
                end /= std.time.ns_per_s;
                var per_sample = end / numSamples;
                var per_sample_percent = per_sample / (1.0 / @as(f64, Synth.sampleRate));

                std.debug.print("[{s: <15}] Took {d: >6.3} s (per sample : {d: >8.3} ns -> {d: >6.3} % -> {d: >4.0} max poly)\n", .{ renderer.name, end, per_sample * std.time.ns_per_s, per_sample_percent * 100.0, @as(u32, @intFromFloat(1.0 / per_sample_percent)) });
            }

            renderer.cb(&synth, buffer);
        }
    }

    std.mem.doNotOptimizeAway(buffer);
}
