const std = @import("std");

// COMMON

pub const WireType = enum(usize) {
    varint_or_zigzag,
    fixed64bit,
    delimited,
    group_start,
    group_end,
    fixed32bit,
};

pub const SplitTag = struct { field: usize, wire_type: WireType };
fn splitTag(tag: usize) SplitTag {
    return .{ .field = tag >> 3, .wire_type = @enumFromInt(tag & 7) };
}

fn joinTag(split: SplitTag) usize {
    return (split.field << 3) | @intFromEnum(split.wire_type);
}

fn readTag(reader: anytype) !SplitTag {
    return splitTag(try std.leb.readUleb128(usize, reader));
}

fn writeTag(writer: anytype, split: SplitTag) !void {
    try std.leb.writeUleb128(writer, joinTag(split));
}

fn isArrayList(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasField(T, "items") and @hasField(T, "capacity");
}

// DECODE

pub fn decode(comptime T: type, allocator: std.mem.Allocator, reader: anytype) !T {
    var value: T = undefined;
    try decodeInternal(T, &value, allocator, reader, true);
    return value;
}

fn decodeMessageFields(comptime T: type, allocator: std.mem.Allocator, reader: anytype, length: usize) !T {
    var bytes_read: usize = 0;
    var value = if (@hasField(T, "items") and @hasField(T, "capacity")) .{} else std.mem.zeroInit(T, .{});

    while (length == 0 or bytes_read < length) {
        var tag_counter = ByteCounter(@TypeOf(reader)){ .inner = reader, .count = &bytes_read };
        const split = readTag(&tag_counter) catch |err| switch (err) {
            error.EndOfStream => return value,
            else => return err,
        };

        var matched = false;
        inline for (@field(T, "tags")) |rel| {
            if (split.field == rel[1]) {
                const expected_wt = typeToWireType(@TypeOf(@field(value, rel[0])));
                if (split.wire_type == expected_wt) {
                    var field_counter = ByteCounter(@TypeOf(reader)){ .inner = reader, .count = &bytes_read };
                    decodeInternal(@TypeOf(@field(value, rel[0])), &@field(value, rel[0]), allocator, &field_counter, false) catch |err| switch (err) {
                        error.EndOfStream => return value,
                        else => return err,
                    };
                    matched = true;
                }
            }
        }

        if (!matched) {
            // Skip unknown or wire-type-mismatched field
            var counter = ByteCounter(@TypeOf(reader)){ .inner = reader, .count = &bytes_read };
            switch (split.wire_type) {
                .varint_or_zigzag => {
                    _ = std.leb.readUleb128(u64, &counter) catch return value;
                },
                .delimited => {
                    const skip_len = std.leb.readUleb128(usize, &counter) catch return value;
                    var remaining = skip_len;
                    while (remaining > 0) {
                        _ = counter.readByte() catch return value;
                        remaining -= 1;
                    }
                },
                .fixed64bit => {
                    var i: usize = 0;
                    while (i < 8) : (i += 1) {
                        _ = counter.readByte() catch return value;
                    }
                },
                .fixed32bit => {
                    var i: usize = 0;
                    while (i < 4) : (i += 1) {
                        _ = counter.readByte() catch return value;
                    }
                },
                else => return value,
            }
        }
    }

    return value;
}

/// A simple wrapper that counts bytes read via readByte
fn ByteCounter(comptime ReaderType: type) type {
    return struct {
        inner: ReaderType,
        count: *usize,

        pub fn readByte(self: *@This()) !u8 {
            const b = try self.inner.readByte();
            self.count.* += 1;
            return b;
        }

        pub fn readAll(self: *@This(), buf: []u8) !usize {
            const n = try self.inner.readAll(buf);
            self.count.* += n;
            return n;
        }
    };
}

