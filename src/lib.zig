//! zlsp: a Language Server Protocol server for languages defined with zgram
//! and checked with zrules.
//!
//! `Server(parser, rules, ...)` holds the configuration; `start_io()` serves
//! an editor over stdin/stdout; `handle(message)` runs one message without
//! I/O (tests, embedding). The protocol, the documents and every feature
//! are native (server.zig); Python only configures, and runs the rules.

const std = @import("std");
const pyoz = @import("PyOZ");
const py = pyoz.py;
const PyObject = pyoz.PyObject;
const ph = @import("pyhelp.zig");
const project_mod = @import("project.zig");
const server_mod = @import("server.zig");
const transport = @import("transport.zig");
const lsp = @import("lsp.zig");
const zabi = @import("zrules_abi.zig");
const textmate_mod = @import("textmate.zig");

const allocator = std.heap.c_allocator;
const raise = ph.raise;
const utf8 = ph.utf8;

/// Everything a Server owns, behind one pointer
const State = struct {
    arena: std.heap.ArenaAllocator,
    threaded: std.Io.Threaded,
    config: project_mod.Config,
    server: server_mod.Server = undefined,
    /// Python objects the config refers to (released with the state)
    refs: std.ArrayList(*PyObject) = .empty,

    fn destroy(self: *State) void {
        self.server.deinit();
        for (self.refs.items) |o| py.Py_DecRef(o);
        self.refs.deinit(allocator);
        self.threaded.deinit();
        self.arena.deinit();
        allocator.destroy(self);
    }

    fn keep(self: *State, obj: *PyObject) !void {
        py.Py_IncRef(obj);
        try self.refs.append(allocator, obj);
    }
};

