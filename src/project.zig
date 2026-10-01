//! The files of the workspace and what analysis found in them.
//!
//! Each file has its text (the open buffer, or the file on disk) and, once
//! analyzed, a native copy of what zgram and zrules found: the tree (read
//! through the `zgram.tree.v1` capsule), diagnostics, symbols, and the nodes
//! the configured selectors match. Features read only these. Parsing and
//! checking call zgram and zrules, and need the GIL.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ph = @import("pyhelp.zig");
const py = ph.py;
const PyObject = ph.PyObject;
const tree_mod = @import("tree.zig");
const document = @import("document.zig");
const lsp = @import("lsp.zig");
const zabi = @import("zrules_abi.zig");
const uri_mod = @import("uri.zig");

pub const NONE = tree_mod.NONE;

/// (the layout of zrules' spans: its uses are read in place)
pub const Span = extern struct {
    start: u32,
    end: u32,

    pub fn contains(self: Span, offset: u32) bool {
        return self.start <= offset and offset <= self.end;
    }
};

/// What the server was configured with (Server(...) in Python)
pub const Config = struct {
    parser: *PyObject,
    rules: ?*PyObject = null,
    resolve: ?*PyObject = null,
    name: []const u8 = "zlsp",
    version: []const u8 = "",
    /// File name extensions of the language (".tiny"): the workspace files
    extensions: []const []const u8 = &.{},
    symbol_rules: []const SymbolRule = &.{},
    token_rules: []const TokenRule = &.{},
    /// Selectors of foldable nodes; none: every multi-line node with children
    fold_rules: []const Selector = &.{},
    line_comments: []const []const u8 = &.{},
    block_comments: []const [2][]const u8 = &.{},
    /// The grammar's word literals (`let`, `if`)
    keywords: []const []const u8 = &.{},
    /// Python functions extending the features (see the Server's docs)
    hover_hook: ?*PyObject = null,
    completion_hook: ?*PyObject = null,
    code_action_hook: ?*PyObject = null,
    format_hook: ?*PyObject = null,
    configuration_hook: ?*PyObject = null,
};

/// A zrules Selector's native match function (its capsule, kept alive by
/// the Server)
pub const Selector = *const zabi.SelectorView;

pub const SymbolRule = struct { selector: Selector, kind: lsp.Kind };
pub const TokenRule = struct { selector: Selector, type: lsp.TokenType };

pub const Note = struct { span: Span, message: []const u8 };

pub const Diag = struct {
    span: Span,
    severity: i64,
    code: []const u8,
    message: []const u8,
    notes: []const Note = &.{},
};

pub const Sym = struct {
    name: []const u8,
    /// The defining node's span and index; null / NONE for a builtin
    def: ?Span,
    def_node: u32,
    kind: ?lsp.Kind,
    type_text: ?[]const u8,
    uses: []const Span,
    /// The scope node it is defined in, and the one it names; NONE if none
    scope: u32,
    owns: u32,
    builtin: bool,
    /// For an imported name: the key of the file defining it, and the node there
    origin_key: ?[]const u8 = null,
    origin_node: u32 = NONE,
};

/// A file's analysis, of one version of its text
pub const Analysis = struct {
    arena: std.heap.ArenaAllocator,
    /// The zgram Tree (its capsule and text stay valid while referenced) and
    /// the zrules Analysis, if checked
    tree: *PyObject,
    checked: ?*PyObject = null,
    nodes: []const tree_mod.FlatNode = &.{},
    parents: []const u32 = &.{},
    text: []const u8 = "",
    rule_names: []const []const u8 = &.{},
    diags: []const Diag = &.{},
    syms: []const Sym = &.{},
    /// Nodes matched by each token rule (same order as Config.token_rules)
    token_nodes: []const []const u32 = &.{},
    /// Nodes matched by the fold rules (null: none configured)
    fold_nodes: ?[]const u32 = null,
    /// The keys of the files it imports, from the check
    imports: []const []const u8 = &.{},
    /// The id of the grammar's `type` label (0: none): a definition with a
    /// child so labelled has its type written out
    type_field: u8 = 0,

    pub fn destroy(self: *Analysis, gpa: Allocator) void {
        if (self.checked) |c| py.Py_DecRef(c);
        py.Py_DecRef(self.tree);
        self.arena.deinit();
        gpa.destroy(self);
    }

    pub fn nodeSpan(self: *const Analysis, node: u32) Span {
        const n = self.nodes[node];
        return .{ .start = n.text_start, .end = n.text_end };
    }

    /// The symbol defined or used at `offset`, preferring a definition.
    pub fn symbolAt(self: *const Analysis, offset: u32) ?*const Sym {
        for (self.syms) |*s| {
            if (s.def) |d| if (d.contains(offset)) return s;
        }
        for (self.syms) |*s| {
            for (s.uses) |u| if (u.contains(offset)) return s;
        }
        return null;
    }
};