fn decodeInternal(
    comptime T: type,
    value: *T,
    allocator: std.mem.Allocator,
    reader: anytype,
    top: bool,
) !void {
    switch (@typeInfo(T)) {
        .@"struct" => {
            if (comptime isArrayList(T)) {
                const Child = @typeInfo(@field(T, "Slice")).pointer.child;
                const cti = @typeInfo(Child);

                if (cti == .int or cti == .@"enum") {
                    const limit = try std.leb.readUleb128(usize, reader);
                    var bytes_consumed: usize = 0;
                    while (bytes_consumed < limit) {
                        var counter = ByteCounter(@TypeOf(reader)){ .inner = reader, .count = &bytes_consumed };
                        try value.append(allocator, decode(Child, allocator, &counter) catch return);
                    }
                } else {
                    var new_elem: Child = undefined;
                    try decodeInternal(Child, &new_elem, allocator, reader, false);
                    try value.append(allocator, new_elem);
                }
            } else {
                const length = if (top) 0 else try std.leb.readUleb128(usize, reader);
                value.* = try decodeMessageFields(T, allocator, reader, length);
            }
        },
        .pointer => |ptr| {
            if (ptr.size == .slice) {
                const len = try std.leb.readUleb128(usize, reader);
                if (ptr.child == u8) {
                    const data = try allocator.alloc(u8, len);
                    _ = try reader.readAll(data);
                    value.* = data;
                } else if (@typeInfo(ptr.child) == .@"struct") {
                    @compileError("Use ArrayList for repeated message fields, not slices of: " ++ @typeName(T));
                } else {
                    @compileError("Slice decode not implemented for: " ++ @typeName(T));
                }
            } else if (ptr.size == .one) {
                // Single-item pointer: allocate and decode inner type
                const inner = try allocator.create(ptr.child);
                try decodeInternal(ptr.child, inner, allocator, reader, false);
                value.* = inner;
            } else {
                @compileError("Pointer decode not implemented for: " ++ @typeName(T));
            }
        },
        .@"enum" => |e| {
            const tag_info = @typeInfo(e.tag_type).int;
            const UnsignedTag = @Type(.{ .int = .{ .signedness = .unsigned, .bits = tag_info.bits } });
            const raw = try std.leb.readUleb128(UnsignedTag, reader);
            value.* = @enumFromInt(@as(e.tag_type, @bitCast(raw)));
        },
        .int => |i| value.* = switch (i.signedness) {
            // Protobuf int32/int64: read unsigned varint, bitcast to i64, truncate to target type
            .signed => @intCast(@as(i64, @bitCast(try std.leb.readUleb128(u64, reader)))),
            .unsigned => try std.leb.readUleb128(T, reader),
        },
        .bool => value.* = ((try std.leb.readUleb128(usize, reader)) != 0),
        .array => |arr| {
            const Child = arr.child;
            const cti = @typeInfo(Child);

            if (cti == .int or cti == .@"enum") {
                const limit = try std.leb.readUleb128(usize, reader);
                var array: [arr.len]Child = undefined;
                var index: usize = 0;
                var bytes_consumed: usize = 0;
                while (bytes_consumed < limit) : (index += 1) {
                    var counter = ByteCounter(@TypeOf(reader)){ .inner = reader, .count = &bytes_consumed };
                    const new_item = decode(Child, allocator, &counter) catch break;
                    if (index == array.len) return error.IndexOutOfRange;
                    array[index] = new_item;
                }
                if (index != array.len) return error.ArrayNotFilled;

                value.* = array;
            } else {
                @compileError("Array not of ints/enums not supported for decoding!");
            }
        },
        else => @compileError("Unsupported: " ++ @typeName(T)),
    }
}

// ENCODE

pub fn encode(value: anytype, writer: anytype) !void {
    try encodeInternal(value, writer, true);
}

fn typeToWireType(comptime T: type) WireType {
    if (@typeInfo(T) == .optional) return typeToWireType(@typeInfo(T).optional.child);
    if (@typeInfo(T) == .@"struct" or @typeInfo(T) == .pointer or @typeInfo(T) == .array) return .delimited;
    if (@typeInfo(T) == .int or @typeInfo(T) == .bool or @typeInfo(T) == .@"enum") return .varint_or_zigzag;
    @compileError("Wire type not handled: " ++ @typeName(T));
}

