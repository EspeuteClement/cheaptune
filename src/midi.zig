// Midi file format reader
// reference used : https://www.cs.cmu.edu/~music/cmsip/readings/Standard-MIDI-file-format-updated.pdf
// Variable Length Quantity Number
const std = @import("std");

const Midi = @This();

pub const Event = struct {
    deltatime: u32,
    data: Data,

    pub const Data = union(enum) {
        MidiEvent: MidiEvent,
        // Sysex events are skipped for the moment
        Meta: Meta,

        const MidiEvent = struct {
            channel: u4,
            data: MidiEventData,

            const MidiEventData = union(MidiEventKind) {
                NoteOff: struct {
                    note: u7,
                    velocity: u7,
                },
                NoteOn: struct {
                    note: u7,
                    velocity: u7,
                },
                KeyPressure: struct {
                    note: u7,
                    value: u7,
                },
                ControlChange: struct {
                    controller_id: u7,
                    value: u7,
                },
                ProgramChange: u7,
                ChannelPressure: u7,
                PitchWheelChange: u14,
                SystemExclusive: void,
                SongPositionPointer: u14,
                SongSelect: u7,
                TuneRequest: void,
                SystemExclusiveEnd: void,
                TimingClock: void,
                RTMStart: void,
                RTMContinue: void,
                RTMStop: void,
                ActiveSensing: void,
                Reset: void,
            };
        };

        const Meta = union(enum) {
            EndOfTrack: void,
            SetTempo: u24,
            TimeSignature: struct {
                numerator: u8,
                denominator: u8,
                clocks_per_metronome_clic: u8,
                number_of_notated_32nd_notes: u8, // ????
            },
        };
    };
};

const MidiEventKind = enum(u8) {
    NoteOff = 0b1000_0000,
    NoteOn = 0b1001_0000,
    KeyPressure = 0b1010_0000,
    ControlChange = 0b1011_0000,
    ProgramChange = 0b1100_0000,
    ChannelPressure = 0b1101_0000,
    PitchWheelChange = 0b1110_0000,
    SystemExclusive = 0b1111_0000,
    SongPositionPointer = 0b111_10001,
    SongSelect = 0b1111_0011,
    TuneRequest = 0b1111_0110,
    SystemExclusiveEnd = 0b1111_0111,
    TimingClock = 0b1111_1000,
    RTMStart = 0b1111_1010,
    RTMContinue = 0b1111_1011,
    RTMStop = 0b1111_1100,
    ActiveSensing = 0b1111_1110,
    Reset = 0b1111_1111,

    pub fn fromInt(data: u8) ?MidiEventKind {
        inline for (@typeInfo(@This()).Enum.fields) |kind| {
            if (comptime kind.value & 0xF0 == 0xF0) {
                if (kind.value == data) {
                    return @enumFromInt(kind.value);
                }
            } else {
                if (kind.value == (@as(u8, data) & 0xF0)) {
                    return @enumFromInt(kind.value);
                }
            }
        }
        return null;
    }
};

division: u16,
tracks: [][]Event = &.{},

pub fn parse(bytes: []const u8, allocator: std.mem.Allocator) !Midi {
    var stream = bytes;

    const track_header = brk: {
        var header = try parseChunkHeader(&stream);
        if (header != .MThd)
            return error.InvalidFile;
        var len = try parseNumber(u32, &stream);

        var next_chunk = stream;
        seek(&next_chunk, len);

        defer stream = next_chunk;

        break :brk .{
            .format = try parseNumber(u16, &stream),
            .tracks = try parseNumber(u16, &stream),
            .division = try parseNumber(u16, &stream),
        };
    };

    var tracks = try allocator.alloc([]Event, track_header.tracks);
    errdefer {
        for (tracks) |track| {
            if (track.len != 0) {
                allocator.free(track);
            }
        }
        allocator.free(tracks);
    }

    if (track_header.division & 0x8000 != 0) {
        std.log.err("Non tick based time division is not currently supported", .{});
        return error.UnsupportedTimeDivision;
    }

    var current_track: usize = 0;
    while (stream.len > 0) {
        var header = try parseChunkHeader(&stream);
        var len = try parseNumber(u32, &stream);

        var substream = stream[0..len];
        var next_chunk = stream;
        seek(&next_chunk, len);

        switch (header) {
            .MThd => {
                return error.InvalidFile;
            },
            .MTrk => {
                tracks[current_track] = try parseTrack(&substream, allocator);
                current_track += 1;
            },
            .Unknown => {},
        }

        stream = next_chunk;
    }

    return .{
        .division = track_header.division,
        .tracks = tracks,
    };
}