pub const File = struct {
    /// The URI it is sent as: the client's, if it opened the file
    uri: []u8,
    /// Its canonical URI (uri.canonical), what the project knows it by
    id: []u8,
    path: ?[]u8,
    /// The name other files import it by (its path under the root, without
    /// the extension), the key zrules knows it by
    key: []u8,
    doc: document.Document,
    /// Opened in the editor (its text is the buffer's, not the disk's)
    open: bool = false,
    /// Bumped on each change of the text
    text_gen: u64 = 1,
    /// The text_gen the tree was parsed from, and the analysis checked
    parsed_gen: u64 = 0,
    checked_gen: u64 = 0,
    tree: ?*PyObject = null,
    analysis: ?*Analysis = null,
    /// The diagnostics last published (JSON), to publish only changes
    published: ?[]u8 = null,
    /// The semantic tokens last sent, and their result id (for deltas)
    tokens: ?[]u32 = null,
    tokens_id: u64 = 0,

    pub fn destroy(self: *File, gpa: Allocator) void {
        if (self.analysis) |a| a.destroy(gpa);
        if (self.tree) |t| py.Py_DecRef(t);
        if (self.published) |p| gpa.free(p);
        if (self.tokens) |t| gpa.free(t);
        self.doc.deinit();
        gpa.free(self.uri);
        gpa.free(self.id);
        if (self.path) |p| gpa.free(p);
        gpa.free(self.key);
        gpa.destroy(self);
    }
};