fn encodeMessageFields(value: anytype, writer: anytype) !void {
    const T = @TypeOf(value);
    inline for (@field(T, "tags")) |rel| {
        const subval = @field(value, rel[0]);
        const SubT = @TypeOf(subval);

        if (comptime @typeInfo(SubT) == .optional) {
            if (subval) |inner| {
                // Inline encoding for optional message fields to avoid
                // recursive error set resolution issues with encodeInternal
                try writeTag(writer, .{ .field = rel[1], .wire_type = .delimited });
                var discard_buf: [64]u8 = undefined;
                var discarding = std.Io.Writer.Discarding.init(&discard_buf);
                try encodeMessageFields(inner, &discarding.writer);
                try std.leb.writeUleb128(writer, discarding.fullCount());
                try encodeMessageFields(inner, writer);
            }
        } else if (comptime isArrayList(SubT) and !b: {
            const Child = @typeInfo(@field(SubT, "Slice")).pointer.child;
            const cti = @typeInfo(Child);
            break :b cti == .int or cti == .@"enum";
        }) {
            if (subval.items.len > 0) {
                for (subval.items) |item| {
                    try writeTag(writer, .{ .field = rel[1], .wire_type = typeToWireType(@TypeOf(item)) });
                    try encodeInternal(item, writer, false);
                }
            }
        } else {
            const skip = if (comptime isArrayList(SubT))
                subval.items.len == 0
            else if (comptime @typeInfo(SubT) == .int)
                subval == 0
            else if (comptime @typeInfo(SubT) == .bool)
                !subval
            else if (comptime @typeInfo(SubT) == .@"enum")
                @intFromEnum(subval) == 0
            else if (comptime @typeInfo(SubT) == .pointer and @typeInfo(SubT).pointer.size == .slice)
                subval.len == 0
            else
                false;
            if (!skip) {
                try writeTag(writer, .{ .field = rel[1], .wire_type = typeToWireType(SubT) });
                try encodeInternal(subval, writer, false);
            }
        }
    }
}

fn encodeInternal(
    value: anytype,
    writer: anytype,
    top: bool,
) !void {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .@"struct" => {
            if (comptime isArrayList(T)) {
                var discard_buf: [64]u8 = undefined;
                var discarding = std.Io.Writer.Discarding.init(&discard_buf);
                for (value.items) |item| try encodeInternal(item, &discarding.writer, false);
                try std.leb.writeUleb128(writer, discarding.fullCount());
                for (value.items) |item| try encodeInternal(item, writer, false);
            } else {
                if (!top) {
                    var discard_buf: [64]u8 = undefined;
                    var discarding = std.Io.Writer.Discarding.init(&discard_buf);
                    try encodeMessageFields(value, &discarding.writer);
                    try std.leb.writeUleb128(writer, discarding.fullCount());
                }
                try encodeMessageFields(value, writer);
            }
        },
        .pointer => |ptr| {
            if (ptr.size == .slice) {
                if (ptr.child == u8) {
                    try std.leb.writeUleb128(writer, value.len);
                    try writer.writeAll(value);
                } else if (@typeInfo(ptr.child) == .@"struct") {
                    @compileError("Use ArrayList for repeated message fields, not slices of: " ++ @typeName(T));
                } else {
                    @compileError("Slice encode not implemented for: " ++ @typeName(T));
                }
            } else if (ptr.size == .one) {
                try encodeInternal(value.*, writer, false);
            } else {
                @compileError("Pointer encode not implemented for: " ++ @typeName(T));
            }
        },
        .@"enum" => |e| {
            const tag_info = @typeInfo(e.tag_type).int;
            const UnsignedTag = @Type(.{ .int = .{ .signedness = .unsigned, .bits = tag_info.bits } });
            try std.leb.writeUleb128(writer, @as(UnsignedTag, @bitCast(@as(e.tag_type, @intFromEnum(value)))));
        },
        .int => |i| switch (i.signedness) {
            // Protobuf int32/int64: sign-extend to i64, bitcast to u64, encode as unsigned varint
            .signed => try std.leb.writeUleb128(writer, @as(u64, @bitCast(@as(i64, value)))),
            .unsigned => try std.leb.writeUleb128(writer, value),
        },
        .bool => try std.leb.writeUleb128(writer, @intFromBool(value)),
        .array => {
            var discard_buf: [64]u8 = undefined;
            var discarding = std.Io.Writer.Discarding.init(&discard_buf);
            for (value) |item| try encodeInternal(item, &discarding.writer, false);
            try std.leb.writeUleb128(writer, discarding.fullCount());
            for (value) |item| try encodeInternal(item, writer, false);
        },
        else => @compileError("Unsupported: " ++ @typeName(T)),
    }
}

