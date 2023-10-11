const std = @import("std");
const Fifo = @import("fifo.zig").Fifo;
const Voice = @import("voice.zig");
const DCBlocker = @import("dcblocker.zig");
const ADSR = @import("ADSR.zig");
const Vardelay = @import("vardelay.zig");

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
    setADSR: struct {
        value: f32,
        index: usize,
    },
    setRenderer: struct {
        wanted: usize,
    },
    playMidi: struct {
        midi: *Midi,
    },
    midiIn: Midi.Event.Data.MidiEvent.MidiEventData,
};

const Synth = @This();

const num_voices_max = 8;

commands: Fifo(Command),
base_instrument: Voice.Instrument = .{},

voices: [num_voices_max]Voice = [_]Voice{.{}} ** num_voices_max,
workBuffer: [1024][numChannels]f32 = undefined,
current_renderer: usize = 0,
dc_blockers: [numChannels]DCBlocker = [_]DCBlocker{.{}} ** numChannels,
vardelay: Vardelay = undefined,
vardelay_buffer: [][2]f32 = undefined,

midi: ?*Midi = null,
midi_next_event: usize = 0,
midi_time_accumulator: f32 = 0.0,
midi_samples_per_tick: f32 = 0.0,

volume: f32 = 0.25,

// ==================================================
// ================ MAIN THREAD API =================
// ==================================================

pub fn init(allocator: std.mem.Allocator) !Synth {
    var self = Synth{
        .commands = Fifo(Command).init(try allocator.alloc(Command, 128)),
    };
    errdefer allocator.free(self.commands.items);

    self.vardelay_buffer = try allocator.alloc([2]f32, 4 * sampleRate);
    errdefer allocator.free(self.vardelay_buffer);

    self.vardelay = try Vardelay.init(self.vardelay_buffer, sampleRate);

    return self;
}

pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
    allocator.free(self.commands.items);
    allocator.free(self.vardelay_buffer);
}

pub fn playNote(self: *Self, wanted_note: u8, velocity: u8) void {
    var note = @max(9, wanted_note);
    self.commands.push(.{ .noteOn = .{ .note = note, .velocity = velocity } }) catch @panic("Couln't play note");
}

pub fn setFilter(self: *Self, freq: f32) void {
    self.commands.push(.{ .setFilter = .{ .freq = freq } }) catch {};
}

pub fn midiIn(self: *Self, message: Midi.Event.Data.MidiEvent.MidiEventData) void {
    self.commands.push(.{ .midiIn = message }) catch {};
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
    self.midi_samples_per_tick = Midi.tempoToSamplesPerTick(0x06_1A_80, midi.division, sampleRate);
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
                                self.midi_samples_per_tick = Midi.tempoToSamplesPerTick(tempo, midi.division, sampleRate);
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
                    voice.playNote(cmd.note, @as(f32, @floatFromInt(cmd.velocity)) / 255.0, self.base_instrument);
                } else {
                    for (&self.voices) |*voice| {
                        if (voice.note == cmd.note) {
                            voice.release();
                        }
                    }
                }
            },
            .setADSR => |cmd| {
                const fields = @typeInfo(ADSR.Parameters).Struct.fields;
                inline for (fields, 0..) |field, i| {
                    if (cmd.index == i) {
                        @field(self.base_instrument.adsr_params, field.name) = cmd.value;
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
            .midiIn => |ev| {
                switch (ev) {
                    .NoteOn => |cmd| {
                        var voice = self.allocateVoice();
                        voice.playNote(cmd.note, @as(f32, @floatFromInt(cmd.velocity)) / 255.0, self.base_instrument);
                    },
                    .NoteOff => |cmd| {
                        for (&self.voices) |*voice| {
                            if (voice.note == cmd.note) {
                                voice.release();
                            }
                        }
                    },
                    .ControlChange => |cmd| {
                        for (&self.voices) |*voice| {
                            switch (cmd.controller_id) {
                                0b111 => {
                                    voice.setFilter(Midi.midiToLogRange(cmd.value, 20.0, 24000.0));
                                },
                                else => {},
                            }
                        }
                    },
                    else => {},
                }
            },
        }
    }

    @memset(buffer, .{ 0.0, 0.0 });

    var sub_buffer = buffer;
    while (sub_buffer.len > 0) {
        var samples_to_render = @min(sub_buffer.len, self.workBuffer.len);
        brk: {
            if (self.midi) |midi| {
                var nextEvent: Midi.Event = midi.tracks[2][self.midi_next_event];
                var delta: f32 = @floatFromInt(nextEvent.deltatime);

                // Play events that are just happening right now
                if (delta <= self.midi_time_accumulator) {
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
                                            voice.playNote(info.note, @as(f32, @floatFromInt(info.velocity)) / 255.0, self.base_instrument);
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

                var ticks_to_next_event: f32 = @as(f32, @floatFromInt(nextEvent.deltatime)) - self.midi_time_accumulator;
                var samples_to_next_event: usize = @intFromFloat(ticks_to_next_event * self.midi_samples_per_tick);
                samples_to_next_event = @max(1, samples_to_next_event);
                samples_to_render = @min(samples_to_render, samples_to_next_event);

                self.midi_time_accumulator += @as(f32, @floatFromInt(samples_to_render)) / self.midi_samples_per_tick;
            }
        }

        var work_slice = self.workBuffer[0..samples_to_render];

        const cb = Voice.renderers[self.current_renderer];
        for (&self.voices) |*voice| {
            cb.cb(voice, work_slice);

            // Mix
            for (sub_buffer[0..samples_to_render], work_slice) |*out, sample| {
                inline for (out, sample) |*o, s| {
                    o.* += s * self.volume;
                }
            }
        }

        for (sub_buffer[0..samples_to_render]) |*out| {
            var del = out.*;
            for (&del) |*d| {
                d.* *= 0.5;
            }
            del = self.vardelay.tick(del, .{});
            for (del, out) |d, *s| {
                s.* += d;
            }
        }

        sub_buffer = sub_buffer[samples_to_render..];
    }

    // for (buffer) |*frame| {
    //     inline for (frame, 0..) |*sample, i| {
    //         sample.* = self.dc_blockers[i].tick(sample.*);
    //     }
    // }
}

pub fn allocateVoice(self: *Self) *Voice {
    var max_index: ?usize = null;
    var max_time: u32 = 0;

    for (&self.voices, 0..) |*voice, i| {
        if (voice.gate < 0.01) {
            if (max_time < voice.playing_time) {
                max_index = i;
                max_time = voice.playing_time;
            }
        }
    }
    if (max_index == null) {
        for (&self.voices, 0..) |*voice, i| {
            if (max_time < voice.playing_time) {
                max_index = i;
                max_time = voice.playing_time;
            }
        }
    }

    return &self.voices[max_index orelse 0];
}

const Self = @This();
