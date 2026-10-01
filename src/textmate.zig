//! A TextMate grammar for the language (VS Code's `contributes.grammars`):
//! its comments, strings, numbers and keywords. The highlighting an editor
//! shows before the server answers, and where semantic tokens are off; the
//! server's semantic tokens refine it.

const std = @import("std");
const Allocator = std.mem.Allocator;
const json = @import("json.zig");

pub const Language = struct {
    /// The language's name (`tiny`): the scopes end with it
    name: []const u8,
    /// `source.tiny` if empty
    scope: []const u8 = "",
    keywords: []const []const u8,
    /// Every literal of the grammar (the quotes a string can start with are
    /// among them)
    literals: []const []const u8,
    line_comments: []const []const u8,
    block_comments: []const [2][]const u8,
};

/// The grammar, as JSON (owned).
pub fn generate(gpa: Allocator, lang: Language) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var w = json.Writer.init(gpa);
    defer w.deinit();

    const scope = if (lang.scope.len != 0) lang.scope else try std.fmt.allocPrint(a, "source.{s}", .{lang.name});
    try w.beginObject();
    try w.fieldString("$schema", "https://raw.githubusercontent.com/martinring/tmlanguage/master/tmlanguage.json");
    try w.fieldString("name", lang.name);
    try w.fieldString("scopeName", scope);
    try w.key("patterns");
    try w.beginArray();
    for ([_][]const u8{ "comments", "strings", "numbers", "keywords" }) |name| {
        try w.beginObject();
        try w.fieldString("include", try std.fmt.allocPrint(a, "#{s}", .{name}));
        try w.endObject();
    }
    try w.endArray();

    try w.key("repository");
    try w.beginObject();

    try w.key("comments");
    try w.beginObject();
    try w.key("patterns");
    try w.beginArray();
    for (lang.block_comments) |pair| {
        try w.beginObject();
        try w.fieldString("name", try std.fmt.allocPrint(a, "comment.block.{s}", .{lang.name}));
        try w.fieldString("begin", try escape(a, pair[0]));
        try w.fieldString("end", try escape(a, pair[1]));
        try w.endObject();
    }
    for (lang.line_comments) |marker| {
        try w.beginObject();
        try w.fieldString("name", try std.fmt.allocPrint(a, "comment.line.{s}", .{lang.name}));
        try w.fieldString("match", try std.fmt.allocPrint(a, "{s}.*$", .{try escape(a, marker)}));
        try w.endObject();
    }
    try w.endArray();
    try w.endObject();

    // Strings: from each quote the grammar has as a literal to the next,
    // a backslash escaping
    try w.key("strings");
    try w.beginObject();
    try w.key("patterns");
    try w.beginArray();
    for ([_][]const u8{ "\"", "'", "`" }) |quote| {
        if (!has(lang.literals, quote)) continue;
        try w.beginObject();
        try w.fieldString("name", try std.fmt.allocPrint(a, "string.quoted.{s}.{s}", .{ if (quote[0] == '"') "double" else if (quote[0] == '\'') "single" else "other", lang.name }));
        try w.fieldString("begin", quote);
        try w.fieldString("end", quote);
        try w.key("patterns");
        try w.beginArray();
        try w.beginObject();
        try w.fieldString("name", try std.fmt.allocPrint(a, "constant.character.escape.{s}", .{lang.name}));
        try w.fieldString("match", "\\\\.");
        try w.endObject();
        try w.endArray();
        try w.endObject();
    }
    try w.endArray();
    try w.endObject();

    try w.key("numbers");
    try w.beginObject();
    try w.key("patterns");
    try w.beginArray();
    try w.beginObject();
    try w.fieldString("name", try std.fmt.allocPrint(a, "constant.numeric.{s}", .{lang.name}));
    try w.fieldString("match", "\\b(?:0[xX][0-9a-fA-F_]+|0[bB][01_]+|[0-9][0-9_]*(?:\\.[0-9_]+)?(?:[eE][+-]?[0-9_]+)?)\\b");
    try w.endObject();
    try w.endArray();
    try w.endObject();

    try w.key("keywords");
    try w.beginObject();
    try w.key("patterns");
    try w.beginArray();
    if (lang.keywords.len != 0) {
        // (the longest first: `elif` before `el`)
        const sorted = try a.dupe([]const u8, lang.keywords);
        std.sort.pdq([]const u8, sorted, {}, struct {
            fn lt(_: void, x: []const u8, y: []const u8) bool {
                return x.len > y.len;
            }
        }.lt);
        var re: std.ArrayList(u8) = .empty;
        try re.appendSlice(a, "\\b(?:");
        for (sorted, 0..) |k, i| {
            if (i > 0) try re.append(a, '|');
            try re.appendSlice(a, try escape(a, k));
        }
        try re.appendSlice(a, ")\\b");
        try w.beginObject();
        try w.fieldString("name", try std.fmt.allocPrint(a, "keyword.control.{s}", .{lang.name}));
        try w.fieldString("match", re.items);
        try w.endObject();
    }
    try w.endArray();
    try w.endObject();

    try w.endObject();
    try w.endObject();
    return w.toOwned();
}

fn has(list: []const []const u8, s: []const u8) bool {
    for (list) |x| {
        if (std.mem.eql(u8, x, s)) return true;
    }
    return false;
}

/// `s` as an Oniguruma regex matching it literally.
fn escape(a: Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (s) |c| {
        if (std.mem.indexOfScalar(u8, "\\^$.|?*+()[]{}/#-", c) != null) try out.append(a, '\\');
        try out.append(a, c);
    }
    return out.items;
}
