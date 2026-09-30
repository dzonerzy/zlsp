//! An open document: its text, where its lines start, and the conversion
//! between byte offsets (what zgram and zrules use) and LSP positions
//! (line, character), whose characters are UTF-16 code units unless the
//! client agreed to UTF-8.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// What LSP positions count characters in
pub const Encoding = enum { utf8, utf16 };

pub const Position = struct { line: u32, character: u32 };

pub const Document = struct {
    gpa: Allocator,
    text: std.ArrayList(u8) = .empty,
    /// Byte offset where each line starts (line 0 at 0). A line ends at
    /// `\n`, `\r\n` or a lone `\r`, as LSP says.
    lines: std.ArrayList(u32) = .empty,
    version: i64 = 0,

    pub fn init(gpa: Allocator, text: []const u8, version: i64) !Document {
        var doc = Document{ .gpa = gpa, .version = version };
        errdefer doc.deinit();
        try doc.setText(text);
        return doc;
    }

    pub fn deinit(self: *Document) void {
        self.text.deinit(self.gpa);
        self.lines.deinit(self.gpa);
    }

    pub fn setText(self: *Document, text: []const u8) !void {
        self.text.clearRetainingCapacity();
        try self.text.appendSlice(self.gpa, text);
        try self.index();
    }

    fn index(self: *Document) !void {
        self.lines.clearRetainingCapacity();
        try self.lines.append(self.gpa, 0);
        const t = self.text.items;
        var i: usize = 0;
        while (i < t.len) : (i += 1) {
            switch (t[i]) {
                '\n' => try self.lines.append(self.gpa, @intCast(i + 1)),
                '\r' => {
                    if (i + 1 < t.len and t[i + 1] == '\n') i += 1;
                    try self.lines.append(self.gpa, @intCast(i + 1));
                },
                else => {},
            }
        }
    }

    /// Replace the text between two positions (an incremental change).
    pub fn edit(self: *Document, start: Position, end: Position, new_text: []const u8, enc: Encoding) !void {
        const a = self.offsetOf(start, enc);
        const b = @max(a, self.offsetOf(end, enc));
        try self.text.replaceRange(self.gpa, a, b - a, new_text);
        try self.index();
    }

    /// Where line `line` ends: before its line break (the end of the text
    /// for the last line).
    fn lineEnd(self: *const Document, line: usize) u32 {
        const t = self.text.items;
        if (line + 1 >= self.lines.items.len) return @intCast(t.len);
        var end = self.lines.items[line + 1];
        if (end > 0 and t[end - 1] == '\n') end -= 1;
        if (end > self.lines.items[line] and t[end - 1] == '\r') end -= 1;
        return end;
    }

    /// The byte offset of a position. A line past the end is the end of the
    /// text; a character past the end of its line is the end of the line;
    /// one inside a character is that character's start.
    pub fn offsetOf(self: *const Document, pos: Position, enc: Encoding) u32 {
        if (pos.line >= self.lines.items.len) return @intCast(self.text.items.len);
        const start = self.lines.items[pos.line];
        const end = self.lineEnd(pos.line);
        const line = self.text.items[start..end];
        return start + switch (enc) {
            .utf8 => @min(pos.character, @as(u32, @intCast(line.len))),
            .utf16 => utf16ToByte(line, pos.character),
        };
    }

    /// The position of a byte offset (clamped to the text).
    pub fn positionOf(self: *const Document, offset: u32, enc: Encoding) Position {
        const off = @min(offset, @as(u32, @intCast(self.text.items.len)));
        // The last line starting at or before it
        const lines = self.lines.items;
        var lo: usize = 0;
        var hi: usize = lines.len;
        while (hi - lo > 1) {
            const mid = (lo + hi) / 2;
            if (lines[mid] <= off) lo = mid else hi = mid;
        }
        const start = lines[lo];
        // (an offset inside a line break is the end of the line)
        const in_line = @min(off, self.lineEnd(lo)) - start;
        return .{
            .line = @intCast(lo),
            .character = switch (enc) {
                .utf8 => in_line,
                .utf16 => byteToUtf16(self.text.items[start .. start + in_line]),
            },
        };
    }
};