pub const Project = struct {
    gpa: Allocator,
    config: *const Config,
    files: std.StringArrayHashMapUnmanaged(*File) = .empty,
    /// Bumped on any change; `analyzed` is the generation last analyzed
    generation: u64 = 1,
    analyzed: u64 = 0,
    /// Bumped when files come or go (the whole project is checked again);
    /// the value at the last check
    structure_gen: u64 = 1,
    checked_structure: u64 = 0,
    /// The last analysis failure (a Python exception in a custom rule),
    /// logged once per distinct message
    last_failure: ?[]u8 = null,

    pub fn deinit(self: *Project) void {
        for (self.files.values()) |f| f.destroy(self.gpa);
        self.files.deinit(self.gpa);
        if (self.last_failure) |m| self.gpa.free(m);
    }

    /// The file a URI names, however the client spells it.
    pub fn get(self: *Project, uri: []const u8) ?*File {
        const id = uri_mod.canonical(self.gpa, uri) catch return null;
        defer self.gpa.free(id);
        return self.files.get(id);
    }

    /// Add a file (or return it if known) with `text`.
    pub fn add(self: *Project, uri: []const u8, path: ?[]const u8, key: []const u8, text: []const u8) !*File {
        if (self.get(uri)) |f| return f;
        const f = try self.gpa.create(File);
        errdefer self.gpa.destroy(f);
        f.* = .{
            .uri = try self.gpa.dupe(u8, uri),
            .id = try uri_mod.canonical(self.gpa, uri),
            .path = if (path) |p| try self.gpa.dupe(u8, p) else null,
            .key = try self.gpa.dupe(u8, key),
            .doc = try document.Document.init(self.gpa, text, 0),
        };
        try self.files.put(self.gpa, f.id, f);
        self.generation += 1;
        self.structure_gen += 1;
        return f;
    }

    /// Send the file as `uri` from now on (the client's spelling).
    pub fn rename(self: *Project, f: *File, uri: []const u8) !void {
        if (std.mem.eql(u8, f.uri, uri)) return;
        const copy = try self.gpa.dupe(u8, uri);
        self.gpa.free(f.uri);
        f.uri = copy;
    }

    pub fn remove(self: *Project, uri: []const u8) void {
        const f = self.get(uri) orelse return;
        _ = self.files.orderedRemove(f.id);
        f.destroy(self.gpa);
        self.generation += 1;
        self.structure_gen += 1;
    }

    /// The text of `f` changed.
    pub fn touched(self: *Project, f: *File) void {
        f.text_gen += 1;
        self.generation += 1;
    }

    /// The file with a zrules key, if any.
    pub fn byKey(self: *Project, key: []const u8) ?*File {
        for (self.files.values()) |f| {
            if (std.mem.eql(u8, f.key, key)) return f;
        }
        return null;
    }

    pub const Outcome = enum { unchanged, analyzed, failed, interrupted };

    /// Asked between files while parsing: is new input waiting? (The
    /// analysis then stops; what it parsed is kept, the rest is done on the
    /// next call.)
    pub const Interrupt = struct {
        ctx: *anyopaque,
        pending: *const fn (ctx: *anyopaque) bool,
    };

    /// Bring every file's analysis up to date: parse what changed, and check
    /// what an edit can have changed: the edited files, the files that
    /// import them (directly or not), with the files those import. The rest
    /// keep their analyses. The whole project is checked on the first call,
    /// and when files come or go. On a Python failure (a custom rule
    /// raising), the files keep only their syntax errors and `failure` gets
    /// the message.
    pub fn analyze(self: *Project, failure: *[512]u8, failure_len: *usize, interrupt: ?Interrupt) !Outcome {
        if (self.analyzed == self.generation) return .unchanged;
        failure_len.* = 0;
        const files = self.files.values();
        for (files) |f| {
            if (f.parsed_gen == f.text_gen and f.tree != null) continue;
            if (interrupt) |i| {
                if (i.pending(i.ctx)) return .interrupted;
            }
            const tree = parseText(self.config.parser, f.doc.text.items) orelse {
                failure_len.* = ph.takeError(failure).len;
                continue;
            };
            if (f.tree) |old| py.Py_DecRef(old);
            f.tree = tree;
            f.parsed_gen = f.text_gen;
        }

        // What to check
        const in_set = try self.gpa.alloc(bool, files.len);
        defer self.gpa.free(in_set);
        @memset(in_set, false);
        var full = self.checked_structure != self.structure_gen;
        for (files, in_set) |f, *slot| {
            if (f.analysis == null) full = true;
            slot.* = f.checked_gen != f.text_gen;
        }
        if (full) @memset(in_set, true) else if (self.config.rules != null) {
            // The files importing an edited one, and theirs...
            var grew = true;
            while (grew) {
                grew = false;
                for (files, in_set) |f, *slot| {
                    if (slot.*) continue;
                    for (f.analysis.?.imports) |key| {
                        const i = self.indexOfKey(key) orelse continue;
                        if (!in_set[i]) continue;
                        slot.* = true;
                        grew = true;
                        break;
                    }
                }
            }
        }

        if (self.config.rules) |rules| {
            // ... checked with the files they import (to resolve them)
            const needed = try self.gpa.alloc(bool, files.len);
            defer self.gpa.free(needed);
            @memcpy(needed, in_set);
            if (!full) _ = self.addImported(needed);
            // A file's new imports are known once it is checked: if they
            // reach outside the set, check again with them
            var round: usize = 0;
            while (true) : (round += 1) {
                const project_obj = self.check(rules, needed) orelse {
                    failure_len.* = ph.takeError(failure).len;
                    try self.extractAll(needed, null, failure, failure_len);
                    break;
                };
                defer py.Py_DecRef(project_obj);
                try self.extractAll(needed, project_obj, failure, failure_len);
                if (full or round >= 8 or !self.addImported(needed)) break;
            }
        } else try self.extractAll(in_set, null, failure, failure_len);

        for (files) |f| f.checked_gen = f.text_gen;
        self.checked_structure = self.structure_gen;
        self.analyzed = self.generation;
        return if (failure_len.* != 0) .failed else .analyzed;
    }

    fn indexOfKey(self: *Project, key: []const u8) ?usize {
        for (self.files.values(), 0..) |f, i| {
            if (std.mem.eql(u8, f.key, key)) return i;
        }
        return null;
    }

    /// Add to `set` the files its files import, until nothing more is
    /// reachable; whether anything was added.
    fn addImported(self: *Project, set: []bool) bool {
        const files = self.files.values();
        var added = false;
        var grew = true;
        while (grew) {
            grew = false;
            for (files, 0..) |f, i| {
                if (!set[i]) continue;
                const a = f.analysis orelse continue;
                for (a.imports) |key| {
                    const j = self.indexOfKey(key) orelse continue;
                    if (set[j]) continue;
                    set[j] = true;
                    grew = true;
                    added = true;
                }
            }
        }
        return added;
    }

    /// New analyses for the files of `set`, from the project's check (or
    /// their syntax errors only, with `project_obj` null).
    fn extractAll(self: *Project, set: []const bool, project_obj: ?*PyObject, failure: *[512]u8, failure_len: *usize) !void {
        for (self.files.values(), set) |f, wanted| {
            if (!wanted) continue;
            const tree = f.tree orelse continue;
            var checked: ?*PyObject = null;
            if (project_obj) |p| {
                const key = ph.newString(f.key) orelse return error.OutOfMemory;
                defer py.Py_DecRef(key);
                checked = py.c.PyObject_CallMethod(p, "file", "O", key);
                if (checked == null) py.c.PyErr_Clear();
            }
            const a = self.extract(tree, checked) catch |e| switch (e) {
                error.Python => {
                    failure_len.* = ph.takeError(failure).len;
                    continue;
                },
                else => return e,
            };
            if (f.analysis) |old| old.destroy(self.gpa);
            f.analysis = a;
        }
    }

    /// rules.analyze_project({key: tree} for the files of `set`, resolve=...)
    /// (a new reference), or null with the Python error set.
    fn check(self: *Project, rules: *PyObject, set: []const bool) ?*PyObject {
        const files = py.c.PyDict_New() orelse return null;
        defer py.Py_DecRef(files);
        for (self.files.values(), set) |f, wanted| {
            if (!wanted) continue;
            const tree = f.tree orelse continue;
            const key = ph.newString(f.key) orelse return null;
            defer py.Py_DecRef(key);
            if (py.c.PyDict_SetItem(files, key, tree) != 0) return null;
        }
        const method = ph.attr(rules, "analyze_project") orelse return null;
        defer py.Py_DecRef(method);
        const args = py.c.PyTuple_Pack(1, files) orelse return null;
        defer py.Py_DecRef(args);
        const kwargs = py.c.PyDict_New() orelse return null;
        defer py.Py_DecRef(kwargs);
        if (self.config.resolve) |r| {
            if (py.c.PyDict_SetItemString(kwargs, "resolve", r) != 0) return null;
        }
        return py.c.PyObject_Call(method, args, kwargs);
    }

    /// The native copy of a tree's analysis. `checked` (the zrules Analysis,
    /// consumed) may be null: then only the syntax errors.
    fn extract(self: *Project, tree: *PyObject, checked_arg: ?*PyObject) error{ Python, OutOfMemory }!*Analysis {
        var checked = checked_arg;
        errdefer if (checked) |c| py.Py_DecRef(c);
        const a = try self.gpa.create(Analysis);
        a.* = .{ .arena = std.heap.ArenaAllocator.init(self.gpa), .tree = tree };
        py.Py_IncRef(tree);
        a.checked = checked;
        checked = null;
        errdefer a.destroy(self.gpa);
        const arena = a.arena.allocator();

        // The tree, in place
        const capsule = ph.attr(tree, "capsule") orelse return error.Python;
        defer py.Py_DecRef(capsule);
        const view: *const tree_mod.TreeView = @ptrCast(@alignCast(py.c.PyCapsule_GetPointer(capsule, tree_mod.CAPSULE_NAME) orelse return error.Python));
        if (view.abi != tree_mod.TREE_ABI) {
            ph.raise(py.PyExc_RuntimeError(), "zlsp reads zgram trees with TREE_ABI {d}, but the tree has {d}: upgrade zlsp or zgram", .{ tree_mod.TREE_ABI, view.abi });
            return error.Python;
        }
        a.nodes = if (view.nodes) |n| n[0..view.node_count] else &.{};
        a.text = if (view.input) |p| p[0..view.input_len] else "";
        a.parents = try tree_mod.Tree.computeParents(arena, a.nodes);
        const names = try arena.alloc([]const u8, view.rule_count);
        for (names, 0..) |*slot, i| slot.* = view.rule_names.?[i].slice();
        a.rule_names = names;
        for (0..view.field_count) |i| {
            if (std.mem.eql(u8, view.field_names.?[i].slice(), "type")) a.type_field = @intCast(i + 1);
        }

        // Diagnostics: the checker's (syntax errors included), or the tree's
        const diag_list = if (a.checked) |c| ph.attr(c, "diagnostics") else ph.attr(tree, "errors");
        const diags_obj = diag_list orelse return error.Python;
        defer py.Py_DecRef(diags_obj);
        a.diags = try readDiagnostics(arena, diags_obj);

        // Selector matches: kinds of defining nodes, tokens, folds
        var kinds: std.AutoHashMapUnmanaged(u32, lsp.Kind) = .empty;
        for (self.config.symbol_rules) |rule| {
            const nodes = try matchNodes(arena, rule.selector, view);
            for (nodes) |n| {
                const entry = try kinds.getOrPut(arena, n);
                if (!entry.found_existing) entry.value_ptr.* = rule.kind;
            }
        }
        const token_nodes = try arena.alloc([]const u32, self.config.token_rules.len);
        for (token_nodes, self.config.token_rules) |*slot, rule| slot.* = try matchNodes(arena, rule.selector, view);
        a.token_nodes = token_nodes;
        if (self.config.fold_rules.len != 0) {
            var folds: std.ArrayList(u32) = .empty;
            for (self.config.fold_rules) |sel| try folds.appendSlice(arena, try matchNodes(arena, sel, view));
            std.sort.pdq(u32, folds.items, {}, std.sort.asc(u32));
            a.fold_nodes = folds.items;
        }

        if (a.checked) |c| {
            const read = try readChecked(arena, c, &kinds);
            a.syms = read.syms;
            a.imports = read.imports;
        }
        return a;
    }
};

