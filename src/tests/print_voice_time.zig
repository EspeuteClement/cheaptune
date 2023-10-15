// zig run src/tests/print_voice_time.zig --main-pkg-path src/

const std = @import("std");
const Voice = @import("../voice.zig");

pub fn main() !void {
    var voice = Voice{};
    var fakeBuffer: [128][2]f32 = undefined;

    std.debug.print("--- 69 ---\n", .{});
    voice.playNote(69, 50, .{});
    voice.renderTrace(fakeBuffer[0..]);

    std.debug.print("--- 127 ---\n", .{});
    voice.playNote(127, 50, .{});
    voice.renderTrace(fakeBuffer[0..]);

    std.debug.print("--- 9 ---\n", .{});
    voice.playNote(9, 50, .{});
    voice.renderTrace(fakeBuffer[0..]);
}
