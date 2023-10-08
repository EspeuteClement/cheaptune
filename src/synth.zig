const std = @import("std");
const Fifo = @import("fifo.zig").Fifo;
const Voice = @import("voice.zig");
const DCBlocker = @import("dcblocker.zig");

const Midi = @import("midi.zig");

pub const sampleRate = 48000;
pub const numChannels = 2;
pub const nyquist = sampleRate / 2;

const Command = union(enum) {
    noteOn: struct {
        velocity: u8,
        note: u8,
    },
    setFilter: struct {
        freq: f32,
    },
    setRenderer: struct {
        wanted: usize,
    },
    playMidi: struct {
        midi: *Midi,
    },
};

const Synth = @This();

commands: Fifo(Command),

voices: [8]Voice = [_]Voice{.{}} ** 8,
workBuffer: [1024][numChannels]f32 = undefined,
current_renderer: usize = 0,
dc_blockers: [numChannels]DCBlocker = [_]DCBlocker{.{}} ** numChannels,

midi: ?*Midi = null,
midi_next_event: usize = 0,
midi_time_accumulator: f32 = 0.0,
midi_ticks_per_sample: f32 = 0.0,

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

pub fn startMidi(self: *Self, midi: *Midi) void {
    self.midi = midi;
    self.midi_time_accumulator = 0.0;
    self.midi_ticks_per_sample = Midi.tempoToTicksPerSamples(500_000, midi.division, sampleRate);
    self.midi_next_event = 0;

    if (self.midi) |m| {
        for (m.tracks) |track| {
            for (track) |event| {
                // only look at starter events
                if (event.deltatime != 0)
                    break;

                switch (event.data) {
                    .Meta => |meta| {
                        switch (meta) {
                            .SetTempo => |tempo| {
                                self.midi_ticks_per_sample = Midi.tempoToTicksPerSamples(tempo, midi.division, sampleRate);
                            },
                            else => {},
                        }
                    },
                    else => {},
                }
            }
        }
    }
}

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
            .playMidi => |midi| {
                self.startMidi(midi.midi);
            },
        }
    }

    @memset(buffer, .{ 0.0, 0.0 });

    var remaining_samples = buffer.len;
    while (remaining_samples > 0) {
        var samples_to_render = @min(remaining_samples, buffer.len);
        brk: {
            if (self.midi) |midi| {
                var nextEvent: Midi.Event = midi.tracks[2][self.midi_next_event];
                var delta: f32 = @floatFromInt(nextEvent.deltatime);

                // Play events that are just happening right now
                if (delta < self.midi_time_accumulator) {
                    self.midi_time_accumulator -= delta;

                    // small hack
                    nextEvent.deltatime = 0;
                    while (nextEvent.deltatime == 0) {
                        switch (nextEvent.data) {
                            .MidiEvent => |ev| {
                                switch (ev.data) {
                                    .NoteOn => |info| {
                                        if (info.velocity > 0) {
                                            var voice = self.allocateVoice();
                                            voice.playNote(info.note, @as(f32, @floatFromInt(info.velocity)) / 255.0);
                                        } else {
                                            for (&self.voices) |*voice| {
                                                if (voice.note == info.note) {
                                                    voice.release();
                                                }
                                            }
                                        }
                                    },
                                    .NoteOff => |info| {
                                        for (&self.voices) |*voice| {
                                            if (voice.note == info.note) {
                                                voice.release();
                                            }
                                        }
                                    },
                                    else => {},
                                }
                            },
                            .Meta => |meta| {
                                switch (meta) {
                                    .EndOfTrack => {
                                        self.midi = null;
                                        for (&self.voices) |*voice| {
                                            voice.release();
                                        }
                                        break :brk;
                                    },
                                    else => {},
                                }
                            },
                        }

                        self.midi_next_event += 1;
                        if (self.midi_next_event >= midi.tracks[2].len) {
                            break :brk;
                        }
                        nextEvent = midi.tracks[2][self.midi_next_event];
                    }
                }

                var new_delta: f32 = @floatFromInt(nextEvent.deltatime);
                var num_samples: usize = @intFromFloat(new_delta * self.midi_ticks_per_sample);
                samples_to_render = @min(samples_to_render, num_samples);

                self.midi_time_accumulator += @as(f32, @floatFromInt(samples_to_render)) * self.midi_ticks_per_sample;
            }
        }

        var work_slice = self.workBuffer[0..samples_to_render];

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

        remaining_samples -|= samples_to_render;
    }

    for (buffer) |*frame| {
        inline for (frame, 0..) |*sample, i| {
            sample.* = self.dc_blockers[i].tick(sample.*);
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
