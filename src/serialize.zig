const std = @import("std");

/// # Serialize.zig
/// ## Disclaimer
/// This library has not been thoroughly tested against malicious data and properly fused.
/// Most of the library assumes that the reader interface will properly handle data that is
/// too long. There is also currently no checksum in place to check if the data has been
/// properly deserialized.
/// Use at your own risk.
/// ## Goals
/// Proof of concept serialization library for zig, with built in versioning and
/// backwards compatibility (can open previous version of serialized data), with
/// support for custom upgrade functions, serializable inside a serializable struct and
/// slices.
/// ## Usage
/// Use the `Serializable` function to create a Struct that will contains the following decls :
/// - `Struct` : The actual struct you can use to store your data
/// - `serialize(value: Struct, writer: anytype) !void` : The function that will allow you to serialize your data
/// to the writer struct of your choice as a binary stream.
/// - `deserialize(reader:anytype, allocator: ?std.mem.Allocator) !Struct` : The function to transform data outputted by the serialize function back to a Struct. Optionally takes an allocator if Struct has some dynamically allocated data (if you used `Record.addMany()` or `Record.addSerMany()` inside).
///
/// The `Serializable` function takes a Definition as its sole parameter. This `Definition` is a slice of `Version`, which is a slice of `Record`
/// Records are additions or removals of fields to the final struct. Here's an example :
/// ```zig
///     const ser: Definition = &.{
///         // V0
///         &.{
///             Record.add("foo", u8, 42),
///         },
///         // V1
///         &.{
///             Record.add("bar", u8, 0),
///             Record.remove("foo"),
///         },
///     };
///
///     var Ser = Serializable(Definition);
///     var ser : Ser.Struct;
///     ser.bar = 99;
///
///     // serialize to a writer
///     Ser.serialize(ser, writer);
///
///     // deserialize from a reader
///     var other_ser = Ser.deserialize(reader, null);
/// ```
/// We can see that the Version 0 of our struct will only have a `foo` field that is an u8 and will have a default value of 42
/// then in version 1 we add the `bar` field and remove the old `foo` field.
/// The Serializable(ser) function will then gives us a struct with the decl Struct equals to
/// Struct = struct {
///     bar : u8 = 0,
/// };
/// ## Supported features
/// - Serialize arbitrary integer values
/// - Serialize arbitrary packed structs
/// - Serialize arrays of the above types
/// - Serialize other serializable objects : use Record.addSer();
/// - Serialize slices of the above types : use Record.addMany() or Record.addSerMany();
/// Floating point types are not supported as they don't have a portable memory layout representation
/// ## Binary format
/// ```
/// header :
///     struct_version: u16
///     struct_hash: u32  // Struct hash is a hash of the name and types of all the fields present in this version of the struct, used
///                       // to check if the saved struct has the same layout as the one we are trying to load
///
/// fields :
///     for each field in the struct:
///         if the value is a simple type:
///             the value serialized as a little endian integer
///         if the value is an array type:
///             for array.len:
///                 the value serialized as a little endian integer
///         if the value is a serializable
///             the serializable serialized with its header
///         if the value is a slice
///             length of the slice: u16
///             then the value serialized as one of the above types
/// ```
pub const Version = []const Record;
pub const Definition = []const Version;