// --- Tests ---

fn encodeToSlice(value: anytype, buf: []u8) ![]u8 {
    var fbs = std.io.fixedBufferStream(buf);
    try encode(value, fbs.writer());
    return fbs.getWritten();
}

const TestEnum = enum(u8) {
    foo = 0,
    bar = 1,
    baz = 2,
};

const SimpleMsg = struct {
    pub const tags = .{
        .{ "value", 1 },
        .{ "name", 2 },
        .{ "flag", 3 },
    };
    value: u32 = 0,
    name: []const u8 = "",
    flag: bool = false,
};

const EnumMsg = struct {
    pub const tags = .{
        .{ "kind", 1 },
        .{ "count", 2 },
    };
    kind: TestEnum,
    count: i32,
};

const NestedMsg = struct {
    pub const tags = .{
        .{ "inner", 1 },
    };
    inner: SimpleMsg,
};

const ListMsg = struct {
    pub const tags = .{
        .{ "items", 1 },
    };
    items: std.ArrayListUnmanaged(SimpleMsg),
};

const ArrayMsg = struct {
    pub const tags = .{
        .{ "values", 1 },
    };
    values: [3]u32,
};

test "encode/decode roundtrip: simple message" {
    const allocator = std.testing.allocator;
    const original = SimpleMsg{ .value = 42, .name = "hello", .flag = true };

    var buf: [256]u8 = undefined;
    const encoded = try encodeToSlice(original, &buf);

    var fbs = std.io.fixedBufferStream(encoded);
    const decoded = try decode(SimpleMsg, allocator, fbs.reader());

    try std.testing.expectEqual(@as(u32, 42), decoded.value);
    try std.testing.expectEqualStrings("hello", decoded.name);
    try std.testing.expectEqual(true, decoded.flag);

    allocator.free(decoded.name);
}

test "encode/decode roundtrip: non-usize enum" {
    const allocator = std.testing.allocator;
    const original = EnumMsg{ .kind = .baz, .count = -7 };

    var buf: [256]u8 = undefined;
    const encoded = try encodeToSlice(original, &buf);

    var fbs = std.io.fixedBufferStream(encoded);
    const decoded = try decode(EnumMsg, allocator, fbs.reader());

    try std.testing.expectEqual(TestEnum.baz, decoded.kind);
    try std.testing.expectEqual(@as(i32, -7), decoded.count);
}

test "encode/decode roundtrip: nested message" {
    const allocator = std.testing.allocator;
    const original = NestedMsg{
        .inner = .{ .value = 99, .name = "nested", .flag = false },
    };

    var buf: [256]u8 = undefined;
    const encoded = try encodeToSlice(original, &buf);

    var fbs = std.io.fixedBufferStream(encoded);
    const decoded = try decode(NestedMsg, allocator, fbs.reader());

    try std.testing.expectEqual(@as(u32, 99), decoded.inner.value);
    try std.testing.expectEqualStrings("nested", decoded.inner.name);
    try std.testing.expectEqual(false, decoded.inner.flag);

    allocator.free(decoded.inner.name);
}