const Server = struct {
    _state: ?*State = null,

    pub fn __new__(args: pyoz.Args(struct {
        parser: *PyObject,
        rules: ?*PyObject = null,
        name: ?*PyObject = null,
        version: ?*PyObject = null,
        extensions: ?*PyObject = null,
        resolve: ?*PyObject = null,
        symbols: ?*PyObject = null,
        tokens: ?*PyObject = null,
        comments: ?*PyObject = null,
        folding: ?*PyObject = null,
        keywords: ?*PyObject = null,
        hover: ?*PyObject = null,
        completion: ?*PyObject = null,
        code_actions: ?*PyObject = null,
        format: ?*PyObject = null,
        configuration: ?*PyObject = null,
        log: ?*PyObject = null,
        section: ?*PyObject = null,
    })) ?Server {
        const v = args.value;
        const state = allocator.create(State) catch return oom(Server);
        state.* = .{
            .arena = std.heap.ArenaAllocator.init(allocator),
            .threaded = std.Io.Threaded.init(allocator, .{}),
            .config = .{ .parser = v.parser },
        };
        var ok = false;
        defer if (!ok) {
            for (state.refs.items) |o| py.Py_DecRef(o);
            state.refs.deinit(allocator);
            state.threaded.deinit();
            state.arena.deinit();
            allocator.destroy(state);
        };
        configure(state, v) catch |e| {
            if (e == error.OutOfMemory) _ = py.c.PyErr_NoMemory();
            return null;
        };
        state.server = server_mod.Server.init(allocator, state.threaded.io(), &state.config) catch return oom(Server);
        if (optional(v.log)) |l| {
            const path = utf8(l, "log") orelse {
                state.server.deinit();
                return null;
            };
            state.server.openLog(path) catch |e| {
                state.server.deinit();
                raise(py.PyExc_OSError(), "cannot open the log file '{s}': {s}", .{ path, @errorName(e) });
                return null;
            };
        }
        ok = true;
        return .{ ._state = state };
    }

    pub fn __del__(self: *Server) void {
        if (self._state) |s| s.destroy();
        self._state = null;
    }

    /// Handle one message (a JSON-RPC body, str or bytes) and whatever it
    /// makes due; returns the messages to send, as JSON strs.
    pub fn handle(self: *Server, message: *PyObject) pyoz.Signature(?*PyObject, "list[str]") {
        const state = self._state orelse return .{ .value = notReady() };
        var body: []const u8 = undefined;
        if (py.PyBytes_Check(message)) {
            var ptr: [*c]u8 = undefined;
            var len: py.Py_ssize_t = 0;
            if (py.c.PyBytes_AsStringAndSize(message, &ptr, &len) != 0) return .{ .value = null };
            body = ptr[0..@intCast(len)];
        } else body = utf8(message, "message") orelse return .{ .value = null };
        state.server.handle(body) catch |e| return .{ .value = failed(e) };
        state.server.idle() catch |e| return .{ .value = failed(e) };
        return .{ .value = drain(state) };
    }

    /// The code the server should exit with once the client sent `exit`
    /// (0 after `shutdown`, 1 without), or None.
    pub fn get_exit_code(self: *const Server) ?i64 {
        const state = self._state orelse return null;
        return if (state.server.exit_code) |c| c else null;
    }

    /// Serve an editor over stdin/stdout until it sends `exit` or closes
    /// the input. Returns the exit code for the process. While serving,
    /// sys.stdout is sys.stderr (a print() would break the protocol).
    pub fn start_io(self: *Server) ?i64 {
        const state = self._state orelse return notReadyInt();
        const sys = py.c.PyImport_ImportModule("sys") orelse return null;
        defer py.Py_DecRef(sys);
        const saved_stdout = ph.attr(sys, "stdout") orelse return null;
        defer py.Py_DecRef(saved_stdout);
        const stderr = ph.attr(sys, "stderr") orelse return null;
        defer py.Py_DecRef(stderr);
        if (py.c.PyObject_SetAttrString(sys, "stdout", stderr) != 0) return null;
        defer _ = py.c.PyObject_SetAttrString(sys, "stdout", saved_stdout);

        const code = serve(state) catch |e| {
            if (py.c.PyErr_Occurred() == null) raise(py.PyExc_RuntimeError(), "zlsp: {s}", .{@errorName(e)});
            return null;
        };
        return code;
    }

    /// A TextMate grammar for the language (JSON): its comments, strings,
    /// numbers and keywords, for VS Code's `contributes.grammars`.
    pub fn textmate(self: *const Server, args: pyoz.Args(struct { scope: ?*PyObject = null })) ?*PyObject {
        const state = self._state orelse return notReady();
        const c = &state.config;
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const scope: []const u8 = if (optional(args.value.scope)) |s| utf8(s, "scope") orelse return null else "";
        const lits = py.c.PyObject_CallMethod(c.parser, "literals", null) orelse return null;
        defer py.Py_DecRef(lits);
        const literals = strings(a, lits, "literals") catch |e| return failed(e);
        const text = textmate_mod.generate(allocator, .{
            .name = c.name,
            .scope = scope,
            .keywords = c.keywords,
            .literals = literals,
            .line_comments = c.line_comments,
            .block_comments = c.block_comments,
        }) catch |e| return failed(e);
        defer allocator.free(text);
        return ph.newString(text);
    }

    pub const __doc__: [*:0]const u8 = "Server(parser, rules=None, *, name=None, version=None, extensions=None, resolve=None, symbols=None, tokens=None, comments=None, folding=None, keywords=None, hover=None, completion=None, code_actions=None, format=None, configuration=None, section=None, log=None): a language server for a zgram grammar (and zrules rules). start_io() serves an editor over stdin/stdout; handle(message) runs one JSON-RPC message and returns the messages to send.";
    pub const textmate__doc__: [*:0]const u8 = "A TextMate grammar for the language, as JSON (comments, strings, numbers, keywords): for an editor extension's syntax highlighting before the server answers. scope defaults to source.<name>.";
    pub const handle__doc__: [*:0]const u8 = "Handle one JSON-RPC message (str or bytes) and return the messages to send (JSON strs), diagnostics included.";
    pub const handle__params__ = "message";
    pub const start_io__doc__: [*:0]const u8 = "Serve an editor over stdin/stdout until it sends exit or closes the input; returns the process exit code.";
};

fn oom(comptime T: type) ?T {
    _ = py.c.PyErr_NoMemory();
    return null;
}

fn notReady() ?*PyObject {
    raise(py.PyExc_RuntimeError(), "the Server is not initialized", .{});
    return null;
}

fn notReadyInt() ?i64 {
    raise(py.PyExc_RuntimeError(), "the Server is not initialized", .{});
    return null;
}