pub const Record = union(enum) {
    Add: Add,
    Delete: Delete,
    Convert: ConvertFunc,

    pub const ConvertFunc = *const fn (from: anytype, to: anytype) void;

    pub const Add = struct {
        name: []const u8,
        info: Info,
    };

    pub const Info = struct {
        type: FieldType,
        default: ?*const anyopaque,
        size: Size,

        const FieldType = union(enum) {
            type: type,
            serializable: type,
        };

        const Size = enum {
            One,
            Many,
        };

        pub fn getType(comptime self: Info) type {
            return switch (self.size) {
                .One => self.getSimpleType(),
                .Many => []self.getSimpleType(),
            };
        }

        pub fn getSimpleType(comptime self: Info) type {
            return switch (self.type) {
                .type => |t| t,
                .serializable => |s| s.Struct,
            };
        }

        fn deserializeOne(comptime self: Info, reader: anytype, allocator: ?std.mem.Allocator) !self.getSimpleType() {
            switch (self.type) {
                .type => |T| {
                    return readValue(T, reader);
                },
                .serializable => |ser| {
                    return ser.deserialize(reader, allocator);
                },
            }
        }

        fn serializeOne(comptime self: Info, value: self.getSimpleType(), writer: anytype) !void {
            switch (self.type) {
                .type => {
                    try writeValue(value, writer);
                },
                .serializable => |ser| {
                    try ser.serialize(value, writer);
                },
            }
        }
    };

    pub const Delete = struct {
        name: []const u8,
    };

    pub fn add(comptime name: []const u8, comptime T: type, comptime def: T) Record {
        return .{ .Add = .{ .name = name, .info = .{
            .type = .{ .type = T },
            .default = &def,
            .size = .One,
        } } };
    }

    pub fn addMany(comptime name: []const u8, comptime T: type, comptime def: []const T) Record {
        return .{ .Add = .{ .name = name, .info = .{
            .type = .{ .type = T },
            .default = @ptrCast(&def),
            .size = .Many,
        } } };
    }

    pub fn addSer(comptime name: []const u8, comptime ser: Definition) Record {
        return .{ .Add = .{ .name = name, .info = .{
            .type = .{ .serializable = ser },
            .default = null,
            .size = .One,
        } } };
    }

    pub fn addSerMany(comptime name: []const u8, comptime ser: Definition) Record {
        var SerT = Serializable(ser);
        const def: []SerT.Struct = &.{};
        return .{ .Add = .{ .name = name, .info = .{
            .type = .{ .serializable = SerT },
            .default = @ptrCast(&def),
            .size = .Many,
        } } };
    }

    pub fn del(comptime name: []const u8) Record {
        return .{ .Delete = .{
            .name = name,
        } };
    }
};

