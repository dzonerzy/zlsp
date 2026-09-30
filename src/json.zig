//! Writing JSON: the messages the server sends, built directly into a byte
//! buffer (no intermediate tree). Reading is std.json's (dynamic Values).

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Appends JSON to `out`, placing the commas between members and items.
pub const Writer = struct {
    gpa: Allocator,
    out: std.ArrayList(u8) = .empty,
    /// Something was written at this level: the next value needs a comma
    comma: bool = false,

    pub fn init(gpa: Allocator) Writer {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Writer) void {
        self.out.deinit(self.gpa);
    }

    /// The JSON written so far, which the caller now owns.
    pub fn toOwned(self: *Writer) ![]u8 {
        return self.out.toOwnedSlice(self.gpa);
    }

    fn separate(self: *Writer) !void {
        if (self.comma) try self.out.append(self.gpa, ',');
    }

    pub fn beginObject(self: *Writer) !void {
        try self.separate();
        try self.out.append(self.gpa, '{');
        self.comma = false;
    }

    pub fn endObject(self: *Writer) !void {
        try self.out.append(self.gpa, '}');
        self.comma = true;
    }

    pub fn beginArray(self: *Writer) !void {
        try self.separate();
        try self.out.append(self.gpa, '[');
        self.comma = false;
    }

    pub fn endArray(self: *Writer) !void {
        try self.out.append(self.gpa, ']');
        self.comma = true;
    }

    /// An object member's name; its value comes next.
    pub fn key(self: *Writer, name: []const u8) !void {
        try self.separate();
        try self.writeString(name);
        try self.out.append(self.gpa, ':');
        self.comma = false;
    }

    pub fn string(self: *Writer, s: []const u8) !void {
        try self.separate();
        try self.writeString(s);
        self.comma = true;
    }

    pub fn int(self: *Writer, v: i64) !void {
        try self.separate();
        var buf: [24]u8 = undefined;
        try self.out.appendSlice(self.gpa, std.fmt.bufPrint(&buf, "{d}", .{v}) catch unreachable);
        self.comma = true;
    }

    pub fn boolean(self: *Writer, v: bool) !void {
        try self.separate();
        try self.out.appendSlice(self.gpa, if (v) "true" else "false");
        self.comma = true;
    }

    pub fn null_(self: *Writer) !void {
        try self.separate();
        try self.out.appendSlice(self.gpa, "null");
        self.comma = true;
    }

    /// A value that is already JSON (a request id, as the client sent it).
    pub fn raw(self: *Writer, json: []const u8) !void {
        try self.separate();
        try self.out.appendSlice(self.gpa, json);
        self.comma = true;
    }

    /// A member with a string / integer / boolean value.
    pub fn fieldString(self: *Writer, name: []const u8, v: []const u8) !void {
        try self.key(name);
        try self.string(v);
    }

    pub fn fieldInt(self: *Writer, name: []const u8, v: i64) !void {
        try self.key(name);
        try self.int(v);
    }

    pub fn fieldBool(self: *Writer, name: []const u8, v: bool) !void {
        try self.key(name);
        try self.boolean(v);
    }

    /// A JSON string: quotes, escapes, and invalid UTF-8 (a file read from
    /// disk may have some) replaced by U+FFFD, which a client can decode.
    fn writeString(self: *Writer, s: []const u8) !void {
        const out = &self.out;
        try out.ensureUnusedCapacity(self.gpa, s.len + 2);
        out.appendAssumeCapacity('"');
        var i: usize = 0;
        while (i < s.len) {
            const ch = s[i];
            if (ch < 0x80) {
                switch (ch) {
                    '"' => try out.appendSlice(self.gpa, "\\\""),
                    '\\' => try out.appendSlice(self.gpa, "\\\\"),
                    '\n' => try out.appendSlice(self.gpa, "\\n"),
                    '\r' => try out.appendSlice(self.gpa, "\\r"),
                    '\t' => try out.appendSlice(self.gpa, "\\t"),
                    else => if (ch < 0x20) {
                        const hex = "0123456789abcdef";
                        try out.appendSlice(self.gpa, &.{ '\\', 'u', '0', '0', hex[ch >> 4], hex[ch & 15] });
                    } else try out.append(self.gpa, ch),
                }
                i += 1;
                continue;
            }
            const n = std.unicode.utf8ByteSequenceLength(ch) catch 0;
            if (n == 0 or i + n > s.len or !std.unicode.utf8ValidateSlice(s[i .. i + n])) {
                try out.appendSlice(self.gpa, "\u{FFFD}");
                i += 1;
                continue;
            }
            try out.appendSlice(self.gpa, s[i .. i + n]);
            i += n;
        }
        try out.append(self.gpa, '"');
    }
};

// ============================================================================
// Reading: helpers over std.json's dynamic Value
// ============================================================================

pub const Value = std.json.Value;

/// The member `name` of an object value, or null (also when `v` isn't an object).
pub fn get(v: ?Value, name: []const u8) ?Value {
    const obj = switch (v orelse return null) {
        .object => |o| o,
        else => return null,
    };
    return obj.get(name);
}

pub fn getString(v: ?Value, name: []const u8) ?[]const u8 {
    return switch (get(v, name) orelse return null) {
        .string => |s| s,
        else => null,
    };
}

pub fn getInt(v: ?Value, name: []const u8) ?i64 {
    return switch (get(v, name) orelse return null) {
        .integer => |i| i,
        .float => |f| if (f >= -9.2e18 and f <= 9.2e18) @intFromFloat(f) else null,
        else => null,
    };
}

pub fn getBool(v: ?Value, name: []const u8) ?bool {
    return switch (get(v, name) orelse return null) {
        .bool => |b| b,
        else => null,
    };
}

pub fn getArray(v: ?Value, name: []const u8) ?[]const Value {
    return switch (get(v, name) orelse return null) {
        .array => |a| a.items,
        else => null,
    };
}

/// A path of members: `path(v, &.{"textDocument", "uri"})`.
pub fn path(v: ?Value, names: []const []const u8) ?Value {
    var cur = v;
    for (names) |name| cur = get(cur, name);
    return cur;
}

test "writer" {
    var w = Writer.init(std.testing.allocator);
    defer w.deinit();
    try w.beginObject();
    try w.fieldString("a", "x\"y\n\x01");
    try w.key("b");
    try w.beginArray();
    try w.int(-3);
    try w.boolean(true);
    try w.null_();
    try w.beginObject();
    try w.endObject();
    try w.endArray();
    try w.fieldInt("c", 7);
    try w.endObject();
    try std.testing.expectEqualStrings("{\"a\":\"x\\\"y\\n\\u0001\",\"b\":[-3,true,null,{}],\"c\":7}", w.out.items);
}

test "invalid UTF-8 is replaced" {
    var w = Writer.init(std.testing.allocator);
    defer w.deinit();
    try w.string("a\xffb\xc3\xa9");
    try std.testing.expectEqualStrings("\"a\u{FFFD}b\u{e9}\"", w.out.items);
}

test "reading" {
    const parsed = try std.json.parseFromSlice(Value, std.testing.allocator, "{\"a\":{\"b\":\"c\",\"n\":4},\"l\":[1,2]}", .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("c", getString(get(parsed.value, "a"), "b").?);
    try std.testing.expectEqual(@as(i64, 4), getInt(path(parsed.value, &.{"a"}), "n").?);
    try std.testing.expectEqual(@as(usize, 2), getArray(parsed.value, "l").?.len);
    try std.testing.expect(get(parsed.value, "zz") == null);
}