fn failed(e: anyerror) ?*PyObject {
    if (py.c.PyErr_Occurred() != null) return null;
    if (e == error.OutOfMemory) return py.c.PyErr_NoMemory();
    raise(py.PyExc_RuntimeError(), "zlsp: {s}", .{@errorName(e)});
    return null;
}

/// The queued outgoing messages as a list of str (emptying the queue).
fn drain(state: *State) ?*PyObject {
    const out = &state.server.out;
    defer {
        for (out.items) |m| allocator.free(m);
        out.clearRetainingCapacity();
    }
    const list = py.c.PyList_New(@intCast(out.items.len)) orelse return null;
    for (out.items, 0..) |m, i| {
        const s = ph.newString(m) orelse {
            py.Py_DecRef(list);
            return null;
        };
        _ = py.c.PyList_SetItem(list, @intCast(i), s);
    }
    return list;
}

// ============================================================================
// Configuration
// ============================================================================

const ConfigArgs = @typeInfo(@typeInfo(@TypeOf(Server.__new__)).@"fn".params[0].type.?).@"struct".fields[0].type;

fn configure(state: *State, v: ConfigArgs) error{ Python, OutOfMemory }!void {
    const a = state.arena.allocator();
    const c = &state.config;
    try state.keep(v.parser);
    if (optional(v.rules)) |r| {
        try state.keep(r);
        c.rules = r;
    }
    if (optional(v.resolve)) |r| {
        if (py.c.PyCallable_Check(r) == 0) {
            raise(py.PyExc_TypeError(), "resolve must be callable: resolve(module, importing_key) -> key or None", .{});
            return error.Python;
        }
        try state.keep(r);
        c.resolve = r;
    }
    // Hooks
    inline for (.{
        .{ "hover", "hover_hook", "hover(uri, text, offset, analysis) -> str or None" },
        .{ "completion", "completion_hook", "completion(uri, text, offset, analysis) -> list of str or dict" },
        .{ "code_actions", "code_action_hook", "code_actions(uri, text, start, end, diagnostics, analysis) -> list of dict" },
        .{ "format", "format_hook", "format(uri, text, analysis) -> str or None" },
        .{ "configuration", "configuration_hook", "configuration(settings) -> None" },
    }) |h| {
        if (optional(@field(v, h[0]))) |f| {
            if (py.c.PyCallable_Check(f) == 0) {
                raise(py.PyExc_TypeError(), "{s} must be callable: {s}", .{ h[0], h[2] });
                return error.Python;
            }
            try state.keep(f);
            @field(c, h[1]) = f;
        }
    }
    if (optional(v.name)) |n| c.name = try a.dupe(u8, utf8(n, "name") orelse return error.Python);
    c.section = c.name;
    if (optional(v.section)) |n| c.section = try a.dupe(u8, utf8(n, "section") orelse return error.Python);
    if (optional(v.version)) |n| c.version = try a.dupe(u8, utf8(n, "version") orelse return error.Python);

    if (optional(v.extensions)) |e| {
        const exts = try strings(a, e, "extensions");
        for (exts) |*ext| {
            if (ext.len != 0 and ext.*[0] != '.') ext.* = try std.fmt.allocPrint(a, ".{s}", .{ext.*});
        }
        c.extensions = exts;
    }

    // Selectors, compiled by zrules against the grammar
    const zrules = py.c.PyImport_ImportModule("zrules") orelse return error.Python;
    defer py.Py_DecRef(zrules);
    const selector_class = ph.attr(zrules, "Selector") orelse {
        py.c.PyErr_Clear();
        raise(py.PyExc_ImportError(), "zlsp needs zrules 0.1.3 or later (zrules.Selector)", .{});
        return error.Python;
    };
    defer py.Py_DecRef(selector_class);

    if (optional(v.symbols)) |d| {
        var rules: std.ArrayList(project_mod.SymbolRule) = .empty;
        try forItems(d, "symbols", struct {
            fn item(st: *State, cls: *PyObject, list: *std.ArrayList(project_mod.SymbolRule), key: *PyObject, value: *PyObject) error{ Python, OutOfMemory }!void {
                const name = utf8(value, "a symbol kind") orelse return error.Python;
                const kind = lsp.Kind.parse(name) orelse {
                    raise(py.PyExc_ValueError(), "unknown symbol kind '{s}' (one of: {s})", .{ name, comptime names(lsp.Kind) });
                    return error.Python;
                };
                try list.append(st.arena.allocator(), .{ .selector = try compileSelector(st, cls, key), .kind = kind });
            }
        }.item, state, selector_class, &rules);
        c.symbol_rules = rules.items;
    }
    if (optional(v.tokens)) |d| {
        var rules: std.ArrayList(project_mod.TokenRule) = .empty;
        try forItems(d, "tokens", struct {
            fn item(st: *State, cls: *PyObject, list: *std.ArrayList(project_mod.TokenRule), key: *PyObject, value: *PyObject) error{ Python, OutOfMemory }!void {
                const name = utf8(value, "a token type") orelse return error.Python;
                const t = lsp.TokenType.parse(name) orelse {
                    raise(py.PyExc_ValueError(), "unknown token type '{s}' (one of: {s})", .{ name, comptime names(lsp.TokenType) });
                    return error.Python;
                };
                try list.append(st.arena.allocator(), .{ .selector = try compileSelector(st, cls, key), .type = t });
            }
        }.item, state, selector_class, &rules);
        c.token_rules = rules.items;
    }
    if (optional(v.folding)) |f| {
        var sels: std.ArrayList(project_mod.Selector) = .empty;
        const texts = try objects(a, f, "folding");
        for (texts) |t| try sels.append(a, try compileSelector(state, selector_class, t));
        c.fold_rules = sels.items;
    }

    if (optional(v.comments)) |cm| {
        var lines: std.ArrayList([]const u8) = .empty;
        var blocks: std.ArrayList([2][]const u8) = .empty;
        const items = try objects(a, cm, "comments");
        for (items) |item| {
            if (py.PyUnicode_Check(item)) {
                const s = utf8(item, "a comment marker") orelse return error.Python;
                if (s.len == 0) continue;
                try lines.append(a, try a.dupe(u8, s));
                continue;
            }
            const pair = try strings(a, item, "a block comment (open, close)");
            if (pair.len != 2 or pair[0].len == 0 or pair[1].len == 0) {
                raise(py.PyExc_ValueError(), "comments: a block comment is a pair of non-empty str (open, close)", .{});
                return error.Python;
            }
            try blocks.append(a, .{ pair[0], pair[1] });
        }
        c.line_comments = lines.items;
        c.block_comments = blocks.items;
    }

    // Keywords: given, or the grammar's word literals
    if (optional(v.keywords)) |k| {
        c.keywords = try strings(a, k, "keywords");
    } else {
        const lits = py.c.PyObject_CallMethod(v.parser, "literals", null) orelse {
            py.c.PyErr_Clear();
            raise(py.PyExc_TypeError(), "Server() needs a zgram parser, 0.3.3 or later (parser.literals())", .{});
            return error.Python;
        };
        defer py.Py_DecRef(lits);
        var words: std.ArrayList([]const u8) = .empty;
        for (try strings(a, lits, "literals")) |lit| {
            if (isWord(lit)) try words.append(a, lit);
        }
        c.keywords = words.items;
    }
}