pub fn Serializable(comptime serializable: Definition) type {
    // poors man hashmap
    const Store = struct { name: []const u8, info: Record.Info, deleted: bool };
    var fields_info: [256]Store = undefined;
    var fields_slice: []Store = fields_info[0..0];

    comptime var versionTypes: [serializable.len]type = undefined;

    for (serializable, 0..) |version, version_id| {
        var convertFunc: ?Record.ConvertFunc = null;

        for (version) |record| {
            switch (record) {
                .Add => |add| {
                    for (fields_slice) |*field| {
                        if (std.mem.eql(u8, field.name, add.name)) {
                            if (!field.deleted) {
                                @compileError("Can't add field " ++ add.name ++ " as it already exists in previous version");
                            }
                            field.info = add.info;
                            field.deleted = false;
                            break;
                        }
                    } else {
                        fields_slice = fields_info[0 .. fields_slice.len + 1];
                        fields_slice[fields_slice.len - 1] = .{
                            .name = add.name,
                            .info = add.info,
                            .deleted = false,
                        };
                    }
                },
                .Delete => |del| {
                    for (fields_slice) |*field| {
                        if (std.mem.eql(u8, field.name, del.name)) {
                            if (field.deleted) {
                                @compileError("Can't remove field " ++ del.name ++ " as it was already removed in previous version");
                            }
                            field.deleted = true;
                            break;
                        }
                    } else {
                        @compileError("Can't remove field " ++ del.name ++ " as it does not exist");
                    }
                },
                .Convert => |func| {
                    if (convertFunc != null)
                        @compileError("A convert func already defined for this version");
                    convertFunc = func;
                },
            }
        }

        var count_active: usize = 0;
        for (fields_slice) |field| {
            if (field.deleted == false)
                count_active += 1;
        }

        var struct_fields: [count_active]std.builtin.Type.StructField = undefined;
        var field_packed: [count_active]SerFieldInfo = undefined;

        var count: usize = 0;
        for (fields_slice) |field| {
            if (field.deleted)
                continue;
            defer count += 1;
            field_packed[count] = .{
                .name = field.name,
                .info = field.info,
            };

            var def_value = field.info.default;
            var T: type = field.info.getType();

            if (def_value == null) {
                const def: T = std.mem.zeroInit(T, .{});
                def_value = &def;
            }

            struct_fields[count] = .{
                .name = field.name,
                .type = T,
                .default_value = def_value,
                .is_comptime = false,
                .alignment = @alignOf(T),
            };
        }

        const VersionType: type = @Type(.{ .Struct = .{
            .layout = .Auto,
            .fields = &struct_fields,
            .decls = &.{},
            .is_tuple = false,
        } });

        const field_packed_final = field_packed;

        const PreviousVersionType = if (version_id > 1) versionTypes[version_id - 1] else versionTypes[0];

        const finalConvert = convertFunc;

        versionTypes[version_id] = struct {
            pub const Struct = VersionType;
            pub const version_fields = field_packed_final;
            pub const hash = getVersionHash(&version_fields);

            pub fn deserialize(value: *Struct, reader: anytype, allocator: ?std.mem.Allocator) !void {
                inline for (version_fields) |field| {
                    switch (field.info.size) {
                        .One => {
                            @field(value, field.name) = try field.info.deserializeOne(reader, allocator);
                        },
                        .Many => {
                            if (allocator) |alloc| {
                                var alloc_count = try reader.readIntLittle(u16);

                                var buffer = try alloc.alloc(field.info.getSimpleType(), alloc_count);
                                @field(value, field.name) = buffer;
                                for (buffer) |*item| {
                                    item.* = try field.info.deserializeOne(reader, allocator);
                                }
                            } else {
                                return error.MissingAlloc;
                            }
                        },
                    }
                }
            }

            pub fn convert(prev: PreviousVersionType.Struct, ours: *VersionType) void {
                main: inline for (PreviousVersionType.version_fields) |field| {
                    // Only copy if field was not removed by next version
                    inline for (version) |record| {
                        switch (record) {
                            .Delete => |del| {
                                if (comptime std.mem.eql(u8, del.name, field.name)) {
                                    continue :main;
                                }
                            },
                            else => {},
                        }
                    }

                    @field(ours, field.name) = @field(prev, field.name);
                }

                if (finalConvert) |f| {
                    f(prev, &ours);
                }
            }
        };
    }

    const versions: [versionTypes.len]type = versionTypes;
    const CurrentVersion: type = versionTypes[versionTypes.len - 1];

    return struct {
        pub const Struct = CurrentVersion.Struct;

        pub fn serialize(value: Struct, writer: anytype) !void {
            try writer.writeIntLittle(u16, versionTypes.len - 1);
            try writer.writeIntLittle(u32, CurrentVersion.hash);

            inline for (CurrentVersion.version_fields) |field| {
                switch (field.info.size) {
                    .One => try field.info.serializeOne(@field(value, field.name), writer),
                    .Many => {
                        if (std.math.cast(u16, @field(value, field.name).len)) |len| {
                            try writer.writeIntLittle(u16, len);
                            for (@field(value, field.name)) |item| {
                                try field.info.serializeOne(item, writer);
                            }
                        } else {
                            return error.SliceTooBig;
                        }
                    },
                }
            }
        }

        pub fn deserialize(reader: anytype, allocator: ?std.mem.Allocator) !Struct {
            const version_id: usize = @intCast(try reader.readIntLittle(u16));
            if (version_id > versions.len)
                return error.UnknownVersion;

            return deserializeVersionRec(0, version_id, reader, null, allocator);
        }

        inline fn deserializeVersionRec(comptime current_version: usize, start_version: usize, reader: anytype, value: ?versions[current_version].Struct, allocator: ?std.mem.Allocator) !Struct {
            var val = value;
            const ThisVersion = versions[current_version];
            if (current_version == start_version) {
                var hash = try reader.readIntLittle(u32);
                if (hash != ThisVersion.hash)
                    return error.WrongVersionHash;

                val = .{};
                try ThisVersion.deserialize(&val.?, reader, allocator);
            }

            if (current_version < versions.len - 1) {
                const NextVer = versions[current_version + 1];

                var next_val: ?NextVer.Struct = null;
                if (val) |val_not_null| {
                    next_val = NextVer.Struct{};
                    NextVer.convert(val_not_null, &next_val.?);
                }

                return try deserializeVersionRec(current_version + 1, start_version, reader, next_val, allocator);
            } else {
                return val.?;
            }
        }
    };
}

// Generic struct with slice dealocator
pub fn deinit(value: anytype, allocator: std.mem.Allocator) void {
    const T = @TypeOf(value);
    const info = @typeInfo(T);

    switch (info) {
        .Struct => |str| {
            inline for (str.fields) |field| {
                deinit(@field(value, field.name), allocator);
            }
        },
        .Pointer => |ptr| {
            if (ptr.size != .Slice)
                @compileError("Struct has non slice pointers");
            allocator.free(value);
        },
        .Array => {
            for (value) |child| {
                deinit(child, allocator);
            }
        },
        else => {},
    }
}

// Implementation details

const SerFieldInfo = struct {
    name: []const u8,
    info: Record.Info,
};