/// Bytes of `line` up to UTF-16 unit `units` (stopping at the character that
/// would pass it).
fn utf16ToByte(line: []const u8, units: u32) u32 {
    var i: usize = 0;
    var u: u32 = 0;
    while (i < line.len and u < units) {
        const n = seqLen(line, i);
        const w: u32 = if (n == 4) 2 else 1;
        if (u + w > units) break;
        u += w;
        i += n;
    }
    return @intCast(i);
}

/// UTF-16 units in `bytes`.
pub fn byteToUtf16(bytes: []const u8) u32 {
    var i: usize = 0;
    var u: u32 = 0;
    while (i < bytes.len) {
        const n = seqLen(bytes, i);
        u += if (n == 4) 2 else 1;
        i += n;
    }
    return u;
}

/// Length of the UTF-8 sequence at `i` (1 for an invalid byte: each counts
/// as one character, as a client decoding with replacement sees it).
fn seqLen(s: []const u8, i: usize) usize {
    const n = std.unicode.utf8ByteSequenceLength(s[i]) catch return 1;
    if (i + n > s.len) return 1;
    for (s[i + 1 .. i + n]) |c| {
        if (c & 0xC0 != 0x80) return 1;
    }
    return n;
}

test "lines and positions" {
    var d = try Document.init(std.testing.allocator, "ab\ncd\r\nef\rg", 1);
    defer d.deinit();
    try std.testing.expectEqualSlices(u32, &.{ 0, 3, 7, 10 }, d.lines.items);
    try std.testing.expectEqual(@as(u32, 4), d.offsetOf(.{ .line = 1, .character = 1 }, .utf16));
    try std.testing.expectEqual(@as(u32, 5), d.offsetOf(.{ .line = 1, .character = 9 }, .utf16));
    try std.testing.expectEqual(@as(u32, 11), d.offsetOf(.{ .line = 9, .character = 0 }, .utf16));
    try std.testing.expectEqual(Position{ .line = 2, .character = 1 }, d.positionOf(8, .utf16));
    // inside \r\n: the end of the line
    try std.testing.expectEqual(Position{ .line = 1, .character = 2 }, d.positionOf(6, .utf16));
}

test "utf-16 units" {
    // é: 2 bytes, 1 unit; 😀: 4 bytes, 2 units
    var d = try Document.init(std.testing.allocator, "aé😀b", 1);
    defer d.deinit();
    try std.testing.expectEqual(@as(u32, 3), d.offsetOf(.{ .line = 0, .character = 2 }, .utf16));
    try std.testing.expectEqual(@as(u32, 7), d.offsetOf(.{ .line = 0, .character = 4 }, .utf16));
    // in the middle of the surrogate pair: before it
    try std.testing.expectEqual(@as(u32, 3), d.offsetOf(.{ .line = 0, .character = 3 }, .utf16));
    try std.testing.expectEqual(Position{ .line = 0, .character = 4 }, d.positionOf(7, .utf16));
    try std.testing.expectEqual(Position{ .line = 0, .character = 7 }, d.positionOf(7, .utf8));
}

test "edits" {
    var d = try Document.init(std.testing.allocator, "let a = 1;\nlet b = 2;\n", 1);
    defer d.deinit();
    try d.edit(.{ .line = 0, .character = 8 }, .{ .line = 1, .character = 8 }, "10;\nlet c = ", .utf16);
    try std.testing.expectEqualStrings("let a = 10;\nlet c = 2;\n", d.text.items);
    try std.testing.expectEqual(@as(usize, 3), d.lines.items.len);
    try d.edit(.{ .line = 2, .character = 0 }, .{ .line = 2, .character = 0 }, "x", .utf16);
    try std.testing.expectEqualStrings("let a = 10;\nlet c = 2;\nx", d.text.items);
}