fn names(comptime E: type) []const u8 {
    comptime {
        var out: []const u8 = "";
        for (std.meta.fieldNames(E), 0..) |n, i| out = out ++ (if (i == 0) "" else ", ") ++ n;
        return out;
    }
}

/// A word literal (`let`, `end`): letters, digits, `_`, starting with a letter or `_`.
fn isWord(s: []const u8) bool {
    if (s.len == 0 or !(std.ascii.isAlphabetic(s[0]) or s[0] == '_')) return false;
    for (s) |ch| {
        if (!(std.ascii.isAlphanumeric(ch) or ch == '_')) return false;
    }
    return true;
}

fn optional(obj: ?*PyObject) ?*PyObject {
    const o = obj orelse return null;
    return if (o == py.Py_None()) null else o;
}

/// zrules.Selector(parser, text), as its native match function. The
/// capsule (which keeps the selector alive) is kept with the state.
fn compileSelector(state: *State, cls: *PyObject, text: *PyObject) error{ Python, OutOfMemory }!project_mod.Selector {
    const sel = py.c.PyObject_CallFunctionObjArgs(cls, state.config.parser, text, @as(?*PyObject, null)) orelse return error.Python;
    defer py.Py_DecRef(sel);
    const capsule = ph.attr(sel, "capsule") orelse {
        py.c.PyErr_Clear();
        raise(py.PyExc_ImportError(), "zlsp needs zrules 0.1.4 or later (Selector.capsule)", .{});
        return error.Python;
    };
    errdefer py.Py_DecRef(capsule);
    const raw = py.c.PyCapsule_GetPointer(capsule, zabi.SELECTOR_CAPSULE) orelse return error.Python;
    const view: project_mod.Selector = @ptrCast(@alignCast(raw));
    if (view.abi != zabi.SELECTOR_ABI) {
        raise(py.PyExc_ImportError(), "zlsp reads zrules selectors with ABI {d}, but this zrules has {d}: upgrade zlsp or zrules", .{ zabi.SELECTOR_ABI, view.abi });
        return error.Python;
    }
    try state.refs.append(allocator, capsule);
    return view;
}

