const std = @import("std");
const Fifo = @import("fifo.zig").Fifo;
const Voice = @import("voice.zig");

pub const sampleRate = 48000;
pub const numChannels = 2;
pub const nyquist = sampleRate / 2;

const Command = union(enum) { noteOn: struct {
    velocity: u8,
    note: u8,
}, setFilter: struct {
    freq: f32,
}, setRenderer: struct {
    wanted: usize,
} };

const Synth = @This();

commands: Fifo(Command),

voices: [8]Voice = [_]Voice{.{}} ** 8,
workBuffer: [1024][numChannels]f32 = undefined,
current_renderer: usize = 0,

// ==================================================
// ================ MAIN THREAD API =================
// ==================================================

pub fn init(allocator: std.mem.Allocator) !Synth {
    var synth = Synth{
        .commands = Fifo(Command).init(try allocator.alloc(Command, 128)),
    };

    return synth;
}

pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
    allocator.free(self.commands.items);
}

pub fn playNote(self: *Self, wanted_note: u8, velocity: u8) void {
    var note = @max(9, wanted_note);
    self.commands.push(.{ .noteOn = .{ .note = note, .velocity = velocity } }) catch @panic("Couln't play note");
}

pub fn setFilter(self: *Self, freq: f32) void {
    self.commands.push(.{ .setFilter = .{ .freq = freq } }) catch {};
}

pub fn setRenderer(self: *Self, wanted: usize) void {
    self.commands.push(.{ .setRenderer = .{ .wanted = wanted } }) catch {};
}

// ==================================================
// ================ AUDIO THREAD API ================
// ==================================================

pub fn render(self: *Self, buffer: [][numChannels]f32) void {
    while (self.commands.pop()) |command| {
        switch (command) {
            .noteOn => |cmd| {
                if (cmd.velocity > 0) {
                    var voice = self.allocateVoice();
                    voice.playNote(cmd.note, @as(f32, @floatFromInt(cmd.velocity)) / 255.0);
                } else {
                    for (&self.voices) |*voice| {
                        if (voice.note == cmd.note) {
                            voice.release();
                        }
                    }
                }
            },
            .setFilter => |cmd| {
                for (&self.voices) |*voice| {
                    voice.setFilter(cmd.freq);
                }
            },
            .setRenderer => |cmd| {
                self.current_renderer = @mod(cmd.wanted, Voice.renderers.len);
            },
        }
    }

    @memset(buffer, .{ 0.0, 0.0 });

    var remaining_samples = buffer.len;
    while (remaining_samples > 0) : (remaining_samples -|= buffer.len) {
        var work_slice = self.workBuffer[0..@min(remaining_samples, buffer.len)];

        const cb = Voice.renderers[self.current_renderer];
        for (&self.voices) |*voice| {
            cb.cb(voice, work_slice);

            // Mix
            for (buffer, work_slice) |*out, sample| {
                inline for (out, sample) |*o, s| {
                    o.* += s;
                }
            }
        }
    }
}

pub fn allocateVoice(self: *Self) *Voice {
    var max_index: usize = 0;
    var max_time: u32 = 0;
    for (&self.voices, 0..) |*voice, i| {
        if (max_time < voice.playing_time) {
            max_index = i;
            max_time = voice.playing_time;
        }
    }
    return &self.voices[max_index];
}

const Self = @This();