pub fn deinit(self: *Midi, allocator: std.mem.Allocator) void {
    for (self.tracks) |track| {
        std.debug.print("\n{*} {d}\n", .{ track.ptr, track.len });
        allocator.free(track);
    }
    allocator.free(self.tracks);
    self.* = undefined;
}

fn parseTrack(stream: *[]const u8, allocator: std.mem.Allocator) ![]Event {
    var track = std.ArrayList(Event).init(allocator);
    errdefer track.deinit();

    var previousEvent: ?MidiEventKind = null;
    while (stream.len > 0) {
        var deltatime = try parseVQL(stream);
        var kind = try parseNumber(u8, stream);
        var data: ?Event.Data = brk: {
            switch (kind) {
                // Meta
                0xFF => {
                    if (try parseMetaMessage(stream)) |meta| {
                        break :brk Event.Data{ .Meta = meta };
                    } else {
                        break :brk null;
                    }
                },
                // Sysex
                0xF7, 0xF0 => {
                    // Just ingnore sysex packets atm
                    const len = try parseVQL(stream);
                    seek(stream, len);
                    break :brk null;
                },
                else => {
                    var channel: u4 = if (kind & 0xF0 != 0xF) @truncate(kind & 0xF) else 0;
                    var data = try parseMidiEvent(stream, kind, previousEvent);
                    previousEvent = data;
                    break :brk .{ .MidiEvent = .{
                        .channel = channel,
                        .data = data,
                    } };
                },
            }
        };

        if (data) |d| {
            var event = try track.addOne();
            event.deltatime = deltatime;
            event.data = d;
        }
    }

    return track.toOwnedSlice();
}

pub fn parseMidiEvent(stream: *[]const u8, first_byte: u8, previous: ?MidiEventKind) !Event.Data.MidiEvent.MidiEventData {
    var kind = MidiEventKind.fromInt(first_byte) orelse previous orelse return error.InvalidFile;
    return switch (kind) {
        .NoteOff => .{ .NoteOff = .{
            .note = @truncate(try parseNumber(u8, stream)),
            .velocity = @truncate(try parseNumber(u8, stream)),
        } },
        .NoteOn => .{ .NoteOn = .{
            .note = @truncate(try parseNumber(u8, stream)),
            .velocity = @truncate(try parseNumber(u8, stream)),
        } },
        .KeyPressure => .{ .KeyPressure = .{
            .note = @truncate(try parseNumber(u8, stream)),
            .value = @truncate(try parseNumber(u8, stream)),
        } },
        .ControlChange => .{ .ControlChange = .{
            .controller_id = @truncate(try parseNumber(u8, stream)),
            .value = @truncate(try parseNumber(u8, stream)),
        } },
        .ProgramChange => .{ .ProgramChange = @truncate(try parseNumber(u8, stream)) },
        .ChannelPressure => .{ .ChannelPressure = @truncate(try parseNumber(u8, stream)) },
        .PitchWheelChange => .{ .PitchWheelChange = @as(u14, try parseNumber(u8, stream)) + (@as(u14, try parseNumber(u8, stream)) << 7) },
        .SystemExclusive => brk: {
            // Just skip bytes
            while (true) {
                var value = try parseNumber(u8, stream);
                if (value == @intFromEnum(MidiEventKind.SystemExclusiveEnd)) {
                    break;
                }
            }
            break :brk .SystemExclusive;
        },
        .SongPositionPointer => .{ .SongPositionPointer = @as(u14, try parseNumber(u8, stream)) + (@as(u14, try parseNumber(u8, stream)) << 7) },
        .SongSelect => .{ .SongSelect = @truncate(try parseNumber(u8, stream)) },
        .TuneRequest => .TuneRequest,
        .SystemExclusiveEnd => .SystemExclusiveEnd,
        .TimingClock => .TimingClock,
        .RTMStart => .RTMStart,
        .RTMContinue => .RTMContinue,
        .RTMStop => .RTMStop,
        .ActiveSensing => .ActiveSensing,
        .Reset => .Reset,
    };
}

