const std = @import("std");
const rl = @import("lib/raylib-zig.zig");
const fft = @import("fft.zig");
const Synth = @import("synth.zig");

const c = @cImport({
    @cInclude("Windows.h");
    @cInclude("Mmsystem.h");
});

const sampleRate = Synth.sampleRate;
const numChannels = Synth.numChannels;
const nyquist = Synth.nyquist;

var readback_buffer: [4096][2]f32 = undefined;
var readback_slice: [][2]f32 = readback_buffer[0..0];
var readback_mutex: std.Thread.Mutex = .{};
var readback_buffer_copy: [4096][2]f32 = undefined;
var readback_slice_copy: [][2]f32 = readback_buffer_copy[0..0];

var currentSynth: isize = 0;
var currentSynthCopy: isize = 0;

var synth: Synth = .{};

fn audioCallback(c_buffer: ?*anyopaque, nb_frames: c_uint) callconv(.C) void {
    var buffer: [*][2]f32 = @ptrCast(@alignCast(c_buffer.?));
    var slice: [][2]f32 = buffer[0..nb_frames];

    if (readback_mutex.tryLock()) {
        defer readback_mutex.unlock();
        currentSynthCopy = currentSynth;
    }

    const cb = Synth.renderers[@intCast(currentSynthCopy)].cb;
    cb(&synth, slice);

    {
        readback_mutex.lock();
        defer readback_mutex.unlock();
        if (readback_slice.len + nb_frames < readback_buffer.len) {
            var rb_slice = readback_buffer[readback_slice.len..][0..nb_frames];
            for (slice, rb_slice) |frame, *rb_frame| {
                rb_frame.* = frame;
            }
            readback_slice = readback_buffer[0 .. readback_slice.len + nb_frames];
        }
    }
}

fn midiInCallback(midi_in: c.HMIDIIN, msg: c_uint, instance: ?*anyopaque, param1: ?*anyopaque, param2: ?*anyopaque) callconv(.C) void {
    _ = midi_in;
    _ = instance;
    _ = param2;
    std.log.info("win in message : {d}", .{msg});

    if (msg == c.MIM_DATA) {
        const Status = packed union {
            voice_message: packed struct {
                channel: u4,
                kind: u4,
            },
            system: u8,
        };

        const MidiInData = packed struct {
            status: Status,
            data: u16,
            __unused: u8,
        };

        const NoteOnEvent = packed struct {
            note: u8,
            velocity: u8,
        };

        var data: MidiInData = @bitCast(@as(u32, @truncate(@intFromPtr(param1))));

        std.log.info("midi message : {b} : {b}", .{ @as(u8, @bitCast(data.status)), @as(u16, @bitCast(data.data)) });

        // Note on
        if (data.status.voice_message.kind == 0b1001) {
            var ev: NoteOnEvent = @bitCast(data.data);
            if (ev.velocity == 0) {
                if (synth.note == ev.note)
                    playNote(null);
            } else {
                playNote(ev.note);
            }
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
    rl.KeyboardKey.key_h, // G#
    rl.KeyboardKey.key_n, // A
    rl.KeyboardKey.key_j, // A#
    rl.KeyboardKey.key_m, // B
};

const keyboard_midi_start = 60;

pub fn playNote(wanted_note: ?u8) void {
    synth.playNote(wanted_note);
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

    var audioStream = rl.loadAudioStream(sampleRate, 32, numChannels);
    rl.setAudioStreamCallback(audioStream, audioCallback);
    rl.playAudioStream(audioStream);

    var numMidi = c.midiInGetNumDevs();
    std.log.info("Found {d} midi devices", .{numMidi});

    if (numMidi > 0) {
        var id: u8 = 0;

        {
            var info: c.MIDIINCAPSA = undefined;
            var status = c.midiInGetDevCapsA(id, &info, @sizeOf(c.MIDIINCAPSA));
            if (status != c.MMSYSERR_NOERROR) {
                std.log.err("Couldn't retrieve info for midi device {d}, errno : {d}", .{ id, status });
            } else {
                var pos = std.mem.indexOfScalar(u8, &info.szPname, 0);
                var name = info.szPname[0 .. pos orelse 32];

                std.log.info("Found midi device with id {d} and name {s}", .{ id, name });
            }
        }

        var phmi: c.HMIDIIN = undefined;
        const CALLBACK_FUNCTION = 0x00030000;
        var status = c.midiInOpen(&phmi, id, @intFromPtr(&midiInCallback), 0, CALLBACK_FUNCTION);
        if (status != c.MMSYSERR_NOERROR) {
            std.log.err("Couldn't open midi device {d}, errno : {d}", .{ id, status });
        }

        _ = c.midiInStart(phmi);
    }

    // Main game loop
    while (!rl.windowShouldClose()) { // Detect window close button or ESC key
        // Update
        //----------------------------------------------------------------------------------
        // TODO: Update your variables here
        //----------------------------------------------------------------------------------

        for (keyboard_map, 0..) |key, index| {
            var midi_key: u8 = @intCast(keyboard_midi_start + index);
            if (rl.isKeyPressed(key)) {
                playNote(midi_key);
            } else if (rl.isKeyReleased(key) and synth.note == midi_key) {
                playNote(null);
            }
        }

        var delta: isize = @as(isize, @intFromBool(rl.isKeyPressed(rl.KeyboardKey.key_kp_subtract))) - @as(isize, @intFromBool(rl.isKeyPressed(rl.KeyboardKey.key_kp_add)));
        if (delta != 0) {
            readback_mutex.lock();
            defer readback_mutex.unlock();
            currentSynth = @mod((currentSynth + delta), Synth.renderers.len);
        }

        // Draw
        //----------------------------------------------------------------------------------
        rl.beginDrawing();
        defer rl.endDrawing();

        if (readback_mutex.tryLock()) {
            defer readback_mutex.unlock();

            if (readback_slice.len > 1024) {
                var our_slice = readback_buffer_copy[0..readback_slice.len];
                for (readback_slice, our_slice) |other, *our| {
                    our.* = other;
                }

                readback_slice_copy = our_slice;
                readback_slice = readback_buffer[0..0];
            }
        }

        const start_x: f32 = 0;
        const start_y: f32 = screenHeight / 2;
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

        const fft_size = 1024;
        if (readback_slice_copy.len > fft_size) {
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

                for (fft_data[0 .. fft_size / 2], 0..) |cp, i| {
                    var mag = linToDb(cp.magnitude()) - linToDb(fft_size);
                    mag = std.math.clamp(mag, -80.0, 0.0);
                    mag = 1.0 + mag / 80.0;
                    mag = std.math.lerp(0.0, screenHeight / 2.0, mag);

                    rl.drawRectangle(
                        @intCast(i),
                        @intFromFloat(start_y),
                        @intCast(1),
                        @intFromFloat(mag),
                        rl.Color.dark_gray,
                    );
                }
            }
        }

        {
            readback_mutex.lock();
            defer readback_mutex.unlock();
            rl.drawText(@ptrCast(Synth.renderers[@intCast(currentSynth)].name), 8, 8, 20, rl.Color.dark_gray);
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
}