/// The nodes a selector matches, natively (zrules' match function).
fn matchNodes(arena: Allocator, selector: Selector, view: *const tree_mod.TreeView) error{ Python, OutOfMemory }![]const u32 {
    const out = try arena.alloc(u32, view.node_count);
    const n = selector.match(selector.ctx, @ptrCast(view), out.ptr);
    if (n == -1) return error.OutOfMemory;
    if (n < 0) {
        ph.raise(py.PyExc_ValueError(), "the tree was parsed with a different grammar than the selectors were compiled against", .{});
        return error.Python;
    }
    return out[0..@intCast(n)];
}

fn strOf(s: zabi.Str) ?[]const u8 {
    const p = s.ptr orelse return null;
    return p[0..s.len];
}

/// The symbols of a zrules Analysis, and the keys of the files it imports,
/// read through its capsule. They point into the Analysis, which the file's
/// analysis keeps.
fn readChecked(arena: Allocator, checked: *PyObject, kinds: *const std.AutoHashMapUnmanaged(u32, lsp.Kind)) error{ Python, OutOfMemory }!struct { syms: []const Sym, imports: []const []const u8 } {
    const capsule = ph.attr(checked, "capsule") orelse return error.Python;
    defer py.Py_DecRef(capsule);
    const raw = py.c.PyCapsule_GetPointer(capsule, zabi.ANALYSIS_CAPSULE) orelse {
        py.c.PyErr_Clear();
        ph.raise(py.PyExc_RuntimeError(), "zlsp needs zrules 0.1.5 or later (the {s} capsule)", .{zabi.ANALYSIS_CAPSULE});
        return error.Python;
    };
    const view: *const zabi.AnalysisView = @ptrCast(@alignCast(raw));
    if (view.abi != zabi.ANALYSIS_ABI) {
        ph.raise(py.PyExc_RuntimeError(), "zlsp reads zrules analyses with ABI {d}, but this zrules has {d}: upgrade zlsp or zrules", .{ zabi.ANALYSIS_ABI, view.abi });
        return error.Python;
    }
    const imports = try arena.alloc([]const u8, view.import_count);
    for (imports, 0..) |*slot, i| slot.* = strOf(view.imports.?[i]) orelse "";
    const n = view.symbol_count;
    const out = try arena.alloc(Sym, n);
    const all_uses: [*]const Span = @ptrCast(view.uses orelse @as([*]const zabi.Span, &.{}));
    for (out, 0..) |*slot, i| {
        const v = view.symbols.?[i];
        slot.* = .{
            .name = strOf(v.name) orelse "",
            .def = if (v.node != NONE) .{ .start = v.def.start, .end = v.def.end } else null,
            .def_node = v.node,
            .kind = if (v.node != NONE) kinds.get(v.node) else null,
            .type_text = strOf(v.type),
            .uses = all_uses[v.uses_start..][0..v.uses_len],
            .scope = v.scope,
            .owns = v.owns,
            .builtin = v.flags & zabi.SYMBOL_BUILTIN != 0,
            .origin_key = strOf(v.origin_key),
            .origin_node = v.origin_node,
        };
    }
    return .{ .syms = out, .imports = imports };
}