pub fn tempoToTicksPerSamples(midi_tempo: u24, ticks_per_quarternote: u16, sample_rate: u32) f32 {
    var tempo: f32 = @floatFromInt(midi_tempo);
    var fsr: f32 = @floatFromInt(sample_rate);
    var fticks_per_quarternote: f32 = @floatFromInt(ticks_per_quarternote);

    var tick_len_s = (tempo / std.time.us_per_s) / fticks_per_quarternote;
    return tick_len_s * fsr;
}

fn parseMetaMessage(stream: *[]const u8) !?Event.Data.Meta {
    const kind = try parseNumber(u8, stream);
    const len = try parseVQL(stream);

    var end_stream = stream.*;
    seek(&end_stream, len);
    defer stream.* = end_stream;

    switch (kind) {
        0x2F => return .EndOfTrack,
        0x51 => return .{ .SetTempo = try parseNumber(u24, stream) },
        0x58 => return .{ .TimeSignature = .{
            .numerator = try parseNumber(u8, stream),
            .denominator = try parseNumber(u8, stream),
            .clocks_per_metronome_clic = try parseNumber(u8, stream),
            .number_of_notated_32nd_notes = try parseNumber(u8, stream),
        } },
        else => {
            return null;
        },
    }
}

// Tries to read a Variable Lenght Quantity from "stream",
// updating the slice to point to the next byte to read if
// the read is successful
fn parseVQL(stream: *[]const u8) !u31 {
    // VQL are only valid for 4 bytes
    var stream_copy = stream.*;
    var parsed_number: u31 = 0;
    for (0..4) |_| {
        if (stream_copy.len <= 0) {
            return error.EndOfStream;
        }
        const byte = stream_copy[0];
        stream_copy = stream_copy[1..];
        parsed_number = @as(u31, byte & 0x7F) + (parsed_number << 7);

        // 8th bit of last the byte is the only one that is cleared
        if ((byte & 0b1000_0000) == 0) {
            break;
        }
    } else {
        return error.NumberTooLarge;
    }

    stream.* = stream_copy;
    return parsed_number;
}

const ChunkHeader = enum {
    MThd,
    MTrk,
    Unknown,
};

const chunk_header_fourCC: []const u32 = brk: {
    var ch_type_info: std.builtin.Type.Enum = @typeInfo(ChunkHeader).Enum;

    var fourCCs: [ch_type_info.fields.len - 1]u32 = undefined;
    for (ch_type_info.fields) |field| {
        if (field.value == @intFromEnum(ChunkHeader.Unknown))
            continue;

        fourCCs[field.value] = std.mem.readIntSlice(u32, field.name[0..4], .Big);
    }
    break :brk &fourCCs;
};

fn parseNumber(comptime T: type, stream: *[]const u8) !T {
    const n = @divExact(@typeInfo(T).Int.bits, 8);
    if (stream.len < n)
        return error.EndOfStream;
    var number: T = std.mem.readInt(T, stream.*[0..n], .Big);
    seek(stream, n);
    return number;
}

fn seek(stream: *[]const u8, bytes: usize) void {
    if (stream.len < bytes)
        stream.* = &.{};
    stream.* = stream.*[bytes..];
}

