const std = @import("std");

/// Protobuf wire types. SCIP only uses VARINT (0) and LEN (2).
pub const WireType = enum(u3) {
    VARINT = 0,
    I64 = 1,
    LEN = 2,
    SGROUP = 3,
    EGROUP = 4,
    I32 = 5,
};

/// A decoded field tag: field number + wire type.
pub const Field = struct {
    number: u32,
    wire_type: WireType,
};

/// Streaming pull parser over a protobuf-encoded byte slice.
/// Zero-copy: string/bytes slices point into the source buffer.
pub const Decoder = struct {
    data: []const u8,
    pos: usize,

    pub fn init(data: []const u8) Decoder {
        return .{ .data = data, .pos = 0 };
    }

    pub fn hasMore(self: *const Decoder) bool {
        return self.pos < self.data.len;
    }

    /// Read a field tag (field number + wire type).
    pub fn readField(self: *Decoder) !Field {
        const tag = try self.readVarint();
        const wire_raw: u3 = @truncate(tag);
        const wire_type = std.meta.intToEnum(WireType, wire_raw) catch return error.InvalidWireType;
        const number_raw = tag >> 3;
        if (number_raw == 0 or number_raw > 0x1FFFFFFF) return error.InvalidFieldNumber;
        return .{ .number = @intCast(number_raw), .wire_type = wire_type };
    }

    /// Read a varint (LEB128).
    pub fn readVarint(self: *Decoder) !u64 {
        var result: u64 = 0;
        var shift: u6 = 0;
        while (true) {
            if (self.pos >= self.data.len) return error.UnexpectedEndOfData;
            const byte = self.data[self.pos];
            self.pos += 1;
            if (shift == 63 and byte > 1) return error.VarintTooLong;
            result |= @as(u64, byte & 0x7F) << shift;
            if (byte & 0x80 == 0) return result;
            shift = std.math.add(u6, shift, 7) catch return error.VarintTooLong;
        }
    }

    /// Read a length-delimited field as a sub-slice (zero-copy).
    pub fn readLengthDelimited(self: *Decoder) ![]const u8 {
        const len = std.math.cast(usize, try self.readVarint()) orelse return error.LengthOverflow;
        const end = std.math.add(usize, self.pos, len) catch return error.LengthOverflow;
        if (end > self.data.len) return error.UnexpectedEndOfData;
        const result = self.data[self.pos..end];
        self.pos = end;
        return result;
    }

    /// Alias for readLengthDelimited — reads a string field.
    pub fn readString(self: *Decoder) ![]const u8 {
        return self.readLengthDelimited();
    }

    /// Read a packed repeated int32 field. Allocates the result array.
    pub fn readPackedInt32(self: *Decoder, allocator: std.mem.Allocator) ![]i32 {
        const bytes = try self.readLengthDelimited();
        var sub = Decoder.init(bytes);
        // First pass: count elements
        var count: usize = 0;
        while (sub.hasMore()) {
            _ = try sub.readVarint();
            count += 1;
        }
        // Second pass: decode
        const result = try allocator.alloc(i32, count);
        errdefer allocator.free(result);
        sub = Decoder.init(bytes);
        for (result) |*slot| {
            const v = try sub.readVarint();
            slot.* = @bitCast(@as(u32, @truncate(v)));
        }
        return result;
    }

    /// Skip over a field value based on its wire type.
    pub fn skipField(self: *Decoder, wire_type: WireType) !void {
        switch (wire_type) {
            .VARINT => {
                _ = try self.readVarint();
            },
            .I64 => try self.skipBytes(8),
            .LEN => {
                _ = try self.readLengthDelimited();
            },
            .I32 => try self.skipBytes(4),
            .SGROUP, .EGROUP => return error.UnsupportedWireType,
        }
    }

    fn skipBytes(self: *Decoder, len: usize) !void {
        const end = std.math.add(usize, self.pos, len) catch return error.LengthOverflow;
        if (end > self.data.len) return error.UnexpectedEndOfData;
        self.pos = end;
    }
};

