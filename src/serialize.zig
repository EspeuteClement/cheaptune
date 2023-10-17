const std = @import("std");

const Entry = struct {
    name: []const u8,
    type: type,
    default_value: ?*const anyopaque = null,
    active: bool = true,
};

// Serialization scheme is as follow :
// <entry_id_delta-1> <entry_as_bytes_big_endian>
//
// Entry ids are offset by one internaly because of the -1 sceme
// (because we only encode a filed once and in sequencial order, we can't have 0 as a delta
// so we offset all the deltas by one to save a little bit of data)
// Inactive ids are skipped
//
// It's imperative that the order of fields in the "entries" array remains constant for the whole project
// or else read data will be garbage

pub fn MakeSerializable(comptime entries: []const Entry) type {
    const Type = std.builtin.Type;

    var field_count = 0;
    for (entries) |entry| {
        if (entry.active) {
            field_count += 1;
        }

        var info = @typeInfo(entry.type);
        switch (info) {
            .Float => @compileError("unsuported type : float"),
            else => {},
        }
    }

    var fields: [field_count]Type.StructField = undefined;

    {
        var cur_id = 0;
        for (entries) |entry| {
            if (!entry.active)
                continue;

            fields[cur_id] = .{
                .name = entry.name,
                .type = entry.type,
                .default_value = entry.default_value,
                .is_comptime = false,
                .alignment = @alignOf(entry.type),
            };

            cur_id += 1;
        }
    }

    const T = @Type(.{ .Struct = .{
        .layout = .Auto,
        .fields = &fields,
        .decls = &.{},
        .is_tuple = false,
    } });

    return struct {
        const Struct = T;

        fn serialize(data: T, writter: anytype) !void {
            comptime var previous_written_field: isize = -1;
            inline for (entries, 0..) |field, field_id| {
                if (!field.active)
                    continue;

                const diff: isize = (@as(isize, @intCast(field_id)) - previous_written_field) - 1;
                try writter.writeIntBig(u8, @intCast(diff));
                try writter.writeIntBig(field.type, @field(data, field.name));
                previous_written_field = field_id;
            }
        }

        fn unserialize(reader: anytype) !T {
            var result: T = std.mem.zeroInit(T, .{});

            var current_id: usize = 0;

            while (current_id < entries.len + 1) {
                var read_id: u8 = reader.readIntBig(u8) catch |e| {
                    switch (e) {
                        error.EndOfStream => return result,
                        else => return e,
                    }
                };

                current_id += (read_id + 1);

                inline for (entries, 0..) |entry, entry_id| {
                    if (entry_id == current_id - 1) {
                        var value = try reader.readIntBig(entry.type);

                        if (entry.active) {
                            @field(result, entry.name) = value;
                        }
                    }
                }
            }

            return result;
        }
    };
}

const testStruct = [_]Entry{
    .{ .name = "attack", .type = u16 },
    .{ .name = "decay", .type = u16 },
    .{ .name = "deprecated", .type = u16, .active = false },
    .{ .name = "volume", .type = u16 },
};

test MakeSerializable {
    const Ctx = MakeSerializable(&testStruct);
    const TestStruct = Ctx.Struct;

    var t: TestStruct = undefined;
    t.attack = 42;
    t.decay = 78;
    t.volume = 999;

    var buffer: [512]u8 = undefined;

    var filled_buffer = brk: {
        var stream = std.io.fixedBufferStream(&buffer);
        var writer = stream.writer();
        try Ctx.serialize(t, writer);

        break :brk stream.getWritten();
    };

    {
        var stream = std.io.fixedBufferStream(filled_buffer);
        var reader = stream.reader();
        var d = try Ctx.unserialize(reader);

        try std.testing.expectEqual(t, d);
    }
}

test "Backwards compatibility" {
    const testStruct2 = [_]Entry{
        .{ .name = "attack", .type = u16 },
        .{ .name = "decay", .type = u16 },
        .{ .name = "to_be_deprecated", .type = u16, .active = true },
        .{ .name = "volume", .type = u16 },
    };

    const Ctx2 = MakeSerializable(&testStruct2);
    const TestStruct = Ctx2.Struct;

    var t: TestStruct = undefined;
    t.attack = 75;
    t.decay = 99;
    t.to_be_deprecated = 4242;
    t.volume = 666;

    var buffer: [512]u8 = undefined;

    var filled_buffer = brk: {
        var stream = std.io.fixedBufferStream(&buffer);
        var writer = stream.writer();
        try Ctx2.serialize(t, writer);

        break :brk stream.getWritten();
    };

    const Ctx = MakeSerializable(&testStruct);
    {
        var stream = std.io.fixedBufferStream(filled_buffer);
        var reader = stream.reader();
        var d = try Ctx.unserialize(reader);

        try std.testing.expectEqual(t.attack, d.attack);
        try std.testing.expectEqual(t.decay, d.decay);
        try std.testing.expectEqual(t.volume, d.volume);
    }
}