fn parseChunkHeader(stream: *[]const u8) !ChunkHeader {
    if (stream.len < 4)
        return error.EndOfStream;

    var read_header: u32 = try parseNumber(u32, stream);

    for (chunk_header_fourCC, 0..) |header, i| {
        if (header == read_header) {
            return @enumFromInt(i);
        }
    }
    return .Unknown;
}

test parseChunkHeader {
    var stream: []const u8 = "MThdMTrkAAAA";
    var expectedData: []const anyerror!ChunkHeader = &[_]anyerror!ChunkHeader{ .MThd, .MTrk, .Unknown, error.EndOfStream };

    for (expectedData) |expect| {
        var header = parseChunkHeader(&stream);
        try std.testing.expectEqual(expect, header);
    }
}

test parseNumber {
    // zig fmt: off
    const data: []const u8 = &[_]u8 {
        0x12, 
        0x12, 0x34,
        0x12, 0x34, 0x56,
        0x12, 0x34, 0x56, 0x78,
    };
    // zig fmt: on

    var stream = data;
    try std.testing.expectEqual(@as(u8, 0x12), try parseNumber(u8, &stream));
    try std.testing.expectEqual(@as(u16, 0x1234), try parseNumber(u16, &stream));
    try std.testing.expectEqual(@as(u24, 0x123456), try parseNumber(u24, &stream));
    try std.testing.expectEqual(@as(u32, 0x12345678), try parseNumber(u32, &stream));
}

test parseVQL {
    {
        // zig fmt: off
        var data: []const u8 = &[_]u8 {
            0x00,
            0x40,
            0x7F,
            0x81, 0x00,
            0xC0, 0x00,
            0xFF, 0x7F,
            0x81, 0x80, 0x00,
            0xC0, 0x80, 0x00,
            0xFF, 0xFF, 0x7F,
            0x81, 0x80, 0x80 , 0x00,
            0xC0, 0x80, 0x80 , 0x00,
            0xFF, 0xFF, 0xFF , 0x7F,
        };

        var results = [_]u31 {
            0x00000000,
            0x00000040,
            0x0000007F,
            0x00000080,
            0x00002000,
            0x00003FFF,
            0x00004000,
            0x00100000,
            0x001FFFFF,
            0x00200000,
            0x08000000,
            0x0FFFFFFF
        };
        // zig fmt: on

        var stream = data;
        for (results) |result| {
            var n: u31 = try parseVQL(&stream);
            try std.testing.expectEqual(result, n);
        }

        {
            var beforeEOF = stream;
            try std.testing.expectError(error.EndOfStream, parseVQL(&stream));
            try std.testing.expectEqual(beforeEOF, stream);
        }
    }

    {
        var too_big_stream: []const u8 = &[_]u8{
            0xFF, 0xFF, 0xFF, 0xFF, 0x7F,
        };
        var beforeEOF = too_big_stream;
        try std.testing.expectError(error.NumberTooLarge, parseVQL(&too_big_stream));
        try std.testing.expectEqual(beforeEOF, too_big_stream);
    }
}

test {
    _ = chunk_header_fourCC;
    std.testing.refAllDeclsRecursive(@This());
}

test Midi {
    var midi_data = @embedFile("tests/test_midi.mid");

    var parsed = try parse(midi_data[0..], std.testing.allocator);
    defer parsed.deinit(std.testing.allocator);

    for (parsed.tracks[2]) |ev| {
        std.debug.print("dt:{d: >6}, kind: {s}", .{ ev.deltatime, @tagName(ev.data) });
        switch (ev.data) {
            .MidiEvent => |mev| {
                std.debug.print(", kind {s}", .{@tagName(mev.data)});

                switch (mev.data) {
                    .NoteOn => |info| {
                        std.debug.print(" note: {d}, vel: {d}", .{ info.note, info.velocity });
                    },
                    else => {},
                }
            },
            else => {},
        }

        std.debug.print("\n", .{});
    }
}