/// Streaming protobuf encoder. Builds a byte buffer from field writes.
pub const Encoder = struct {
    data: std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Encoder {
        return .{ .data = .empty, .allocator = allocator };
    }

    pub fn deinit(self: *Encoder) void {
        self.data.deinit(self.allocator);
    }

    /// Write a varint (LEB128).
    pub fn writeVarint(self: *Encoder, value: u64) !void {
        var v = value;
        while (v > 0x7F) {
            try self.data.append(self.allocator, @truncate((v & 0x7F) | 0x80));
            v >>= 7;
        }
        try self.data.append(self.allocator, @truncate(v));
    }

    /// Write a field tag (field number + wire type).
    pub fn writeField(self: *Encoder, number: u32, wire_type: WireType) !void {
        if (number == 0 or number > 0x1FFFFFFF) return error.InvalidFieldNumber;
        const tag: u64 = (@as(u64, number) << 3) | @intFromEnum(wire_type);
        try self.writeVarint(tag);
    }

    /// Write a varint field (tag + value).
    pub fn writeVarintField(self: *Encoder, number: u32, value: u64) !void {
        if (value == 0) return; // skip default values
        try self.writeField(number, .VARINT);
        try self.writeVarint(value);
    }

    /// Write a string/bytes field (tag + length + data).
    pub fn writeString(self: *Encoder, number: u32, value: []const u8) !void {
        if (value.len == 0) return; // skip empty strings
        try self.writeField(number, .LEN);
        try self.writeVarint(@intCast(value.len));
        try self.data.appendSlice(self.allocator, value);
    }

    /// Write a length-delimited field (tag + length + raw bytes).
    pub fn writeLengthDelimited(self: *Encoder, number: u32, data_bytes: []const u8) !void {
        try self.writeField(number, .LEN);
        try self.writeVarint(@intCast(data_bytes.len));
        try self.data.appendSlice(self.allocator, data_bytes);
    }

    /// Write a packed repeated int32 field (tag + length + varint-encoded values).
    pub fn writePackedInt32(self: *Encoder, number: u32, values: []const i32) !void {
        if (values.len == 0) return;
        // First encode values to a temp buffer to get the length
        var tmp = Encoder.init(self.allocator);
        defer tmp.deinit();
        for (values) |v| {
            try tmp.writeVarint(@as(u64, @as(u32, @bitCast(v))));
        }
        const packed_data = tmp.data.items;
        try self.writeField(number, .LEN);
        try self.writeVarint(@intCast(packed_data.len));
        try self.data.appendSlice(self.allocator, packed_data);
    }

    /// Write a bool field as a varint (1 = true, skip if false).
    pub fn writeBool(self: *Encoder, number: u32, value: bool) !void {
        if (!value) return;
        try self.writeField(number, .VARINT);
        try self.writeVarint(1);
    }

    /// Return the encoded bytes. Caller owns the slice.
    pub fn toOwnedSlice(self: *Encoder) ![]const u8 {
        return try self.data.toOwnedSlice(self.allocator);
    }
};

// ── Tests ───────────────────────────────────────────────────────────────

test "readVarint single byte" {
    var d = Decoder.init(&.{0x08});
    const v = try d.readVarint();
    try std.testing.expectEqual(@as(u64, 8), v);
    try std.testing.expect(!d.hasMore());
}

test "readVarint multi byte" {
    // 300 = 0xAC 0x02
    var d = Decoder.init(&.{ 0xAC, 0x02 });
    const v = try d.readVarint();
    try std.testing.expectEqual(@as(u64, 300), v);
}

test "readVarint empty data" {
    var d = Decoder.init(&.{});
    const result = d.readVarint();
    try std.testing.expectError(error.UnexpectedEndOfData, result);
}

test "readVarint rejects overflow in tenth byte" {
    var d = Decoder.init(&.{ 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x02 });
    try std.testing.expectError(error.VarintTooLong, d.readVarint());
}

test "readField basic" {
    // field 1, wire type 0 (VARINT) => tag = (1 << 3) | 0 = 0x08
    var d = Decoder.init(&.{0x08});
    const f = try d.readField();
    try std.testing.expectEqual(@as(u32, 1), f.number);
    try std.testing.expectEqual(WireType.VARINT, f.wire_type);
}

test "readField LEN type" {
    // field 2, wire type 2 (LEN) => tag = (2 << 3) | 2 = 0x12
    var d = Decoder.init(&.{0x12});
    const f = try d.readField();
    try std.testing.expectEqual(@as(u32, 2), f.number);
    try std.testing.expectEqual(WireType.LEN, f.wire_type);
}

