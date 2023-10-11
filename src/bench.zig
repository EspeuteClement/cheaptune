const std = @import("std");
const Synth = @import("synth.zig");
const Voice = @import("voice.zig");
const WavWritter = @import("wav_writter.zig");

pub fn main() !void {
    const numSamples = 10 * Synth.sampleRate;
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var allocator = gpa.allocator();

    var buffer = try allocator.alloc([2]f32, numSamples);
    defer allocator.free(buffer);

    std.debug.print("[ Rendering {d} samples]\n------------\n", .{numSamples});

    {
        for (Voice.renderers) |renderer| {
            @memset(buffer, .{ 0, 0 });

            var voice = Voice{};
            voice.playNote(42 + 12, 0.5);
            var buff = buffer;

            {
                var time = try std.time.Timer.start();
                defer {
                    var end: f64 = @floatFromInt(time.read());
                    end /= std.time.ns_per_s;
                    var per_sample = end / numSamples;
                    var per_sample_percent = per_sample / (1.0 / @as(f64, Synth.sampleRate));

                    std.debug.print("[{s: <15}] Took {d: >6.3} s (per sample : {d: >8.3} ns -> {d: >6.3} % -> {d: >4.0} max poly)\n", .{ renderer.name, end, per_sample * std.time.ns_per_s, per_sample_percent * 100.0, @as(u32, @intFromFloat(1.0 / per_sample_percent)) });
                }

                while (buff.len > 0) {
                    var rem_samples = @min(buff.len, 256);
                    renderer.cb(&voice, buff[0..rem_samples]);
                    buff = buff[rem_samples..];
                }
            }

            {
                var wav_writter = WavWritter.init(numSamples);
                var filenamebuffer: [128]u8 = undefined;
                var filename = try std.fmt.bufPrint(filenamebuffer[0..], "{s}.wav", .{renderer.name});
                var subFolder = try std.fs.cwd().makeOpenPath("bench", .{});
                defer subFolder.close();
                var file = try subFolder.createFile(filename, .{});
                defer file.close();

                var file_writter = file.writer();
                var bufwrit = std.io.bufferedWriter(file_writter);
                try wav_writter.writeHeader(bufwrit.writer());

                try wav_writter.writeDataFloat(buffer, bufwrit.writer());
            }
        }
    }

    std.mem.doNotOptimizeAway(buffer);
}
