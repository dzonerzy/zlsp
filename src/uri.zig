//! `file://` URIs and paths: percent-encoding, and Windows drive letters
//! (`file:///c%3A/dir/f.tiny` is `c:\dir\f.tiny` there, `/c:/dir/f.tiny`
//! read as a POSIX path).

const std = @import("std");
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");

/// The path of a `file:` URI, or null for another scheme.
pub fn toPath(gpa: Allocator, uri: []const u8) !?[]u8 {
    const prefix = "file://";
    if (uri.len < prefix.len or !std.ascii.eqlIgnoreCase(uri[0..prefix.len], prefix)) return null;
    var rest = uri[prefix.len..];
    // file://host/path: only an empty host or localhost is local
    if (!std.mem.startsWith(u8, rest, "/")) {
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
        if (!std.ascii.eqlIgnoreCase(rest[0..slash], "localhost")) return null;
        rest = rest[slash..];
    }
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    while (i < rest.len) : (i += 1) {
        if (rest[i] == '%' and i + 2 < rest.len) {
            if (std.fmt.parseInt(u8, rest[i + 1 .. i + 3], 16)) |b| {
                try out.append(gpa, b);
                i += 2;
                continue;
            } else |_| {}
        }
        try out.append(gpa, rest[i]);
    }
    if (builtin.os.tag == .windows) windowsPath(&out);
    return try out.toOwnedSlice(gpa);
}

/// `/c:/dir/f` -> `c:\dir\f`
fn windowsPath(out: *std.ArrayList(u8)) void {
    const p = out.items;
    if (p.len >= 3 and p[0] == '/' and std.ascii.isAlphabetic(p[1]) and p[2] == ':') {
        std.mem.copyForwards(u8, p[0 .. p.len - 1], p[1..]);
        out.shrinkRetainingCapacity(p.len - 1);
    }
    for (out.items) |*c| {
        if (c.* == '/') c.* = '\\';
    }
}

/// The `file:` URI of an absolute path.
pub fn fromPath(gpa: Allocator, path: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, "file://");
    const drive = path.len >= 2 and std.ascii.isAlphabetic(path[0]) and path[1] == ':';
    if (drive) try out.append(gpa, '/');
    const hex = "0123456789ABCDEF";
    for (path, 0..) |c, i| {
        const ch: u8 = if (c == '\\') '/' else c;
        const plain = std.ascii.isAlphanumeric(ch) or std.mem.indexOfScalar(u8, "/-._~!$&'()*+,;=@", ch) != null;
        // (a drive letter's colon stays: file:///c:/dir, as editors write it)
        if (plain or (drive and i == 1)) {
            try out.append(gpa, if (drive and i == 0) std.ascii.toLower(ch) else ch);
        } else {
            try out.appendSlice(gpa, &.{ '%', hex[ch >> 4], hex[ch & 15] });
        }
    }
    return out.toOwnedSlice(gpa);
}

/// The form of a URI files are identified by: a `file:` URI decoded and
/// encoded again (`%2E` is `.`, `C%3A` is `c:`), anything else as it is.
/// Clients spell the same file differently.
pub fn canonical(gpa: Allocator, uri: []const u8) ![]u8 {
    const p = (try toPath(gpa, uri)) orelse return gpa.dupe(u8, uri);
    defer gpa.free(p);
    return fromPath(gpa, p);
}

test "canonical URIs" {
    const gpa = std.testing.allocator;
    const a = try canonical(gpa, "file:///tmp/dir/main%2Ety");
    defer gpa.free(a);
    try std.testing.expectEqualStrings("file:///tmp/dir/main.ty", a);
    const b = try canonical(gpa, "untitled:Untitled-1");
    defer gpa.free(b);
    try std.testing.expectEqualStrings("untitled:Untitled-1", b);
    if (builtin.os.tag == .windows) {
        const c = try canonical(gpa, "file:///C%3A/dir/f.ty");
        defer gpa.free(c);
        try std.testing.expectEqualStrings("file:///c:/dir/f.ty", c);
    }
}

test "paths from URIs" {
    const gpa = std.testing.allocator;
    const p = (try toPath(gpa, "file:///home/me/a%20b/f.tiny")).?;
    defer gpa.free(p);
    if (builtin.os.tag != .windows) try std.testing.expectEqualStrings("/home/me/a b/f.tiny", p);
    try std.testing.expect(try toPath(gpa, "untitled:Untitled-1") == null);
    try std.testing.expect(try toPath(gpa, "file://server/share/f") == null);
    const l = (try toPath(gpa, "file://localhost/tmp/x")).?;
    defer gpa.free(l);
    if (builtin.os.tag != .windows) try std.testing.expectEqualStrings("/tmp/x", l);
}

test "URIs from paths" {
    const gpa = std.testing.allocator;
    const u = try fromPath(gpa, "/home/me/a b/f#1.tiny");
    defer gpa.free(u);
    try std.testing.expectEqualStrings("file:///home/me/a%20b/f%231.tiny", u);
    const w = try fromPath(gpa, "C:\\dir\\f.tiny");
    defer gpa.free(w);
    try std.testing.expectEqualStrings("file:///c:/dir/f.tiny", w);
}
