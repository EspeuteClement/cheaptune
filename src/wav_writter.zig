const std = @import("std");

hdr: RiffHeader = .{},

const Self = @This();

const RiffHeader = extern struct {
    riff: [4]u8 = [_]u8{ 'R', 'I', 'F', 'F' },
    size: u32 = 0,
    wave: [4]u8 = [_]u8{ 'W', 'A', 'V', 'E' },
    ftm: [4]u8 = [_]u8{ 'f', 'm', 't', ' ' },
    ftm_len: u32 = 16,
    fmt_type: u16 = 1, // 1 for pcm data
    num_channles: u16 = 2,
    sample_rate: u32 = 48000,
    kbps: u32 = (48000 * 4 * 2) / 8,
    bytesPerSample: u16 = 4, // 16bit stereo
    bitsPerSample: u16 = 16,
    data_header: [4]u8 = [_]u8{ 'd', 'a', 't', 'a' },
    data_len: u32 = 0,

    comptime {
        if (@sizeOf(RiffHeader) != 44) {
            @compileError("Riff header size != 44");
        }
    }
};

fn init(len: u32) Self {
    return .{
        .hdr = .{
            .size = @sizeOf(RiffHeader) + len * 4 - 8,
            .data_len = len * 4,
        },
    };
}

fn writeHeader(self: *Self, writer: anytype) !void {
    try writer.writeStruct(self.hdr);
}

fn writeDataFloat(_: Self, buffer: [][2]f32, writer: anytype) !void {
    for (buffer) |frame| {
        inline for (frame) |sample| {
            var convert: i16 = @intFromFloat(sample * std.math.maxInt(i16));
            try writer.writeIntNative(i16, convert);
        }
    }
}

test {
    var file = try std.fs.cwd().createFile("test.wav", .{});
    var wav_writter: Self = Self.init(48000 * 3);

    var file_writter = file.writer();
    try wav_writter.writeHeader(file_writter);

    var buffer = try std.testing.allocator.alloc([2]f32, 48000 * 3);
    defer std.testing.allocator.free(buffer);
    const step = 440.0 / 48000.0;
    var time: f32 = 0.0;
    for (buffer) |*frame| {
        inline for (frame) |*sample| {
            sample.* = std.math.cos(time * std.math.tau) * 0.25;
        }
        time = @mod(time + step, 1.0);
    }

    try wav_writter.writeDataFloat(buffer, file_writter);
}
