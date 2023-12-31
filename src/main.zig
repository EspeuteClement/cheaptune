const std = @import("std");
const rl = @import("lib/raylib-zig.zig");
const fft = @import("fft.zig");
const Synth = @import("synth.zig");
const Voice = @import("voice.zig");
const Fifo = @import("fifo.zig").Fifo;
const Midi = @import("midi.zig");
const ADSR = @import("adsr.zig");
const WavWritter = @import("wav_writter.zig");

const c = @cImport({
    @cInclude("Windows.h");
    @cInclude("Mmsystem.h");
});

const sampleRate = Synth.sampleRate;
const numChannels = Synth.numChannels;
const nyquist = Synth.nyquist;

var readback_buffer: [1 << 14][2]f32 = undefined;

var readback_fifo = Fifo([2]f32).init(&readback_buffer);

var readback_buffer_copy: [1 << 14][2]f32 = undefined;

var currentSynth: isize = 0;

var synth: Synth = undefined;

fn audioCallback(c_buffer: ?*anyopaque, nb_frames: c_uint) callconv(.C) void {
    var buffer: [*][2]f32 = @ptrCast(@alignCast(c_buffer.?));
    var slice: [][2]f32 = buffer[0..nb_frames];

    synth.render(slice);

    readback_fifo.pushBuffer(slice) catch {};
}

fn midiInCallback(midi_in: c.HMIDIIN, msg: c_uint, instance: ?*anyopaque, param1: ?*anyopaque, param2: ?*anyopaque) callconv(.C) void {
    _ = midi_in;
    _ = instance;
    _ = param2;
    //std.log.info("win in message : {d}", .{msg});

    if (msg == c.MIM_DATA) {
        var data: [4]u8 = @bitCast(@as(u32, @truncate(@intFromPtr(param1))));
        var slice: []u8 = data[1..];
        var ev_or_null = Midi.parseMidiEvent(&slice, data[0], null) catch null;

        //std.log.info("midi message : {b:0>8} : {b:0>16}", .{ @as(u8, @bitCast(data.status)), @as(u16, @bitCast(data.data)) });

        if (ev_or_null) |ev| {
            synth.midiIn(ev);
        }
    }
}

const keyboard_map = [_]rl.KeyboardKey{
    rl.KeyboardKey.key_z, // C
    rl.KeyboardKey.key_s, // C#
    rl.KeyboardKey.key_x, // D
    rl.KeyboardKey.key_d, // D#
    rl.KeyboardKey.key_c, // E
    rl.KeyboardKey.key_v, // F
    rl.KeyboardKey.key_g, // F#
    rl.KeyboardKey.key_b, // G
    rl.KeyboardKey.key_h, // G#x&
    rl.KeyboardKey.key_n, // A
    rl.KeyboardKey.key_j, // A#
    rl.KeyboardKey.key_m, // B
};

const midi_raw_data = @embedFile("tests/test_midi.mid");

const keyboard_midi_start = 60;

var font: rl.Font = undefined;

var ui_clic: struct {
    name: ?[]const u8 = null,
} = .{};