fn getVersionHash(comptime field_infos: []const SerFieldInfo) u32 {
    var hash = std.hash.XxHash32.init(108501602);
    for (field_infos) |field| {
        hash.update(field.name);
        if (field.info.type == .type) {
            hash.update(@typeName(field.info.type.type));
            switch (@typeInfo(field.info.type.type)) {
                .Struct => |S| {
                    for (S.fields) |struct_field| {
                        hash.update(struct_field.name);
                        hash.update(@typeName(struct_field.type));
                    }
                },
                else => {},
            }
        }
    }
    return hash.final();
}

fn writeValue(value: anytype, writer: anytype) !void {
    const T = @TypeOf(value);
    const info = @typeInfo(T);
    switch (info) {
        .Int => try writer.writeIntLittle(T, value),
        .Array => {
            for (value) |v| {
                try writeValue(v, writer);
            }
        },
        .Struct => |s| {
            comptime if (s.layout != .Packed) @compileError("Struct must be packed, for more general structs see addSer()");
            try writer.writeIntLittle(s.backing_integer.?, @bitCast(value));
        },
        else => @compileError("Can't serialize " ++ @typeName(T)),
    }
}

fn readValue(comptime T: type, reader: anytype) !T {
    const info = @typeInfo(T);
    switch (info) {
        .Int => return try reader.readIntLittle(T),
        .Array => |array| {
            var values: T = undefined;
            for (&values) |*v| {
                v.* = try readValue(array.child, reader);
            }
            return values;
        },
        .Struct => |s| {
            comptime if (s.layout != .Packed) @compileError("Struct must be packed, for more general structs see addSer()");
            return @bitCast(try reader.readIntLittle(s.backing_integer.?));
        },
        else => @compileError("Can't unserialize " ++ @typeName(T)),
    }
}

test {
    const R = Record;

    const TestStruct = packed struct {
        x: u16 = 0,
        y: u16 = 42,
        z: u16 = 0,
    };

    const child: Definition = &.{&.{
        R.add("foo", u8, 99),
        R.add("bar", u8, 10),
    }};

    const ser: Definition = &.{
        // V0
        &.{
            R.add("attack", u8, 42),
        },
        // V1
        &.{
            R.add("decay", u8, 0),
            R.add("sustain", u8, 0),
            R.add("array", [8]u8, [_]u8{69} ** 8), // TODO : Support static arrays
            R.add("vector", TestStruct, TestStruct{}),
            R.addSerMany("foobar", child),
        },
        // V2
        &.{
            R.del("decay"),
            R.addMany("name", u8, "frodo baggins"),
            // R.del("decay"), // this should not compile
            // R.add("attack", u16, 99), // this also should not compile
        },
    };

    const T = Serializable(ser);
    const Foobar = Serializable(child);

    {
        var t: T.Struct = .{};

        try std.testing.expectEqual(@as(u8, 42), t.attack);
        try std.testing.expectEqual(@as(u16, 42), t.vector.y);

        t.attack = 123;
        t.foobar = try std.testing.allocator.alloc(Foobar.Struct, 6);
        defer std.testing.allocator.free(t.foobar);
        for (t.foobar, 0..) |*foobar, i| {
            foobar.* = .{
                .bar = @intCast(i * 2),
            };
        }

        try std.testing.expectEqual(@as(u8, 99), t.foobar[5].foo);
        try std.testing.expectEqual(@as(u8, 10), t.foobar[5].bar);

        var buffer: [128]u8 = undefined;
        var writerBuff = std.io.fixedBufferStream(&buffer);
        try T.serialize(t, writerBuff.writer());

        var readerBuff = std.io.fixedBufferStream(&buffer);
        var unser = try T.deserialize(readerBuff.reader(), std.testing.allocator);
        defer deinit(unser, std.testing.allocator);

        try std.testing.expectEqualDeep(t, unser);
        try std.testing.expectEqualSlices(u8, unser.name, "frodo baggins");
    }

    {
        const ser2: Definition = &.{
            // V0
            &.{
                R.add("attack", u8, 42),
            },
        };
        const T2 = Serializable(ser2);
        // upgrade
        var v0: T2.Struct = .{};
        v0.attack = 123;

        var buffer: [128]u8 = undefined;
        var writerBuff = std.io.fixedBufferStream(&buffer);
        try T2.serialize(v0, writerBuff.writer());

        var expected: T.Struct = .{};
        expected.attack = 123;

        var readerBuff = std.io.fixedBufferStream(&buffer);
        var unser = try T.deserialize(readerBuff.reader(), std.testing.allocator);

        try std.testing.expectEqualDeep(expected, unser);
    }
}