/// Call `f` on each (key, value) of a dict.
fn forItems(d: *PyObject, what: []const u8, comptime f: anytype, state: *State, cls: *PyObject, list: anytype) error{ Python, OutOfMemory }!void {
    if (!py.PyDict_Check(d)) {
        raise(py.PyExc_TypeError(), "{s} must be a dict of selector -> name", .{what});
        return error.Python;
    }
    var pos: py.Py_ssize_t = 0;
    var key: ?*PyObject = null;
    var value: ?*PyObject = null;
    while (py.c.PyDict_Next(d, &pos, &key, &value) != 0) try f(state, cls, list, key.?, value.?);
}

/// A str, or a sequence of them, copied into `a`.
fn strings(a: std.mem.Allocator, obj: *PyObject, what: []const u8) error{ Python, OutOfMemory }![][]const u8 {
    if (py.PyUnicode_Check(obj)) {
        const one = try a.alloc([]const u8, 1);
        one[0] = try a.dupe(u8, utf8(obj, what) orelse return error.Python);
        return one;
    }
    const items = try objects(a, obj, what);
    const out = try a.alloc([]const u8, items.len);
    for (out, items) |*slot, item| slot.* = try a.dupe(u8, utf8(item, what) orelse return error.Python);
    return out;
}

/// The items of a sequence (borrowed: the sequence keeps them), or the
/// object itself if it's a str.
fn objects(a: std.mem.Allocator, obj: *PyObject, what: []const u8) error{ Python, OutOfMemory }![]*PyObject {
    if (py.PyUnicode_Check(obj)) {
        const one = try a.alloc(*PyObject, 1);
        one[0] = obj;
        return one;
    }
    const n = py.c.PySequence_Size(obj);
    if (n < 0) {
        py.c.PyErr_Clear();
        raise(py.PyExc_TypeError(), "{s} must be a str or a sequence", .{what});
        return error.Python;
    }
    const out = try a.alloc(*PyObject, @intCast(n));
    for (out, 0..) |*slot, i| {
        const item = py.c.PySequence_GetItem(obj, @intCast(i)) orelse return error.Python;
        // (a list or tuple keeps its items; the sequence outlives this use)
        py.Py_DecRef(item);
        slot.* = item;
    }
    return out;
}

// ============================================================================
// Serving over stdin/stdout
// ============================================================================

const Queue = std.Io.Queue([]u8);

/// The messages read from stdin, between the reader thread and the server.
/// Freed by whichever of the two lets go last: the reader may still be
/// waiting for input after the server has stopped.
const Inbox = struct {
    slots: [256][]u8 = undefined,
    queue: Queue = undefined,
    refs: std.atomic.Value(u32) = .init(2),
    /// Messages put and not yet taken (the queue can't be peeked)
    waiting: std.atomic.Value(u32) = .init(0),

    fn pending(ctx: *anyopaque) bool {
        const self: *Inbox = @ptrCast(@alignCast(ctx));
        return self.waiting.load(.acquire) > 0;
    }

    fn create() !*Inbox {
        const inbox = try allocator.create(Inbox);
        inbox.* = .{};
        inbox.queue = Queue.init(&inbox.slots);
        return inbox;
    }

    fn release(self: *Inbox, io: std.Io) void {
        if (self.refs.fetchSub(1, .acq_rel) != 1) return;
        // (whatever is left unread)
        var rest: [256][]u8 = undefined;
        const n = self.queue.getUncancelable(io, &rest, 0) catch 0;
        for (rest[0..n]) |m| allocator.free(m);
        allocator.destroy(self);
    }
};

