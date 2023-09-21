const std = @import("std");
const rl = @import("lib/raylib-zig.zig");

const c = @cImport({
    @cInclude("Windows.h");
    @cInclude("Mmsystem.h");
});

const sampleRate = 48000;
const numChannels = 2;

var time: f64 = 0.0;
var mutex: std.Thread.Mutex = .{};
var note: ?u8 = null;
var cur_note: ?u8 = null;

var prev_note: u8 = 9;
var cur_vel: f32 = 0;

fn audioCallback(c_buffer: ?*anyopaque, nb_frames: c_uint) callconv(.C) void {
    if (mutex.tryLock()) {
        defer mutex.unlock();
        cur_note = note;
    }

    prev_note = cur_note orelse prev_note;

    var buffer: [*][2]f32 = @ptrCast(@alignCast(c_buffer.?));
    var slice: [][2]f32 = buffer[0..nb_frames];

    const A = 440.0;
    var freq: f32 = (A / 32.0) * std.math.pow(f32, 2.0, @as(f32, @floatFromInt((prev_note) - 9)) / 12.0);

    var target_vel: f32 = if (cur_note != null) 0.50 else 0.0;
    cur_vel = cur_vel + (target_vel - cur_vel) * 0.1;
    for (slice) |*frame| {
        var s: f32 = if (@mod(time, 1.0) > 0.5) 1.0 else -1.0;
        s *= cur_vel;
        frame[0] = s;
        frame[1] = s;
        time += 1.0 / @as(f32, sampleRate) * freq;
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
                if (note == ev.note)
                    playNote(null);
            } else {
                playNote(note);
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
    mutex.lock();
    defer mutex.unlock();
    note = wanted_note;
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
            } else if (rl.isKeyReleased(key) and note == midi_key) {
                playNote(null);
            }
        }

        // Draw
        //----------------------------------------------------------------------------------
        rl.beginDrawing();
        defer rl.endDrawing();

        rl.clearBackground(rl.Color.white);

        rl.drawText("Congrats! You created your first window!", 190, 200, 20, rl.Color.light_gray);
        //----------------------------------------------------------------------------------
    }
}
