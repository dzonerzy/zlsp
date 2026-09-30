//! The LSP base protocol: each message is a JSON body after a header
//! (`Content-Length: N\r\n\r\n`). A Framer cuts a byte stream into bodies.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Largest message accepted (a document, sent whole, is inside one)
pub const MAX_MESSAGE = 256 * 1024 * 1024;

pub const Error = error{ BadHeader, MessageTooLarge, OutOfMemory };

pub const Framer = struct {
    gpa: Allocator,
    buf: std.ArrayList(u8) = .empty,
    /// Bytes of `buf` already handed out as messages
    consumed: usize = 0,

    pub fn init(gpa: Allocator) Framer {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Framer) void {
        self.buf.deinit(self.gpa);
    }

    /// Add bytes read from the stream.
    pub fn feed(self: *Framer, bytes: []const u8) !void {
        // Drop what was handed out before growing
        if (self.consumed > 0) {
            const rest = self.buf.items.len - self.consumed;
            std.mem.copyForwards(u8, self.buf.items[0..rest], self.buf.items[self.consumed..]);
            self.buf.shrinkRetainingCapacity(rest);
            self.consumed = 0;
        }
        try self.buf.appendSlice(self.gpa, bytes);
    }

    /// The next complete message's body, copied (the caller frees it with
    /// the framer's allocator); null until more bytes arrive.
    pub fn next(self: *Framer) Error!?[]u8 {
        const data = self.buf.items[self.consumed..];
        const header_end = std.mem.indexOf(u8, data, "\r\n\r\n") orelse {
            if (data.len > 64 * 1024) return error.BadHeader;
            return null;
        };
        var length: ?usize = null;
        var lines = std.mem.splitSequence(u8, data[0..header_end], "\r\n");
        while (lines.next()) |line| {
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.BadHeader;
            const name = std.mem.trim(u8, line[0..colon], " \t");
            if (!std.ascii.eqlIgnoreCase(name, "Content-Length")) continue;
            const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
            length = std.fmt.parseInt(usize, value, 10) catch return error.BadHeader;
        }
        const n = length orelse return error.BadHeader;
        if (n > MAX_MESSAGE) return error.MessageTooLarge;
        const body_start = header_end + 4;
        if (data.len < body_start + n) return null;
        const body = try self.gpa.dupe(u8, data[body_start .. body_start + n]);
        self.consumed += body_start + n;
        return body;
    }
};

/// The header that goes before a body of `len` bytes.
pub fn header(buf: *[64]u8, len: usize) []const u8 {
    return std.fmt.bufPrint(buf, "Content-Length: {d}\r\n\r\n", .{len}) catch unreachable;
}

test "framing" {
    const gpa = std.testing.allocator;
    var f = Framer.init(gpa);
    defer f.deinit();
    try f.feed("Content-Length: 7\r\nContent-Type: x\r\n\r\n{\"a\":1}Content-Len");
    const one = (try f.next()).?;
    defer gpa.free(one);
    try std.testing.expectEqualStrings("{\"a\":1}", one);
    try std.testing.expect(try f.next() == null);
    try f.feed("gth: 2\r\n\r\n{}");
    const two = (try f.next()).?;
    defer gpa.free(two);
    try std.testing.expectEqualStrings("{}", two);
    try std.testing.expect(try f.next() == null);
}

test "bad headers" {
    var f = Framer.init(std.testing.allocator);
    defer f.deinit();
    try f.feed("Nope\r\n\r\n");
    try std.testing.expectError(error.BadHeader, f.next());
}