/// Reads stdin, cuts it into messages, queues them; closes the queue at
/// the end of the input.
fn readInput(io: std.Io, inbox: *Inbox) void {
    defer inbox.release(io);
    defer inbox.queue.close(io);
    var framer = transport.Framer.init(allocator);
    defer framer.deinit();
    const stdin = std.Io.File.stdin();
    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        const n = stdin.readStreaming(io, &.{&buf}) catch return;
        if (n == 0) return;
        framer.feed(buf[0..n]) catch return;
        while (framer.next() catch return) |msg| {
            _ = inbox.waiting.fetchAdd(1, .acq_rel);
            inbox.queue.putOne(io, msg) catch {
                allocator.free(msg);
                return;
            };
        }
    }
}

/// The next message, waiting for it (without the GIL); null at the end.
fn waitMessage(io: std.Io, queue: *Queue) ?[]u8 {
    return queue.getOneUncancelable(io) catch null;
}

fn serve(state: *State) !i64 {
    const io = state.threaded.io();
    const srv = &state.server;
    const inbox = try Inbox.create();
    const reader = std.Thread.spawn(.{}, readInput, .{ io, inbox }) catch |e| {
        allocator.destroy(inbox);
        return e;
    };
    reader.detach();
    defer inbox.release(io);
    const queue = &inbox.queue;
    const stdout = std.Io.File.stdout();
    // An idle analysis stops when input arrives
    srv.interrupt = .{ .ctx = inbox, .pending = &Inbox.pending };
    defer srv.interrupt = null;

    var batch: [256][]u8 = undefined;
    while (srv.exit_code == null) {
        // Whatever has arrived, without waiting
        var n = queue.getUncancelable(io, &batch, 0) catch 0;
        if (n == 0) {
            // Nothing waiting: catch up, then wait
            try srv.idle();
            try flush(io, stdout, srv);
            const msg = pyoz.allowThreads(waitMessage, .{ io, queue }) orelse break;
            batch[0] = msg;
            n = 1;
        }
        _ = inbox.waiting.fetchSub(@intCast(n), .acq_rel);
        // Cancellations first: they may be about requests in the batch
        for (batch[0..n]) |msg| {
            if (std.mem.indexOf(u8, msg, "\"$/cancelRequest\"") != null) try srv.handle(msg);
        }
        for (batch[0..n]) |msg| {
            defer allocator.free(msg);
            if (std.mem.indexOf(u8, msg, "\"$/cancelRequest\"") != null) continue;
            if (srv.exit_code == null) try srv.handle(msg);
            try flush(io, stdout, srv);
        }
    }
    try flush(io, stdout, srv);
    return srv.exit_code orelse 1;
}

fn flush(io: std.Io, stdout: std.Io.File, srv: *server_mod.Server) !void {
    for (srv.out.items) |m| {
        var hbuf: [64]u8 = undefined;
        stdout.writeStreamingAll(io, transport.header(&hbuf, m.len)) catch return error.BrokenPipe;
        stdout.writeStreamingAll(io, m) catch return error.BrokenPipe;
    }
    for (srv.out.items) |m| allocator.free(m);
    srv.out.clearRetainingCapacity();
}

// ============================================================================
// Module
// ============================================================================

fn version() []const u8 {
    return @import("build_options").version;
}

pub const Module = pyoz.module(.{
    .name = "zlsp",
    .doc = "zlsp - a native Language Server Protocol server for languages defined with zgram and checked with zrules.",
    .funcs = &.{
        pyoz.func("version", version, "Return the zlsp version string"),
    },
    .classes = &.{
        pyoz.class("Server", Server),
    },
});

// Required: forces analysis of all pub decls so PyInit_ is exported.
comptime {
    for (@typeInfo(@This()).@"struct".decls) |decl| {
        _ = @field(@This(), decl.name);
    }
}