test "readField rejects oversized field number" {
    var d = Decoder.init(&.{ 0x80, 0x80, 0x80, 0x80, 0x80, 0x01 });
    try std.testing.expectError(error.InvalidFieldNumber, d.readField());
}

test "readField rejects reserved wire type" {
    var d = Decoder.init(&.{0x0E});
    try std.testing.expectError(error.InvalidWireType, d.readField());
}

test "readLengthDelimited" {
    // length=5, then 5 bytes of data
    var d = Decoder.init(&.{ 0x05, 'h', 'e', 'l', 'l', 'o' });
    const s = try d.readLengthDelimited();
    try std.testing.expectEqualStrings("hello", s);
    try std.testing.expect(!d.hasMore());
}

test "readLengthDelimited truncated" {
    // length=5 but only 3 bytes available
    var d = Decoder.init(&.{ 0x05, 'h', 'e', 'l' });
    const result = d.readLengthDelimited();
    try std.testing.expectError(error.UnexpectedEndOfData, result);
}

test "readLengthDelimited rejects lengths wider than usize" {
    if (@bitSizeOf(usize) >= @bitSizeOf(u64)) return error.SkipZigTest;

    var bytes: [11]u8 = undefined;
    bytes[0] = 0xFF;
    bytes[1] = 0xFF;
    bytes[2] = 0xFF;
    bytes[3] = 0xFF;
    bytes[4] = 0x1F;
    @memset(bytes[5..], 0);

    var d = Decoder.init(&bytes);
    try std.testing.expectError(error.LengthOverflow, d.readLengthDelimited());
}

test "readLengthDelimited rejects length addition overflow" {
    var bytes: [11]u8 = .{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x01, 0x00 };
    var d = Decoder.init(&bytes);
    try std.testing.expectError(error.LengthOverflow, d.readLengthDelimited());
}

test "readString alias" {
    var d = Decoder.init(&.{ 0x02, 'h', 'i' });
    const s = try d.readString();
    try std.testing.expectEqualStrings("hi", s);
}

test "readPackedInt32" {
    const allocator = std.testing.allocator;
    // packed int32: values 10, 20, 30
    // 10 = 0x0A, 20 = 0x14, 30 = 0x1E
    var d = Decoder.init(&.{ 0x03, 0x0A, 0x14, 0x1E });
    const values = try d.readPackedInt32(allocator);
    defer allocator.free(values);
    try std.testing.expectEqual(@as(usize, 3), values.len);
    try std.testing.expectEqual(@as(i32, 10), values[0]);
    try std.testing.expectEqual(@as(i32, 20), values[1]);
    try std.testing.expectEqual(@as(i32, 30), values[2]);
}

test "readPackedInt32 4 elements (occurrence range)" {
    const allocator = std.testing.allocator;
    // Simulating SCIP range: [5, 10, 7, 25]
    var d = Decoder.init(&.{ 0x04, 0x05, 0x0A, 0x07, 0x19 });
    const values = try d.readPackedInt32(allocator);
    defer allocator.free(values);
    try std.testing.expectEqual(@as(usize, 4), values.len);
    try std.testing.expectEqual(@as(i32, 5), values[0]);
    try std.testing.expectEqual(@as(i32, 10), values[1]);
    try std.testing.expectEqual(@as(i32, 7), values[2]);
    try std.testing.expectEqual(@as(i32, 25), values[3]);
}

test "skipField VARINT" {
    // field 1 VARINT with value 150 (0x96 0x01), then field 2 VARINT value 1
    var d = Decoder.init(&.{ 0x08, 0x96, 0x01, 0x10, 0x01 });
    const f1 = try d.readField();
    try std.testing.expectEqual(@as(u32, 1), f1.number);
    try d.skipField(f1.wire_type);
    const f2 = try d.readField();
    try std.testing.expectEqual(@as(u32, 2), f2.number);
    const v = try d.readVarint();
    try std.testing.expectEqual(@as(u64, 1), v);
}

test "skipField LEN" {
    // field 1 LEN "abc", then field 2 VARINT 42
    var d = Decoder.init(&.{ 0x0A, 0x03, 'a', 'b', 'c', 0x10, 0x2A });
    const f1 = try d.readField();
    try std.testing.expectEqual(@as(u32, 1), f1.number);
    try d.skipField(f1.wire_type);
    const f2 = try d.readField();
    try std.testing.expectEqual(@as(u32, 2), f2.number);
    const v = try d.readVarint();
    try std.testing.expectEqual(@as(u64, 42), v);
}

