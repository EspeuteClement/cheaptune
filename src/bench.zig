const std = @import("std");
const Synth = @import("synth.zig");

pub fn main() !void {
    const numSamples = 30 * Synth.sampleRate;
    var allocator = std.heap.c_allocator;

    var buffer = try allocator.alloc([2]f32, numSamples);
    defer allocator.free(buffer);

    {
        var synth = Synth{};
        synth.playNote(42);

        {
            var time = try std.time.Timer.start();
            defer {
                var end: f64 = @floatFromInt(time.read());
                end /= std.time.ns_per_s;
                var per_sample = end / numSamples;
                var per_sample_percent = per_sample / Synth.sampleRate;

                std.debug.print("Took {d:0>5.3}s (per sample : {d:0>5.3}ns -> {d}%)\n", .{ end, per_sample * std.time.ns_per_s, per_sample_percent * 100.0 });
            }

            synth.renderSine(buffer);
        }
    }

    {
        var synth = Synth{};
        synth.playNote(42);

        {
            var time = try std.time.Timer.start();
            defer {
                var end: f64 = @floatFromInt(time.read());
                end /= std.time.ns_per_s;
                var per_sample = end / numSamples;
                var per_sample_percent = per_sample / Synth.sampleRate;

                std.debug.print("Took {d:0>5.3}s (per sample : {d:0>5.3}ns -> {d}%)\n", .{ end, per_sample * std.time.ns_per_s, per_sample_percent * 100.0 });
            }

            synth.renderBandlimited(buffer);
        }
    }

    std.mem.doNotOptimizeAway(buffer);
}