pub fn slider(name: []const u8, x: i32, y: i32, w: i32, h: i32, value: *f32, min: f32, max: f32) bool {
    var t = (value.* - min) / (max - min);
    var value_changed = false;

    if (rl.isMouseButtonPressed(rl.MouseButton.mouse_button_left)) {
        var mpos = rl.getMousePosition();
        if (mpos.x > @as(f32, @floatFromInt(x)) and mpos.y > @as(f32, @floatFromInt(y)) and mpos.x < @as(f32, @floatFromInt(x + w)) and mpos.y < @as(f32, @floatFromInt(y + h))) {
            ui_clic.name = name;
        }
    }

    if (ui_clic.name != null and ui_clic.name.?.ptr == name.ptr and ui_clic.name.?.len == name.len) {
        if (rl.isMouseButtonDown(rl.MouseButton.mouse_button_left)) {
            var mpos = rl.getMousePosition();

            var mt = (mpos.y - @as(f32, @floatFromInt(y))) / @as(f32, @floatFromInt(h));
            mt = std.math.clamp(1.0 - mt, 0.0, 1.0);
            mt = min + mt * (max - min);
            value.* = mt;
            value_changed = true;
        } else {
            ui_clic.name = null;
        }
    }

    var bar_h: i32 = @as(i32, @intFromFloat((1.0 - t) * @as(f32, @floatFromInt(h))));
    rl.drawRectangle(x, y + bar_h, w, h - bar_h, rl.Color.light_gray);
    rl.drawRectangleLines(x, y, w, h, rl.Color.black);

    var s = rl.measureTextEx(font, @ptrCast(name), 13, 0);
    rl.drawTextEx(font, @ptrCast(name), .{ .x = @as(f32, @floatFromInt(x + @divTrunc(w, 2))) - s.x / 2.0, .y = @floatFromInt(y + h) }, 13, 0, rl.Color.black);

    var text_buff: [16]u8 = undefined;
    var str: []const u8 = std.fmt.bufPrintZ(text_buff[0..], "{d: ^6.2}", .{value.*}) catch "err";

    var s2 = rl.measureTextEx(font, @ptrCast(str), 13, 0);
    rl.drawTextEx(font, @ptrCast(str), .{ .x = @as(f32, @floatFromInt(x + @divTrunc(w, 2))) - s2.x / 2.0, .y = @as(f32, @floatFromInt(y + h)) + s.y }, 13, 0, rl.Color.black);

    return value_changed;
}