test "skipField fixed widths reject position overflow" {
    var d64 = Decoder{ .data = &.{}, .pos = std.math.maxInt(usize) - 3 };
    try std.testing.expectError(error.LengthOverflow, d64.skipField(.I64));

    var d32 = Decoder{ .data = &.{}, .pos = std.math.maxInt(usize) - 1 };
    try std.testing.expectError(error.LengthOverflow, d32.skipField(.I32));
}

test "nested message decoding" {
    // Simulate: outer message with field 1 = nested message containing field 1 = varint 42
    // Inner: field 1 VARINT 42 => 0x08 0x2A (2 bytes)
    // Outer: field 1 LEN length=2 inner => 0x0A 0x02 0x08 0x2A
    var d = Decoder.init(&.{ 0x0A, 0x02, 0x08, 0x2A });
    const f = try d.readField();
    try std.testing.expectEqual(@as(u32, 1), f.number);
    try std.testing.expectEqual(WireType.LEN, f.wire_type);
    const inner_bytes = try d.readLengthDelimited();
    try std.testing.expectEqual(@as(usize, 2), inner_bytes.len);

    var inner = Decoder.init(inner_bytes);
    const inner_f = try inner.readField();
    try std.testing.expectEqual(@as(u32, 1), inner_f.number);
    const val = try inner.readVarint();
    try std.testing.expectEqual(@as(u64, 42), val);
}

test "multiple fields in sequence" {
    // field 1 VARINT 1, field 2 LEN "hi", field 3 VARINT 99
    var d = Decoder.init(&.{ 0x08, 0x01, 0x12, 0x02, 'h', 'i', 0x18, 0x63 });
    // Field 1
    const f1 = try d.readField();
    try std.testing.expectEqual(@as(u32, 1), f1.number);
    const v1 = try d.readVarint();
    try std.testing.expectEqual(@as(u64, 1), v1);
    // Field 2
    const f2 = try d.readField();
    try std.testing.expectEqual(@as(u32, 2), f2.number);
    const s = try d.readString();
    try std.testing.expectEqualStrings("hi", s);
    // Field 3
    const f3 = try d.readField();
    try std.testing.expectEqual(@as(u32, 3), f3.number);
    const v3 = try d.readVarint();
    try std.testing.expectEqual(@as(u64, 99), v3);
}

// ── Encoder Tests ───────────────────────────────────────────────────────

test "Encoder writeVarint single byte" {
    const allocator = std.testing.allocator;
    var enc = Encoder.init(allocator);
    defer enc.deinit();
    try enc.writeVarint(8);
    try std.testing.expectEqualSlices(u8, &.{0x08}, enc.data.items);
}

test "Encoder writeVarint multi byte" {
    const allocator = std.testing.allocator;
    var enc = Encoder.init(allocator);
    defer enc.deinit();
    try enc.writeVarint(300);
    try std.testing.expectEqualSlices(u8, &.{ 0xAC, 0x02 }, enc.data.items);
}

test "Encoder writeField" {
    const allocator = std.testing.allocator;
    var enc = Encoder.init(allocator);
    defer enc.deinit();
    // field 2, LEN => (2 << 3) | 2 = 0x12
    try enc.writeField(2, .LEN);
    try std.testing.expectEqualSlices(u8, &.{0x12}, enc.data.items);
}

test "Encoder writeField rejects invalid field numbers" {
    const allocator = std.testing.allocator;
    var enc = Encoder.init(allocator);
    defer enc.deinit();

    try std.testing.expectError(error.InvalidFieldNumber, enc.writeField(0, .LEN));
    try std.testing.expectError(error.InvalidFieldNumber, enc.writeField(0x20000000, .LEN));
    try std.testing.expectEqual(@as(usize, 0), enc.data.items.len);
}

test "Encoder writeString" {
    const allocator = std.testing.allocator;
    var enc = Encoder.init(allocator);
    defer enc.deinit();
    // field 1, string "hi"
    try enc.writeString(1, "hi");
    try std.testing.expectEqualSlices(u8, &.{ 0x0A, 0x02, 'h', 'i' }, enc.data.items);
}