/// parser.parse_tree(bytes, recover=True): a new reference, or null with the
/// Python error set.
fn parseText(parser: *PyObject, text: []const u8) ?*PyObject {
    const bytes = py.c.PyBytes_FromStringAndSize(text.ptr, @intCast(text.len)) orelse return null;
    defer py.Py_DecRef(bytes);
    const method = ph.attr(parser, "parse_tree") orelse return null;
    defer py.Py_DecRef(method);
    const args = py.c.PyTuple_Pack(1, bytes) orelse return null;
    defer py.Py_DecRef(args);
    const kwargs = py.c.Py_BuildValue("{s:O}", "recover", py.Py_True()) orelse return null;
    defer py.Py_DecRef(kwargs);
    return py.c.PyObject_Call(method, args, kwargs);
}

fn severityOf(s: []const u8) i64 {
    if (std.mem.eql(u8, s, "warning")) return lsp.DiagnosticSeverity.warning;
    if (std.mem.eql(u8, s, "note")) return lsp.DiagnosticSeverity.information;
    return lsp.DiagnosticSeverity.err;
}

fn readDiagnostics(arena: Allocator, list: *PyObject) error{ Python, OutOfMemory }![]const Diag {
    const n: usize = @intCast(py.c.PyList_Size(list));
    const out = try arena.alloc(Diag, n);
    for (out, 0..) |*slot, i| {
        const d = py.c.PyList_GetItem(list, @intCast(i));
        const span_obj = ph.attr(d, "span") orelse return error.Python;
        defer py.Py_DecRef(span_obj);
        const span = (try ph.toSpan(span_obj)) orelse .{ 0, 0 };
        slot.* = .{
            .span = .{ .start = span[0], .end = span[1] },
            .severity = severityOf((try ph.attrString(arena, d, "severity")) orelse "error"),
            .code = (try ph.attrString(arena, d, "code")) orelse "",
            .message = (try ph.attrString(arena, d, "message")) orelse "",
        };
        const notes_obj = ph.attr(d, "notes") orelse return error.Python;
        defer py.Py_DecRef(notes_obj);
        const count = py.c.PySequence_Size(notes_obj);
        if (count > 0) {
            const notes = try arena.alloc(Note, @intCast(count));
            for (notes, 0..) |*note, k| {
                const nd = py.c.PySequence_GetItem(notes_obj, @intCast(k)) orelse return error.Python;
                defer py.Py_DecRef(nd);
                const ns_obj = ph.attr(nd, "span") orelse return error.Python;
                defer py.Py_DecRef(ns_obj);
                const ns = (try ph.toSpan(ns_obj)) orelse .{ 0, 0 };
                note.* = .{ .span = .{ .start = ns[0], .end = ns[1] }, .message = (try ph.attrString(arena, nd, "message")) orelse "" };
            }
            slot.notes = notes;
        }
    }
    return out;
}