test "encode/decode roundtrip: ArrayList of messages" {
    const allocator = std.testing.allocator;
    var items = std.ArrayListUnmanaged(SimpleMsg){};
    defer items.deinit(allocator);
    try items.append(allocator, .{ .value = 1, .name = "a", .flag = true });
    try items.append(allocator, .{ .value = 2, .name = "b", .flag = false });

    const original = ListMsg{ .items = items };

    var buf: [512]u8 = undefined;
    const encoded = try encodeToSlice(original, &buf);

    var fbs = std.io.fixedBufferStream(encoded);
    var decoded = try decode(ListMsg, allocator, fbs.reader());

    try std.testing.expectEqual(@as(usize, 2), decoded.items.items.len);
    try std.testing.expectEqual(@as(u32, 1), decoded.items.items[0].value);
    try std.testing.expectEqualStrings("a", decoded.items.items[0].name);
    try std.testing.expectEqual(true, decoded.items.items[0].flag);
    try std.testing.expectEqual(@as(u32, 2), decoded.items.items[1].value);
    try std.testing.expectEqualStrings("b", decoded.items.items[1].name);

    for (decoded.items.items) |item| allocator.free(item.name);
    decoded.items.deinit(allocator);
}

test "encode/decode roundtrip: fixed array" {
    const allocator = std.testing.allocator;
    const original = ArrayMsg{ .values = .{ 10, 20, 30 } };

    var buf: [256]u8 = undefined;
    const encoded = try encodeToSlice(original, &buf);

    var fbs = std.io.fixedBufferStream(encoded);
    const decoded = try decode(ArrayMsg, allocator, fbs.reader());

    try std.testing.expectEqual([3]u32{ 10, 20, 30 }, decoded.values);
}

test "decode skips unknown fields" {
    // Manually craft bytes: field 1 (varint) = 42, field 99 (varint) = 123, field 2 (delimited) = "hi", field 3 (varint) = 1
    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const w = fbs.writer();

    // field 1, wire=varint: value=42
    try std.leb.writeUleb128(w, joinTag(.{ .field = 1, .wire_type = .varint_or_zigzag }));
    try std.leb.writeUleb128(w, @as(u32, 42));

    // field 99, wire=varint: unknown field
    try std.leb.writeUleb128(w, joinTag(.{ .field = 99, .wire_type = .varint_or_zigzag }));
    try std.leb.writeUleb128(w, @as(u32, 123));

    // field 2, wire=delimited: "hi"
    try std.leb.writeUleb128(w, joinTag(.{ .field = 2, .wire_type = .delimited }));
    try std.leb.writeUleb128(w, @as(usize, 2));
    try w.writeAll("hi");

    // field 3, wire=varint: true
    try std.leb.writeUleb128(w, joinTag(.{ .field = 3, .wire_type = .varint_or_zigzag }));
    try std.leb.writeUleb128(w, @as(u32, 1));

    const encoded = fbs.getWritten();
    const allocator = std.testing.allocator;

    var reader = std.io.fixedBufferStream(encoded);
    const decoded = try decode(SimpleMsg, allocator, reader.reader());

    try std.testing.expectEqual(@as(u32, 42), decoded.value);
    try std.testing.expectEqualStrings("hi", decoded.name);
    try std.testing.expectEqual(true, decoded.flag);

    allocator.free(decoded.name);
}

test "wire type helpers" {
    try std.testing.expectEqual(WireType.varint_or_zigzag, typeToWireType(u32));
    try std.testing.expectEqual(WireType.varint_or_zigzag, typeToWireType(bool));
    try std.testing.expectEqual(WireType.varint_or_zigzag, typeToWireType(TestEnum));
    try std.testing.expectEqual(WireType.delimited, typeToWireType([]const u8));
    try std.testing.expectEqual(WireType.delimited, typeToWireType(SimpleMsg));

    // splitTag/joinTag roundtrip
    const split = SplitTag{ .field = 5, .wire_type = .delimited };
    try std.testing.expectEqual(split, splitTag(joinTag(split)));
}