test "Encoder writeString empty is no-op" {
    const allocator = std.testing.allocator;
    var enc = Encoder.init(allocator);
    defer enc.deinit();
    try enc.writeString(1, "");
    try std.testing.expectEqual(@as(usize, 0), enc.data.items.len);
}

test "Encoder writePackedInt32" {
    const allocator = std.testing.allocator;
    var enc = Encoder.init(allocator);
    defer enc.deinit();
    // field 1, packed [10, 5, 15]
    try enc.writePackedInt32(1, &.{ 10, 5, 15 });
    try std.testing.expectEqualSlices(u8, &.{ 0x0A, 0x03, 0x0A, 0x05, 0x0F }, enc.data.items);
}

test "Encoder round-trip varint" {
    const allocator = std.testing.allocator;
    var enc = Encoder.init(allocator);
    defer enc.deinit();
    try enc.writeField(1, .VARINT);
    try enc.writeVarint(42);
    try enc.writeField(2, .VARINT);
    try enc.writeVarint(150);

    var dec = Decoder.init(enc.data.items);
    const f1 = try dec.readField();
    try std.testing.expectEqual(@as(u32, 1), f1.number);
    try std.testing.expectEqual(@as(u64, 42), try dec.readVarint());
    const f2 = try dec.readField();
    try std.testing.expectEqual(@as(u32, 2), f2.number);
    try std.testing.expectEqual(@as(u64, 150), try dec.readVarint());
    try std.testing.expect(!dec.hasMore());
}

test "Encoder round-trip string" {
    const allocator = std.testing.allocator;
    var enc = Encoder.init(allocator);
    defer enc.deinit();
    try enc.writeString(3, "hello world");

    var dec = Decoder.init(enc.data.items);
    const f = try dec.readField();
    try std.testing.expectEqual(@as(u32, 3), f.number);
    try std.testing.expectEqual(WireType.LEN, f.wire_type);
    try std.testing.expectEqualStrings("hello world", try dec.readString());
}

test "Encoder round-trip packed int32" {
    const allocator = std.testing.allocator;
    var enc = Encoder.init(allocator);
    defer enc.deinit();
    try enc.writePackedInt32(1, &.{ 5, 10, 7, 25 });

    var dec = Decoder.init(enc.data.items);
    const f = try dec.readField();
    try std.testing.expectEqual(@as(u32, 1), f.number);
    const values = try dec.readPackedInt32(allocator);
    defer allocator.free(values);
    try std.testing.expectEqual(@as(usize, 4), values.len);
    try std.testing.expectEqual(@as(i32, 5), values[0]);
    try std.testing.expectEqual(@as(i32, 10), values[1]);
    try std.testing.expectEqual(@as(i32, 7), values[2]);
    try std.testing.expectEqual(@as(i32, 25), values[3]);
}

test "Encoder round-trip multiple field types" {
    const allocator = std.testing.allocator;
    var enc = Encoder.init(allocator);
    defer enc.deinit();

    // field 1 VARINT 1, field 2 LEN "hi", field 3 VARINT 99
    try enc.writeVarintField(1, 1);
    try enc.writeString(2, "hi");
    try enc.writeVarintField(3, 99);

    var dec = Decoder.init(enc.data.items);
    const f1 = try dec.readField();
    try std.testing.expectEqual(@as(u32, 1), f1.number);
    try std.testing.expectEqual(@as(u64, 1), try dec.readVarint());
    const f2 = try dec.readField();
    try std.testing.expectEqual(@as(u32, 2), f2.number);
    try std.testing.expectEqualStrings("hi", try dec.readString());
    const f3 = try dec.readField();
    try std.testing.expectEqual(@as(u32, 3), f3.number);
    try std.testing.expectEqual(@as(u64, 99), try dec.readVarint());
}

test "Encoder writeBool" {
    const allocator = std.testing.allocator;
    var enc = Encoder.init(allocator);
    defer enc.deinit();
    try enc.writeBool(2, true);
    try enc.writeBool(3, false); // should be no-op

    var dec = Decoder.init(enc.data.items);
    const f = try dec.readField();
    try std.testing.expectEqual(@as(u32, 2), f.number);
    try std.testing.expectEqual(@as(u64, 1), try dec.readVarint());
    try std.testing.expect(!dec.hasMore());
}