pub fn main() anyerror!void {

    // Initialization
    //--------------------------------------------------------------------------------------
    const screenWidth = 800;
    const screenHeight = 450;

    rl.initWindow(screenWidth, screenHeight, "raylib-zig [core] example - basic window");
    defer rl.closeWindow(); // Close window and OpenGL context

    rl.setTargetFPS(60); // Set our game to run at 60 frames-per-second
    //--------------------------------------------------------------------------------------

    rl.initAudioDevice();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer if (gpa.deinit() == .leak) @panic("leak");
    var alloc = gpa.allocator();

    var midi = try Midi.parse(midi_raw_data[0..], alloc);
    defer midi.deinit(alloc);

    synth = try Synth.init(alloc);
    defer synth.deinit(alloc);

    //try synth.commands.push(.{ .playMidi = .{ .midi = &midi } });

    var audioStream = rl.loadAudioStream(sampleRate, 32, numChannels);
    rl.setAudioStreamCallback(audioStream, audioCallback);
    rl.playAudioStream(audioStream);

    var numMidi = c.midiInGetNumDevs();
    std.log.info("Found {d} midi devices", .{numMidi});

    if (numMidi > 0) {
        var id = brk: {
            for (0..numMidi) |id| {
                var info: c.MIDIINCAPSA = undefined;
                var status = c.midiInGetDevCapsA(@intCast(id), &info, @sizeOf(c.MIDIINCAPSA));
                if (!std.mem.startsWith(u8, &info.szPname, "loopMIDI")) {
                    continue;
                }

                if (status != c.MMSYSERR_NOERROR) {
                    std.log.err("Couldn't retrieve info for midi device {d}, errno : {d}", .{ id, status });
                } else {
                    var pos = std.mem.indexOfScalar(u8, &info.szPname, 0);
                    var name = info.szPname[0 .. pos orelse 32];

                    std.log.info("Found midi device with id {d} and name {s}", .{ id, name });
                    break :brk id;
                }
            }
            break :brk 0;
        };

        var phmi: c.HMIDIIN = undefined;
        const CALLBACK_FUNCTION = 0x00030000;
        var status = c.midiInOpen(&phmi, @intCast(id), @intFromPtr(&midiInCallback), 0, CALLBACK_FUNCTION);
        if (status != c.MMSYSERR_NOERROR) {
            std.log.err("Couldn't open midi device {d}, errno : {d}", .{ id, status });
        }

        _ = c.midiInStart(phmi);
    }

    font = rl.loadFont("res/cozette.fnt");
    defer rl.unloadFont(font);

    var instrument: Voice.Instrument = .{};

    // one min of recording max
    var record_buffer = try alloc.alloc([2]f32, 48000 * 60);
    defer alloc.free(record_buffer);
    var record_head: ?usize = null;

    // Main game loop
    while (!rl.windowShouldClose()) { // Detect window close button or ESC key
        // Update
        //----------------------------------------------------------------------------------
        // TODO: Update your variables here
        //----------------------------------------------------------------------------------

        for (keyboard_map, 0..) |key, index| {
            var midi_key: u8 = @intCast(keyboard_midi_start + index);
            if (rl.isKeyPressed(key)) {
                synth.playNote(midi_key, 127);
            } else if (rl.isKeyReleased(key)) {
                synth.playNote(midi_key, 0);
            }
        }

        if (rl.isKeyPressed(rl.KeyboardKey.key_p)) {
            try synth.commands.push(.{ .playMidi = .{ .midi = &midi } });
        }

        var delta: isize = @as(isize, @intFromBool(rl.isKeyPressed(rl.KeyboardKey.key_kp_subtract))) - @as(isize, @intFromBool(rl.isKeyPressed(rl.KeyboardKey.key_kp_add)));
        if (delta != 0) {
            currentSynth = @mod((currentSynth + delta), Voice.renderers.len);
            synth.setRenderer(@intCast(currentSynth));
        }

        // Draw
        //----------------------------------------------------------------------------------
        rl.beginDrawing();
        defer rl.endDrawing();

        {
            const fields: []const struct {
                *f32,
                []const u8,
            } = &.{
                .{ &instrument.adsr_params.attack, "Atk" },
                .{ &instrument.adsr_params.decay, "Dec" },
                .{ &instrument.adsr_params.sustain, "Sus" },
                .{ &instrument.adsr_params.release, "Rel" },
                .{ &instrument.adsr_params.volume, "Vol" },
                .{ &instrument.delay_mix, "Del" },
                .{ &instrument.pulse_width, "pwm" },
            };

            for (fields, 0..) |field, i| {
                var modified = slider(field[1], 100 + @as(i32, @intCast(i)) * 28, 10, 16, 75, field[0], 0.001, 1.0);

                if (modified) {
                    //synth.commands.push(.{ .setADSR = .{ .value = @field(adsr_params, field.name), .index = i } }) catch {};
                    var start = @intFromPtr(&instrument);
                    var adsr_field = field[0];
                    var fieldOffset = @intFromPtr(adsr_field) - start;
                    var asBytes = std.mem.asBytes(adsr_field);

                    var payload: [8]u8 = undefined;
                    payload[0..asBytes.len].* = asBytes.*;

                    try synth.commands.push(.{ .setCurrentInstrParam = .{
                        .offset = fieldOffset,
                        .payload = payload,
                        .size = asBytes.len,
                    } });
                }
            }
        }

        // Draw adsr

        {
            const start_x = 236;
            const height = 75.0;
            const start_y = 10 + @as(comptime_int, @intFromFloat(height));
            const step_x = 1;
            var prev_val: f32 = 0.0;

            var adsr: ADSR = .{};

            const params: ADSR.Parameters = instrument.adsr_params;
            prev_val = adsr.tick(0.0, params);
            const samples = 150;
            adsr.setSampleRate(samples / 3);
            for (0..samples) |i| {
                var gate: f32 = if (i < samples / 2) 1.0 else 0.0;
                var val = adsr.tick(gate, instrument.adsr_params);

                rl.drawLineEx(
                    .{ .x = @floatFromInt(start_x + i * step_x), .y = @floatFromInt(start_y - @as(i32, @intFromFloat(height * prev_val))) },
                    .{ .x = @floatFromInt(start_x + (i + 1) * step_x), .y = @floatFromInt(start_y - @as(i32, @intFromFloat(height * val))) },
                    1.0,
                    rl.Color.black,
                );

                prev_val = val;
            }
        }

        var stop_recording = false;

        const readback_slice_copy = readback_buffer_copy[0..1024];
        while (readback_fifo.popBufferExact(readback_slice_copy)) {
            if (record_head) |record| {
                if (record + 1024 > record_buffer.len) {
                    stop_recording = true;
                } else {
                    for (readback_slice_copy, record_buffer[record..][0..1024]) |source, *target| {
                        target.* = source;
                    }
                    record_head = record + 1024;
                }
            }
        }

        if (record_head) |pos| {
            const y = 16;

            var buffer: [64]u8 = undefined;
            var time: f32 = @floatFromInt(pos);
            time /= @floatFromInt(Synth.sampleRate);
            var max: f32 = @floatFromInt(record_buffer.len);
            max /= @floatFromInt(Synth.sampleRate);
            var text = std.fmt.bufPrintZ(buffer[0..], "• Recording : {d:0>5.2}/{d:0>5.2}", .{ time, max }) catch "err";

            var size = rl.measureTextEx(font, text, 13, 0);
            rl.drawTextEx(font, text, .{ .x = screenWidth - size.x - 16, .y = y }, 13, 0, rl.Color.red);
        }

        if (rl.isKeyPressed(rl.KeyboardKey.key_r)) {
            if (record_head != null) {
                stop_recording = true;
            } else {
                record_head = 0;
            }
        }

        if (stop_recording) {
            var file = try std.fs.cwd().createFile("record.wav", .{});
            defer file.close();

            std.log.info("got {d} s of samples", .{@as(f32, @floatFromInt(record_head.?)) / 48000.0});
            var final_buffer = record_buffer[0..record_head.?];
            var wav_writter: WavWritter = WavWritter.init(@intCast(final_buffer.len));

            var file_writter = file.writer();
            var buff = std.io.bufferedWriter(file_writter);
            try wav_writter.writeHeader(buff.writer());

            try wav_writter.writeDataFloat(final_buffer, buff.writer());
            record_head = null;
        }

        const start_x: f32 = 0;
        var start_y: f32 = screenHeight / 2;
        const scale: f32 = screenHeight / 4;
        var start: usize = 0;
        var prev: [2]f32 = [2]f32{ 0, 0 };
        for (readback_slice_copy, 0..) |smp, i| {
            if (prev[0] < 0.0 and smp[0] > 0.0) {
                start = i;
                break;
            }
            prev = smp;
        }

        start = 0;

        var reslice = readback_slice_copy[start..];
        if (reslice.len > 1) {
            for (0..reslice.len - 1) |i| {
                var fi: f32 = @floatFromInt(i);
                var f0 = reslice[i];
                var f1 = reslice[i + 1];
                rl.drawLine(
                    @intFromFloat(start_x + fi),
                    @intFromFloat(start_y + std.math.clamp(f0[0], -1.0, 1.0) * scale),
                    @intFromFloat(start_x + fi + 1.0),
                    @intFromFloat(start_y + std.math.clamp(f1[0], -1.0, 1.0) * scale),
                    rl.Color.black,
                );
            }
        }

        start_y = screenHeight;
        const fft_size = 1024;
        if (readback_slice_copy.len >= fft_size) {
            {
                var fft_data: [fft_size]fft.Cp = undefined;
                var fft_tmp: [fft_size]fft.Cp = undefined;

                for (fft_data[0..], readback_slice_copy[0..fft_size], 0..) |*cp, frame, i| {
                    var fi: f32 = @floatFromInt(i);
                    var h = std.math.pow(f32, std.math.sin(fi * std.math.pi / fft_size), 2);
                    cp.re = (frame[0] + frame[1]) / 2.0 * h;
                    cp.im = 0;
                }

                fft.fft(&fft_data, fft_size, &fft_tmp, false);

                var prev_mag: f32 = 0.0;
                for (0..fft_size / 2) |i| {
                    var cp = fft_data[i];
                    var mag = linToDb(cp.magnitude()) - linToDb(fft_size);

                    mag = std.math.clamp(mag, -80.0, 0.0);
                    mag = 1.0 + mag / 80.0;
                    mag = std.math.lerp(0.0, screenHeight / 2.0, mag);

                    if (i > 0) {
                        rl.drawLine(
                            @intCast(i - 1),
                            @intFromFloat(start_y - prev_mag),
                            @intCast(i),
                            @intFromFloat(start_y - mag),
                            rl.Color.dark_gray,
                        );
                    }
                    prev_mag = mag;
                }
            }
        }

        {
            rl.drawTextEx(font, @ptrCast(Voice.renderers[@intCast(currentSynth)].name), .{ .x = 8, .y = 8 }, 13, 0, rl.Color.dark_gray);
        }

        rl.clearBackground(rl.Color.white);

        //----------------------------------------------------------------------------------
    }
}

pub fn dbToLin(db: f32) f32 {
    const cc = std.math.ln10 / 20.0;
    return std.math.exp(db * cc);
}

pub fn linToDb(lin: f32) f32 {
    return 20 * std.math.log10(lin);
}

test {
    _ = @import("wav_writter.zig");
    _ = @import("fifo.zig");
}
