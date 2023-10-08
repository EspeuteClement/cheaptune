// Midi file format reader
// reference used : https://www.cs.cmu.edu/~music/cmsip/readings/Standard-MIDI-file-format-updated.pdf
// Variable Length Quantity Number
const std = @import("std");

// Tries to read a Variable Lenght Quantity from "stream",
// updating the slice to point to the next byte to read if
// the read is successful
pub fn parseVQL(stream: *[]const u8) !u31 {
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

test parseVQL {
    {
        // zig fmt: off
        var stream: []const u8 = &[_]u8 {
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

test {}
