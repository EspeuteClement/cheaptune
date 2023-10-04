const std = @import("std");
const Fifo = @import("fifo.zig").Fifo;

pub const sampleRate = 48000;
pub const numChannels = 2;
pub const nyquist = sampleRate / 2;

const Command = union(enum) {
    noteOn: struct {
        velocity: u8,
        note: u8,
    },
};

const Synth = @This();

time: f64 = 0.0,

commands: Fifo(Command),

mutex: std.Thread.Mutex = .{},
cur_freq: f64 = 0.0,

note: u8 = 9,
velocity: f32 = 0.0,

cur_vel: f32 = 0.0,

pub fn init(allocator: std.mem.Allocator) !Synth {
    var synth = Synth{
        .commands = Fifo(Command).init(try allocator.alloc(Command, 128)),
    };

    return synth;
}

pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
    allocator.free(self.commands.items);
}

pub const render = renderBandlimited;

pub fn renderCommon(self: *Self, buffer: [][numChannels]f32) void {
    _ = buffer;
    while (self.commands.pop()) |command| {
        switch (command) {
            .noteOn => |cmd| {
                if (cmd.note == self.note or cmd.velocity != 0) {
                    self.velocity = @floatFromInt(cmd.velocity);
                    self.note = cmd.note;

                    const A = 440.0;
                    self.cur_freq = (A / 32.0) * std.math.pow(f32, 2.0, @as(f32, @floatFromInt((self.note) - 9)) / 12.0);
                }
            },
        }
    }

    var target_vel: f32 = self.velocity;
    self.cur_vel = self.cur_vel + (target_vel - self.cur_vel) * 0.1;
}

pub fn renderNaive(self: *Self, buffer: [][numChannels]f32) void {
    self.renderCommon(buffer);

    for (buffer) |*frame| {
        var s: f32 = if (@mod(self.time, 1.0) > 0.5) 1.0 else -1.0;
        s *= self.cur_vel;
        inline for (frame) |*sample| {
            sample.* = s;
        }
        self.time += 1.0 / @as(f32, sampleRate) * self.cur_freq;
    }
}

pub fn renderSine(self: *Self, buffer: [][numChannels]f32) void {
    self.renderCommon(buffer);

    for (buffer) |*frame| {
        var s: f32 = @floatCast(@sin(self.time * std.math.tau + @sin(self.time * std.math.tau * 2.0 + @sin(self.time * std.math.tau * 2.0))));
        s *= self.cur_vel;
        inline for (frame) |*sample| {
            sample.* = s;
        }
        self.time += 1.0 / @as(f64, sampleRate) * self.cur_freq;
        self.time = std.math.mod(f64, self.time, 1.0) catch unreachable;
    }
}

pub fn renderBandlimited(self: *Self, buffer: [][numChannels]f32) void {
    self.renderCommon(buffer);

    for (buffer) |*frame| {
        var neededHarmonics: usize = @intFromFloat(@floor(nyquist / self.cur_freq));
        neededHarmonics = @min(neededHarmonics, 50);
        var s: f32 = 0.0;
        for (0..std.math.shr(usize, neededHarmonics, 1)) |harmonic| {
            const fharmonic: f32 = @floatFromInt(harmonic * 2 + 1);

            s += 1.0 / (fharmonic) * @sin(@as(f32, @floatCast(self.time * std.math.tau)) * fharmonic);
        }

        s *= 4.0 / std.math.pi;

        s *= self.cur_vel;
        inline for (frame) |*sample| {
            sample.* = s;
        }
        self.time += 1.0 / @as(f32, sampleRate) * self.cur_freq;
        self.time = std.math.mod(f64, self.time, 1.0) catch unreachable;
    }
}

pub inline fn blep(dt: f32, tIn: f32) f32 {
    var t = tIn;
    if (t < dt) {
        t /= dt;
        return t + t - t * t - 1.0;
    } else if (t > 1.0 - dt) {
        t = (t - 1.0) / dt;
        return t * t + t + t + 1.0;
    }
    return 0.0;
}

pub fn renderBlep(self: *Self, buffer: [][numChannels]f32) void {
    self.renderCommon(buffer);

    const inc: f32 = 1.0 / @as(f32, sampleRate) * @as(f32, @floatCast(self.cur_freq));
    for (buffer) |*frame| {
        var v: f32 = if (self.time < 0.5) 1.0 else -1.0;

        v += blep(inc, @floatCast(self.time));
        v -= blep(inc, @floatCast(@mod(self.time + 0.5, 1.0)));

        var s = v;
        s *= self.cur_vel;
        inline for (frame) |*sample| {
            sample.* = s;
        }
        self.time += @floatCast(inc);
        self.time = std.math.mod(f64, self.time, 1.0) catch unreachable;
    }
}

pub const renderers = [_]struct { name: []const u8, cb: *const fn (*Self, [][2]f32) void }{
    .{ .name = "PolyBlep", .cb = &renderBlep },
    .{ .name = "Naive", .cb = &renderNaive },
    .{ .name = "Sine", .cb = &renderSine },
    .{ .name = "Band Limited", .cb = &renderBandlimited },
};

pub fn playNote(self: *Self, wanted_note: ?u8) void {
    var note = wanted_note orelse 9;
    var volume: u8 = if (wanted_note == null) 0 else 255;
    self.commands.push(.{ .noteOn = .{ .note = note, .velocity = volume } }) catch {};
}

const Self = @This();
