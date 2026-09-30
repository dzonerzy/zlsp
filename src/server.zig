//! The language server: LSP messages in, messages out.
//!
//! `handle(body)` takes one message and queues what to send in `out`;
//! `idle()` runs when no more input is waiting: it brings the analysis up to
//! date and publishes the diagnostics that changed. Requests that need
//! results analyze first. Everything runs on one thread, with the GIL held.

const std = @import("std");
const Allocator = std.mem.Allocator;
const json = @import("json.zig");
const document = @import("document.zig");
const project_mod = @import("project.zig");
const uri_mod = @import("uri.zig");
const lsp = @import("lsp.zig");
const ph = @import("pyhelp.zig");
const py = ph.py;
const PyObject = ph.PyObject;

const Project = project_mod.Project;
const File = project_mod.File;
const Analysis = project_mod.Analysis;
const Span = project_mod.Span;
const Sym = project_mod.Sym;
const Config = project_mod.Config;
const Encoding = document.Encoding;
const Document = document.Document;
const Value = json.Value;
const NONE = project_mod.NONE;

/// Workspace files read at most (a huge tree opened by mistake stays usable)
const MAX_WORKSPACE_FILES = 10_000;
const MAX_FILE_SIZE = 16 * 1024 * 1024;

pub const Server = struct {
    gpa: Allocator,
    io: std.Io,
    config: *const Config,
    project: Project,
    encoding: Encoding = .utf16,
    /// Workspace roots (paths)
    roots: std.ArrayList([]u8) = .empty,
    initialized: bool = false,
    shutting_down: bool = false,
    /// Set by the `exit` notification: 0 after `shutdown`, 1 otherwise
    exit_code: ?u8 = null,
    /// Messages to send, in order (owned)
    out: std.ArrayList([]u8) = .empty,
    /// Ids (as JSON) of requests the client cancelled
    cancelled: std.StringHashMapUnmanaged(void) = .empty,
    /// Keywords, for lookups
    keywords: std.StringHashMapUnmanaged(void) = .empty,
    next_request_id: i64 = 1,
    client: struct {
        multiline_tokens: bool = false,
        hierarchical_symbols: bool = false,
        related_information: bool = false,
        watched_files: bool = false,
    } = .{},

    pub fn init(gpa: Allocator, io: std.Io, config: *const Config) !Server {
        var s = Server{ .gpa = gpa, .io = io, .config = config, .project = .{ .gpa = gpa, .config = config } };
        for (config.keywords) |k| try s.keywords.put(gpa, k, {});
        return s;
    }

    pub fn deinit(self: *Server) void {
        self.project.deinit();
        for (self.roots.items) |r| self.gpa.free(r);
        self.roots.deinit(self.gpa);
        for (self.out.items) |m| self.gpa.free(m);
        self.out.deinit(self.gpa);
        var it = self.cancelled.keyIterator();
        while (it.next()) |k| self.gpa.free(k.*);
        self.cancelled.deinit(self.gpa);
        self.keywords.deinit(self.gpa);
    }

    // ------------------------------------------------------------------
    // Messages
    // ------------------------------------------------------------------

    /// Handle one message (a JSON body).
    pub fn handle(self: *Server, body: []const u8) !void {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const msg = std.json.parseFromSliceLeaky(Value, a, body, .{}) catch {
            return self.respondError("null", lsp.ErrorCode.parse_error, "the message is not valid JSON");
        };
        const method = json.getString(msg, "method");
        const id_value = json.get(msg, "id");
        const params = json.get(msg, "params");
        const id: ?[]const u8 = if (id_value) |v| try std.json.Stringify.valueAlloc(a, v, .{}) else null;

        const m = method orelse return; // a response to one of our requests
        if (id) |req_id| {
            if (self.cancelled.fetchRemove(req_id)) |kv| {
                self.gpa.free(kv.key);
                return self.respondError(req_id, lsp.ErrorCode.request_cancelled, "cancelled");
            }
            if (!self.initialized and !std.mem.eql(u8, m, "initialize")) {
                return self.respondError(req_id, lsp.ErrorCode.server_not_initialized, "the server is not initialized");
            }
            if (self.shutting_down) {
                return self.respondError(req_id, lsp.ErrorCode.invalid_request, "the server is shutting down");
            }
            self.request(a, req_id, m, params) catch |e| switch (e) {
                error.Python => {
                    var buf: [512]u8 = undefined;
                    const text = ph.takeError(&buf);
                    return self.respondError(req_id, lsp.ErrorCode.internal_error, text);
                },
                error.InvalidParams => return self.respondError(req_id, lsp.ErrorCode.invalid_params, "invalid parameters"),
                else => |other| return other,
            };
        } else {
            if (!self.initialized and !std.mem.eql(u8, m, "exit")) return;
            try self.notification(a, m, params);
        }
    }

    /// Nothing more to read for now: analyze and publish.
    pub fn idle(self: *Server) !void {
        if (!self.initialized) return;
        try self.analyze();
        try self.publishAll();
    }

    fn analyze(self: *Server) !void {
        var buf: [512]u8 = undefined;
        var len: usize = 0;
        const outcome = try self.project.analyze(&buf, &len);
        if (outcome != .failed) return;
        const text = buf[0..len];
        if (self.project.last_failure) |prev| {
            if (std.mem.eql(u8, prev, text)) return;
            self.gpa.free(prev);
        }
        self.project.last_failure = try self.gpa.dupe(u8, text);
        var msg: [600]u8 = undefined;
        try self.logMessage(1, std.fmt.bufPrint(&msg, "analysis failed: {s}", .{text}) catch text);
    }

    fn request(self: *Server, a: Allocator, id: []const u8, method: []const u8, params: ?Value) !void {
        const R = *const fn (*Server, Allocator, *json.Writer, ?Value) anyerror!void;
        const table = [_]struct { []const u8, R }{
            .{ "initialize", initialize },
            .{ "shutdown", shutdown },
            .{ "textDocument/definition", definition },
            .{ "textDocument/declaration", definition },
            .{ "textDocument/references", references },
            .{ "textDocument/documentHighlight", documentHighlight },
            .{ "textDocument/prepareRename", prepareRename },
            .{ "textDocument/rename", rename },
            .{ "textDocument/hover", hover },
            .{ "textDocument/documentSymbol", documentSymbol },
            .{ "textDocument/semanticTokens/full", semanticTokens },
            .{ "textDocument/foldingRange", foldingRange },
            .{ "textDocument/completion", completion },
            .{ "workspace/symbol", workspaceSymbol },
        };
        for (table) |entry| {
            if (!std.mem.eql(u8, entry[0], method)) continue;
            var w = json.Writer.init(self.gpa);
            defer w.deinit();
            try w.beginObject();
            try w.fieldString("jsonrpc", "2.0");
            try w.key("id");
            try w.raw(id);
            try w.key("result");
            try entry[1](self, a, &w, params);
            try w.endObject();
            return self.send(&w);
        }
        return self.respondError(id, lsp.ErrorCode.method_not_found, method);
    }

    fn notification(self: *Server, a: Allocator, method: []const u8, params: ?Value) !void {
        _ = a;
        if (std.mem.eql(u8, method, "exit")) {
            self.exit_code = if (self.shutting_down) 0 else 1;
        } else if (std.mem.eql(u8, method, "initialized")) {
            try self.registerWatchers();
        } else if (std.mem.eql(u8, method, "textDocument/didOpen")) {
            const td = json.get(params, "textDocument") orelse return;
            const u = json.getString(td, "uri") orelse return;
            try self.openFile(u, json.getString(td, "text") orelse "", json.getInt(td, "version") orelse 0);
        } else if (std.mem.eql(u8, method, "textDocument/didChange")) {
            try self.didChange(params);
        } else if (std.mem.eql(u8, method, "textDocument/didClose")) {
            const u = json.getString(json.get(params, "textDocument"), "uri") orelse return;
            try self.closeFile(u);
        } else if (std.mem.eql(u8, method, "workspace/didChangeWatchedFiles")) {
            for (json.getArray(params, "changes") orelse &.{}) |change| {
                const u = json.getString(change, "uri") orelse continue;
                try self.watchedChange(u, json.getInt(change, "type") orelse 2);
            }
        } else if (std.mem.eql(u8, method, "$/cancelRequest")) {
            const idv = json.get(params, "id") orelse return;
            const text = try std.json.Stringify.valueAlloc(self.gpa, idv, .{});
            const entry = try self.cancelled.getOrPut(self.gpa, text);
            if (entry.found_existing) self.gpa.free(text);
        }
        // Everything else (didSave, setTrace, ...) needs nothing
    }

    // ------------------------------------------------------------------
    // Output
    // ------------------------------------------------------------------

    fn send(self: *Server, w: *json.Writer) !void {
        const body = try w.toOwned();
        errdefer self.gpa.free(body);
        try self.out.append(self.gpa, body);
    }

    fn respondError(self: *Server, id: []const u8, code: i64, message: []const u8) !void {
        var w = json.Writer.init(self.gpa);
        defer w.deinit();
        try w.beginObject();
        try w.fieldString("jsonrpc", "2.0");
        try w.key("id");
        try w.raw(id);
        try w.key("error");
        try w.beginObject();
        try w.fieldInt("code", code);
        try w.fieldString("message", message);
        try w.endObject();
        try w.endObject();
        try self.send(&w);
    }

    /// window/logMessage (type 1 error, 2 warning, 3 info, 4 log)
    pub fn logMessage(self: *Server, kind: i64, message: []const u8) !void {
        var w = json.Writer.init(self.gpa);
        defer w.deinit();
        try w.beginObject();
        try w.fieldString("jsonrpc", "2.0");
        try w.fieldString("method", "window/logMessage");
        try w.key("params");
        try w.beginObject();
        try w.fieldInt("type", kind);
        try w.fieldString("message", message);
        try w.endObject();
        try w.endObject();
        try self.send(&w);
    }

    fn writePosition(self: *const Server, w: *json.Writer, doc: *const Document, offset: u32) !void {
        const p = doc.positionOf(offset, self.encoding);
        try w.beginObject();
        try w.fieldInt("line", p.line);
        try w.fieldInt("character", p.character);
        try w.endObject();
    }

    fn writeRange(self: *const Server, w: *json.Writer, doc: *const Document, span: Span) !void {
        try w.beginObject();
        try w.key("start");
        try self.writePosition(w, doc, span.start);
        try w.key("end");
        try self.writePosition(w, doc, span.end);
        try w.endObject();
    }

    fn writeLocation(self: *const Server, w: *json.Writer, f: *const File, span: Span) !void {
        try w.beginObject();
        try w.fieldString("uri", f.uri);
        try w.key("range");
        try self.writeRange(w, &f.doc, span);
        try w.endObject();
    }

    // ------------------------------------------------------------------
    // Lifecycle
    // ------------------------------------------------------------------

    fn initialize(self: *Server, a: Allocator, w: *json.Writer, params: ?Value) !void {
        _ = a;
        const caps = json.get(params, "capabilities");
        // UTF-8 positions if the client can (no conversion); UTF-16 otherwise
        for (json.getArray(json.get(caps, "general"), "positionEncodings") orelse &.{}) |enc| {
            if (enc == .string and std.mem.eql(u8, enc.string, "utf-8")) self.encoding = .utf8;
        }
        const td = json.get(caps, "textDocument");
        self.client.multiline_tokens = json.getBool(json.get(td, "semanticTokens"), "multilineTokenSupport") orelse false;
        self.client.hierarchical_symbols = json.getBool(json.get(td, "documentSymbol"), "hierarchicalDocumentSymbolSupport") orelse false;
        self.client.related_information = json.getBool(json.get(td, "publishDiagnostics"), "relatedInformation") orelse false;
        self.client.watched_files = json.getBool(json.path(caps, &.{ "workspace", "didChangeWatchedFiles" }), "dynamicRegistration") orelse false;

        // The workspace: its folders, or the root
        var roots: std.ArrayList([]const u8) = .empty;
        defer roots.deinit(self.gpa);
        for (json.getArray(params, "workspaceFolders") orelse &.{}) |folder| {
            if (json.getString(folder, "uri")) |u| try roots.append(self.gpa, u);
        }
        if (roots.items.len == 0) {
            if (json.getString(params, "rootUri")) |u| try roots.append(self.gpa, u);
        }
        for (roots.items) |u| {
            const p = (try uri_mod.toPath(self.gpa, u)) orelse continue;
            try self.roots.append(self.gpa, p);
        }
        if (self.roots.items.len == 0) {
            if (json.getString(params, "rootPath")) |p| try self.roots.append(self.gpa, try self.gpa.dupe(u8, p));
        }
        for (self.roots.items) |root| self.scanWorkspace(root) catch {};
        self.initialized = true;

        try w.beginObject();
        try w.key("capabilities");
        try w.beginObject();
        try w.fieldString("positionEncoding", if (self.encoding == .utf8) "utf-8" else "utf-16");
        try w.key("textDocumentSync");
        try w.beginObject();
        try w.fieldBool("openClose", true);
        try w.fieldInt("change", 2); // incremental
        try w.endObject();
        try w.fieldBool("definitionProvider", true);
        try w.fieldBool("declarationProvider", true);
        try w.fieldBool("referencesProvider", true);
        try w.fieldBool("documentHighlightProvider", true);
        try w.key("renameProvider");
        try w.beginObject();
        try w.fieldBool("prepareProvider", true);
        try w.endObject();
        try w.fieldBool("hoverProvider", true);
        try w.fieldBool("documentSymbolProvider", true);
        try w.fieldBool("workspaceSymbolProvider", true);
        try w.fieldBool("foldingRangeProvider", true);
        try w.key("completionProvider");
        try w.beginObject();
        try w.key("triggerCharacters");
        try w.beginArray();
        try w.string(".");
        try w.endArray();
        try w.endObject();
        try w.key("semanticTokensProvider");
        try w.beginObject();
        try w.key("legend");
        try w.beginObject();
        try w.key("tokenTypes");
        try w.beginArray();
        for (std.meta.fieldNames(lsp.TokenType)) |name| try w.string(name);
        try w.endArray();
        try w.key("tokenModifiers");
        try w.beginArray();
        for (std.meta.fieldNames(lsp.Modifier)) |name| try w.string(name);
        try w.endArray();
        try w.endObject();
        try w.fieldBool("full", true);
        try w.fieldBool("range", false);
        try w.endObject();
        try w.endObject();
        try w.key("serverInfo");
        try w.beginObject();
        try w.fieldString("name", self.config.name);
        if (self.config.version.len != 0) try w.fieldString("version", self.config.version);
        try w.endObject();
        try w.endObject();
    }

    fn shutdown(self: *Server, a: Allocator, w: *json.Writer, params: ?Value) !void {
        _ = a;
        _ = params;
        self.shutting_down = true;
        try w.null_();
    }

    /// Ask the client to tell us about changes to the language's files on
    /// disk (dynamic registration of workspace/didChangeWatchedFiles).
    fn registerWatchers(self: *Server) !void {
        if (!self.client.watched_files or self.config.extensions.len == 0) return;
        var w = json.Writer.init(self.gpa);
        defer w.deinit();
        try w.beginObject();
        try w.fieldString("jsonrpc", "2.0");
        try w.fieldInt("id", self.next_request_id);
        self.next_request_id += 1;
        try w.fieldString("method", "client/registerCapability");
        try w.key("params");
        try w.beginObject();
        try w.key("registrations");
        try w.beginArray();
        try w.beginObject();
        try w.fieldString("id", "zlsp-watch");
        try w.fieldString("method", "workspace/didChangeWatchedFiles");
        try w.key("registerOptions");
        try w.beginObject();
        try w.key("watchers");
        try w.beginArray();
        for (self.config.extensions) |ext| {
            try w.beginObject();
            var buf: [128]u8 = undefined;
            try w.fieldString("globPattern", std.fmt.bufPrint(&buf, "**/*{s}", .{ext}) catch continue);
            try w.endObject();
        }
        try w.endArray();
        try w.endObject();
        try w.endObject();
        try w.endArray();
        try w.endObject();
        try w.endObject();
        try self.send(&w);
    }

    // ------------------------------------------------------------------
    // Files
    // ------------------------------------------------------------------

    fn hasExtension(self: *const Server, name: []const u8) bool {
        for (self.config.extensions) |ext| {
            if (std.mem.endsWith(u8, name, ext)) return true;
        }
        return false;
    }

    /// The key zrules knows a file by: its path under a root without the
    /// extension (`lib/util`), else its name without it.
    fn keyOf(self: *const Server, a: Allocator, path_opt: ?[]const u8, uri: []const u8) ![]u8 {
        const p = path_opt orelse return a.dupe(u8, uri);
        var rel: []const u8 = std.fs.path.basename(p);
        for (self.roots.items) |root| {
            if (p.len > root.len + 1 and std.mem.startsWith(u8, p, root) and (p[root.len] == '/' or p[root.len] == '\\')) {
                rel = p[root.len + 1 ..];
                break;
            }
        }
        for (self.config.extensions) |ext| {
            if (std.mem.endsWith(u8, rel, ext)) {
                rel = rel[0 .. rel.len - ext.len];
                break;
            }
        }
        const key = try a.dupe(u8, rel);
        for (key) |*c| {
            if (c.* == '\\') c.* = '/';
        }
        return key;
    }

    fn scanWorkspace(self: *Server, root: []const u8) !void {
        if (self.config.extensions.len == 0) return;
        var dir = try std.Io.Dir.openDirAbsolute(self.io, root, .{ .iterate = true });
        defer dir.close(self.io);
        var walker = try dir.walkSelectively(self.gpa);
        defer walker.deinit();
        var count: usize = 0;
        while (try walker.next(self.io)) |entry| {
            switch (entry.kind) {
                .directory => {
                    const skip = entry.basename[0] == '.' or
                        std.mem.eql(u8, entry.basename, "node_modules") or
                        std.mem.eql(u8, entry.basename, "__pycache__") or
                        std.mem.eql(u8, entry.basename, "zig-cache") or
                        std.mem.eql(u8, entry.basename, "zig-out");
                    if (!skip) walker.enter(self.io, entry) catch {};
                },
                .file => {
                    if (!self.hasExtension(entry.basename)) continue;
                    if (count >= MAX_WORKSPACE_FILES) return;
                    count += 1;
                    const text = entry.dir.readFileAlloc(self.io, entry.basename, self.gpa, .limited(MAX_FILE_SIZE)) catch continue;
                    defer self.gpa.free(text);
                    const full = try std.fs.path.join(self.gpa, &.{ root, entry.path });
                    defer self.gpa.free(full);
                    try self.addDiskFile(full, text);
                },
                else => {},
            }
        }
    }

    fn addDiskFile(self: *Server, path: []const u8, text: []const u8) !void {
        const u = try uri_mod.fromPath(self.gpa, path);
        defer self.gpa.free(u);
        const key = try self.keyOf(self.gpa, path, u);
        defer self.gpa.free(key);
        _ = try self.project.add(u, path, key, text);
    }

    fn openFile(self: *Server, uri: []const u8, text: []const u8, version: i64) !void {
        if (self.project.get(uri)) |f| {
            // (a file found on disk: sent as the client spells it from now
            // on; what was published under the other spelling is cleared)
            if (!std.mem.eql(u8, f.uri, uri)) {
                if (f.published) |p| {
                    try self.publish(f.uri, null, &.{}, &f.doc);
                    self.gpa.free(p);
                    f.published = null;
                }
                try self.project.rename(f, uri);
            }
            try f.doc.setText(text);
            f.doc.version = version;
            f.open = true;
            self.project.touched(f);
            return;
        }
        const p = try uri_mod.toPath(self.gpa, uri);
        defer if (p) |x| self.gpa.free(x);
        const key = try self.keyOf(self.gpa, p, uri);
        defer self.gpa.free(key);
        const f = try self.project.add(uri, p, key, text);
        f.doc.version = version;
        f.open = true;
    }

    fn didChange(self: *Server, params: ?Value) !void {
        const td = json.get(params, "textDocument");
        const u = json.getString(td, "uri") orelse return;
        const f = self.project.get(u) orelse return;
        for (json.getArray(params, "contentChanges") orelse &.{}) |change| {
            const text = json.getString(change, "text") orelse continue;
            if (json.get(change, "range")) |range| {
                const start = readPosition(json.get(range, "start")) orelse continue;
                const end = readPosition(json.get(range, "end")) orelse continue;
                try f.doc.edit(start, end, text, self.encoding);
            } else try f.doc.setText(text);
        }
        if (json.getInt(td, "version")) |v| f.doc.version = v;
        self.project.touched(f);
    }

    /// Closed in the editor: back to the file on disk if it's one of the
    /// workspace's, else forgotten (and its diagnostics cleared).
    fn closeFile(self: *Server, uri: []const u8) !void {
        const f = self.project.get(uri) orelse return;
        f.open = false;
        if (f.path) |p| {
            if (self.hasExtension(p) and self.underRoot(p)) {
                const text = std.Io.Dir.cwd().readFileAlloc(self.io, p, self.gpa, .limited(MAX_FILE_SIZE)) catch null;
                if (text) |t| {
                    defer self.gpa.free(t);
                    try f.doc.setText(t);
                    self.project.touched(f);
                    return;
                }
            }
        }
        try self.forget(uri);
    }

    fn underRoot(self: *const Server, path: []const u8) bool {
        for (self.roots.items) |root| {
            if (std.mem.startsWith(u8, path, root)) return true;
        }
        return false;
    }

    fn forget(self: *Server, uri: []const u8) !void {
        const f = self.project.get(uri) orelse return;
        if (f.published != null) try self.publish(uri, null, &.{}, &f.doc);
        self.project.remove(uri);
    }

    /// A file changed on disk (1 created, 2 changed, 3 deleted).
    fn watchedChange(self: *Server, uri: []const u8, kind: i64) !void {
        if (self.project.get(uri)) |f| {
            if (f.open) return; // the buffer is the truth
        }
        if (kind == 3) return self.forget(uri);
        const p = (try uri_mod.toPath(self.gpa, uri)) orelse return;
        defer self.gpa.free(p);
        if (!self.hasExtension(p)) return;
        const text = std.Io.Dir.cwd().readFileAlloc(self.io, p, self.gpa, .limited(MAX_FILE_SIZE)) catch return;
        defer self.gpa.free(text);
        if (self.project.get(uri)) |f| {
            try f.doc.setText(text);
            self.project.touched(f);
        } else try self.addDiskFile(p, text);
    }

    // ------------------------------------------------------------------
    // Diagnostics
    // ------------------------------------------------------------------

    fn publishAll(self: *Server) !void {
        for (self.project.files.values()) |f| {
            const a = f.analysis orelse continue;
            try self.publish(f.uri, f, a.diags, &f.doc);
        }
    }

    /// Publish `diags` for `uri`, unless they are what was published last.
    fn publish(self: *Server, uri: []const u8, file: ?*File, diags: []const project_mod.Diag, doc: *const Document) !void {
        var w = json.Writer.init(self.gpa);
        defer w.deinit();
        try w.beginArray();
        for (diags) |d| {
            try w.beginObject();
            try w.key("range");
            try self.writeRange(&w, doc, d.span);
            try w.fieldInt("severity", d.severity);
            if (d.code.len != 0) try w.fieldString("code", d.code);
            try w.fieldString("source", self.config.name);
            try w.fieldString("message", d.message);
            if (d.notes.len != 0 and self.client.related_information) {
                try w.key("relatedInformation");
                try w.beginArray();
                for (d.notes) |note| {
                    try w.beginObject();
                    try w.key("location");
                    try w.beginObject();
                    try w.fieldString("uri", uri);
                    try w.key("range");
                    try self.writeRange(&w, doc, note.span);
                    try w.endObject();
                    try w.fieldString("message", note.message);
                    try w.endObject();
                }
                try w.endArray();
            }
            try w.endObject();
        }
        try w.endArray();
        if (file) |f| {
            if (f.published) |prev| {
                if (std.mem.eql(u8, prev, w.out.items)) return;
                self.gpa.free(prev);
                f.published = null;
            }
            f.published = try self.gpa.dupe(u8, w.out.items);
        }

        var m = json.Writer.init(self.gpa);
        defer m.deinit();
        try m.beginObject();
        try m.fieldString("jsonrpc", "2.0");
        try m.fieldString("method", "textDocument/publishDiagnostics");
        try m.key("params");
        try m.beginObject();
        try m.fieldString("uri", uri);
        if (file) |f| {
            if (f.open) try m.fieldInt("version", f.doc.version);
        }
        try m.key("diagnostics");
        try m.raw(w.out.items);
        try m.endObject();
        try m.endObject();
        try self.send(&m);
    }

    // ------------------------------------------------------------------
    // Features: shared
    // ------------------------------------------------------------------

    /// The file a request is about, analyzed; null if unknown.
    fn target(self: *Server, params: ?Value) !?*File {
        const u = json.getString(json.get(params, "textDocument"), "uri") orelse return error.InvalidParams;
        const f = self.project.get(u) orelse return null;
        try self.analyze();
        if (f.analysis == null) return null;
        return f;
    }

    fn offsetIn(self: *const Server, f: *const File, params: ?Value) !u32 {
        const pos = readPosition(json.get(params, "position")) orelse return error.InvalidParams;
        return f.doc.offsetOf(pos, self.encoding);
    }

    /// A symbol's definition: its own, or (for an imported name) the one
    /// in the file it comes from.
    const Definition = struct { file: *File, sym: *const Sym };

    fn definitionOf(self: *Server, f: *File, s: *const Sym) ?Definition {
        if (s.origin_key) |key| {
            const other = self.project.byKey(key) orelse return null;
            const a = other.analysis orelse return null;
            for (a.syms) |*o| {
                if (o.def_node == s.origin_node and o.def != null) return .{ .file = other, .sym = o };
            }
            return null;
        }
        if (s.def == null) return null;
        return .{ .file = f, .sym = s };
    }

    /// Every occurrence of the definition `d` in the project: (file, span,
    /// is a definition). Imports of it count, with their uses.
    fn occurrences(self: *Server, a: Allocator, d: Definition) ![]const Occurrence {
        var out: std.ArrayList(Occurrence) = .empty;
        try out.append(a, .{ .file = d.file, .span = d.sym.def.?, .def = true });
        for (d.sym.uses) |u| try out.append(a, .{ .file = d.file, .span = u, .def = false });
        for (self.project.files.values()) |f| {
            const an = f.analysis orelse continue;
            for (an.syms) |*s| {
                const key = s.origin_key orelse continue;
                if (s.origin_node != d.sym.def_node or !std.mem.eql(u8, key, d.file.key)) continue;
                if (s.def) |sd| try out.append(a, .{ .file = f, .span = sd, .def = true });
                for (s.uses) |u| try out.append(a, .{ .file = f, .span = u, .def = false });
            }
        }
        return out.items;
    }

    const Occurrence = struct { file: *File, span: Span, def: bool };

    /// The symbol at the request's position, with its file.
    fn symbolAtRequest(self: *Server, params: ?Value) !?struct { file: *File, sym: *const Sym, offset: u32 } {
        const f = (try self.target(params)) orelse return null;
        const offset = try self.offsetIn(f, params);
        const s = f.analysis.?.symbolAt(offset) orelse return null;
        return .{ .file = f, .sym = s, .offset = offset };
    }

    /// The kind a symbol shows as: configured for its defining node, else
    /// taken from its definition (an imported name), else guessed from
    /// its type.
    fn kindOf(self: *Server, f: *File, s: *const Sym) lsp.Kind {
        if (s.kind) |k| return k;
        if (s.origin_key != null) {
            if (self.definitionOf(f, s)) |d| {
                if (d.sym.kind) |k| return k;
            }
        }
        if (s.type_text) |t| {
            if (std.mem.startsWith(u8, t, "fn(")) return .function;
            if (std.mem.startsWith(u8, t, "type[")) return .type;
        }
        return .variable;
    }

    // ------------------------------------------------------------------
    // Features
    // ------------------------------------------------------------------

    fn definition(self: *Server, a: Allocator, w: *json.Writer, params: ?Value) !void {
        _ = a;
        const at = (try self.symbolAtRequest(params)) orelse return w.null_();
        const d = self.definitionOf(at.file, at.sym) orelse return w.null_();
        try self.writeLocation(w, d.file, d.sym.def.?);
    }

    fn references(self: *Server, a: Allocator, w: *json.Writer, params: ?Value) !void {
        const at = (try self.symbolAtRequest(params)) orelse return w.null_();
        const d = self.definitionOf(at.file, at.sym) orelse return w.null_();
        const include_decl = json.getBool(json.get(params, "context"), "includeDeclaration") orelse true;
        try w.beginArray();
        for (try self.occurrences(a, d)) |o| {
            if (o.def and !include_decl) continue;
            try self.writeLocation(w, o.file, o.span);
        }
        try w.endArray();
    }

    fn documentHighlight(self: *Server, a: Allocator, w: *json.Writer, params: ?Value) !void {
        _ = a;
        const at = (try self.symbolAtRequest(params)) orelse return w.null_();
        const s = at.sym;
        try w.beginArray();
        if (s.def) |d| {
            try w.beginObject();
            try w.key("range");
            try self.writeRange(w, &at.file.doc, d);
            try w.fieldInt("kind", 3);
            try w.endObject();
        }
        for (s.uses) |u| {
            try w.beginObject();
            try w.key("range");
            try self.writeRange(w, &at.file.doc, u);
            try w.fieldInt("kind", 2);
            try w.endObject();
        }
        try w.endArray();
    }

    fn prepareRename(self: *Server, a: Allocator, w: *json.Writer, params: ?Value) !void {
        _ = a;
        const at = (try self.symbolAtRequest(params)) orelse return w.null_();
        if (at.sym.builtin or self.definitionOf(at.file, at.sym) == null) return w.null_();
        // The occurrence under the cursor
        var span = at.sym.def orelse Span{ .start = 0, .end = 0 };
        if (at.sym.def == null or !span.contains(at.offset)) {
            for (at.sym.uses) |u| {
                if (u.contains(at.offset)) span = u;
            }
        }
        try w.beginObject();
        try w.key("range");
        try self.writeRange(w, &at.file.doc, span);
        try w.fieldString("placeholder", at.sym.name);
        try w.endObject();
    }

    fn rename(self: *Server, a: Allocator, w: *json.Writer, params: ?Value) !void {
        const new_name = json.getString(params, "newName") orelse return error.InvalidParams;
        const at = (try self.symbolAtRequest(params)) orelse return w.null_();
        if (at.sym.builtin) return w.null_();
        const d = self.definitionOf(at.file, at.sym) orelse return w.null_();
        const occ = try self.occurrences(a, d);
        try w.beginObject();
        try w.key("changes");
        try w.beginObject();
        for (self.project.files.values()) |f| {
            var any = false;
            for (occ) |o| {
                if (o.file != f) continue;
                if (!any) {
                    try w.key(f.uri);
                    try w.beginArray();
                    any = true;
                }
                try w.beginObject();
                try w.key("range");
                try self.writeRange(w, &f.doc, o.span);
                try w.fieldString("newText", new_name);
                try w.endObject();
            }
            if (any) try w.endArray();
        }
        try w.endObject();
        try w.endObject();
    }

    fn hover(self: *Server, a: Allocator, w: *json.Writer, params: ?Value) !void {
        const at = (try self.symbolAtRequest(params)) orelse return w.null_();
        const s = at.sym;
        const kind = self.kindOf(at.file, s);
        var text: std.ArrayList(u8) = .empty;
        try text.appendSlice(a, "```");
        try text.appendSlice(a, self.config.name);
        try text.append(a, '\n');
        try text.appendSlice(a, if (s.builtin) "(builtin) " else "");
        try text.appendSlice(a, @tagName(kind));
        try text.append(a, ' ');
        try text.appendSlice(a, s.name);
        if (s.type_text) |t| {
            try text.appendSlice(a, ": ");
            try text.appendSlice(a, t);
        }
        try text.appendSlice(a, "\n```");
        if (s.origin_key) |key| {
            try text.appendSlice(a, "\n\nfrom `");
            try text.appendSlice(a, key);
            try text.append(a, '`');
        }
        var span = s.def orelse Span{ .start = at.offset, .end = at.offset };
        if (!span.contains(at.offset)) {
            for (s.uses) |u| {
                if (u.contains(at.offset)) span = u;
            }
        }
        try w.beginObject();
        try w.key("contents");
        try w.beginObject();
        try w.fieldString("kind", "markdown");
        try w.fieldString("value", text.items);
        try w.endObject();
        try w.key("range");
        try self.writeRange(w, &at.file.doc, span);
        try w.endObject();
    }

    /// The definitions a file's outline shows: its own (not builtins or
    /// imports), those of a configured kind when kinds are configured.
    fn outlined(self: *const Server, s: *const Sym) bool {
        if (s.builtin or s.def == null or s.origin_key != null) return false;
        return self.config.symbol_rules.len == 0 or s.kind != null;
    }

    /// The range an outline entry covers: the construct its name defines
    /// (the defining node's parent), unless that is the whole file.
    fn outlineRange(an: *const Analysis, s: *const Sym) Span {
        const def = s.def.?;
        if (s.def_node == NONE or s.def_node >= an.parents.len) return def;
        const parent = an.parents[s.def_node];
        if (parent == NONE or parent == 0) return def;
        return an.nodeSpan(parent);
    }

    fn documentSymbol(self: *Server, a: Allocator, w: *json.Writer, params: ?Value) !void {
        const f = (try self.target(params)) orelse return w.null_();
        const an = f.analysis.?;
        const Entry = struct { sym: *const Sym, range: Span };
        var entries: std.ArrayList(Entry) = .empty;
        for (an.syms) |*s| {
            if (self.outlined(s)) try entries.append(a, .{ .sym = s, .range = outlineRange(an, s) });
        }
        std.sort.pdq(Entry, entries.items, {}, struct {
            fn lt(_: void, x: Entry, y: Entry) bool {
                return if (x.range.start != y.range.start) x.range.start < y.range.start else x.range.end > y.range.end;
            }
        }.lt);

        try w.beginArray();
        if (!self.client.hierarchical_symbols) {
            for (entries.items) |e| {
                try w.beginObject();
                try w.fieldString("name", e.sym.name);
                try w.fieldInt("kind", self.kindOf(f, e.sym).symbolKind());
                try w.key("location");
                try self.writeLocation(w, f, e.range);
                try w.endObject();
            }
        } else {
            // Nested by containment: a stack of the open entries' ends
            var stack: std.ArrayList(u32) = .empty;
            for (entries.items) |e| {
                while (stack.items.len > 0 and e.range.start >= stack.items[stack.items.len - 1]) {
                    _ = stack.pop();
                    try w.endArray();
                    try w.endObject();
                }
                try w.beginObject();
                try w.fieldString("name", e.sym.name);
                if (e.sym.type_text) |t| try w.fieldString("detail", t);
                try w.fieldInt("kind", self.kindOf(f, e.sym).symbolKind());
                try w.key("range");
                try self.writeRange(w, &f.doc, e.range);
                try w.key("selectionRange");
                try self.writeRange(w, &f.doc, e.sym.def.?);
                try w.key("children");
                try w.beginArray();
                try stack.append(a, @max(e.range.end, e.range.start + 1));
            }
            while (stack.items.len > 0) {
                _ = stack.pop();
                try w.endArray();
                try w.endObject();
            }
        }
        try w.endArray();
    }

    fn workspaceSymbol(self: *Server, a: Allocator, w: *json.Writer, params: ?Value) !void {
        const query = json.getString(params, "query") orelse "";
        try self.analyze();
        try w.beginArray();
        var count: usize = 0;
        for (self.project.files.values()) |f| {
            const an = f.analysis orelse continue;
            for (an.syms) |*s| {
                if (!self.outlined(s)) continue;
                if (query.len != 0 and !containsIgnoreCase(s.name, query)) continue;
                try w.beginObject();
                try w.fieldString("name", s.name);
                try w.fieldInt("kind", self.kindOf(f, s).symbolKind());
                try w.key("location");
                try self.writeLocation(w, f, s.def.?);
                try w.fieldString("containerName", f.key);
                try w.endObject();
                count += 1;
                if (count >= 1000) break;
            }
        }
        _ = a;
        try w.endArray();
    }

    fn foldingRange(self: *Server, a: Allocator, w: *json.Writer, params: ?Value) !void {
        const f = (try self.target(params)) orelse return w.null_();
        const an = f.analysis.?;
        const doc = &f.doc;
        const Fold = struct { start: u32, end: u32, comment: bool };
        var folds: std.ArrayList(Fold) = .empty;

        const addNode = struct {
            fn run(list: *std.ArrayList(Fold), alloc: Allocator, d: *const Document, text: []const u8, span: Span) !void {
                if (span.end <= span.start) return;
                const first = d.positionOf(span.start, .utf8).line;
                var last = d.positionOf(span.end - 1, .utf8).line;
                if (last <= first) return;
                // A last line that only closes (`}`, `end`) stays visible
                const line_start = d.lines.items[last];
                if (std.mem.trim(u8, text[line_start..span.end], " \t\r\n").len <= 3) last -= 1;
                if (last > first) try list.append(alloc, .{ .start = first, .end = last, .comment = false });
            }
        }.run;

        if (an.fold_nodes) |nodes| {
            for (nodes) |n| try addNode(&folds, a, doc, an.text, an.nodeSpan(n));
        } else {
            // Every multi-line node with children, but the root
            for (an.nodes, 0..) |n, i| {
                if (i == 0 or n.subtree_size == 0) continue;
                try addNode(&folds, a, doc, an.text, .{ .start = n.text_start, .end = n.text_end });
            }
        }
        // Runs of line comments, and block comments
        for (try self.commentSpans(a, an)) |c| {
            const first = doc.positionOf(c.start, .utf8).line;
            const last = doc.positionOf(@max(c.end, c.start + 1) - 1, .utf8).line;
            if (folds.items.len > 0 and folds.items[folds.items.len - 1].comment and folds.items[folds.items.len - 1].end + 1 == first) {
                folds.items[folds.items.len - 1].end = last;
            } else try folds.append(a, .{ .start = first, .end = last, .comment = true });
        }

        // One fold per first line (the widest)
        std.sort.pdq(Fold, folds.items, {}, struct {
            fn lt(_: void, x: Fold, y: Fold) bool {
                return if (x.start != y.start) x.start < y.start else x.end > y.end;
            }
        }.lt);
        try w.beginArray();
        var last_start: ?u32 = null;
        for (folds.items) |fold| {
            if (fold.end <= fold.start) continue;
            if (last_start != null and last_start.? == fold.start) continue;
            last_start = fold.start;
            try w.beginObject();
            try w.fieldInt("startLine", fold.start);
            try w.fieldInt("endLine", fold.end);
            if (fold.comment) try w.fieldString("kind", "comment");
            try w.endObject();
        }
        try w.endArray();
    }

    /// Spans of the comments (line and block) in the text, outside string
    /// tokens.
    fn commentSpans(self: *const Server, a: Allocator, an: *const Analysis) ![]const Span {
        var out: std.ArrayList(Span) = .empty;
        if (self.config.line_comments.len == 0 and self.config.block_comments.len == 0) return out.items;
        // Where strings are: a comment marker inside one isn't one
        var strings: std.ArrayList(Span) = .empty;
        for (self.config.token_rules, an.token_nodes) |rule, nodes| {
            if (rule.type != .string) continue;
            for (nodes) |n| try strings.append(a, an.nodeSpan(n));
        }
        std.sort.pdq(Span, strings.items, {}, struct {
            fn lt(_: void, x: Span, y: Span) bool {
                return x.start < y.start;
            }
        }.lt);
        const text = an.text;
        var si: usize = 0;
        var i: usize = 0;
        outer: while (i < text.len) {
            while (si < strings.items.len and strings.items[si].end <= i) si += 1;
            if (si < strings.items.len and strings.items[si].start <= i) {
                i = strings.items[si].end;
                continue;
            }
            for (self.config.block_comments) |pair| {
                if (!std.mem.startsWith(u8, text[i..], pair[0])) continue;
                const close = std.mem.indexOfPos(u8, text, i + pair[0].len, pair[1]);
                const end = if (close) |c| c + pair[1].len else text.len;
                try out.append(a, .{ .start = @intCast(i), .end = @intCast(end) });
                i = end;
                continue :outer;
            }
            for (self.config.line_comments) |marker| {
                if (!std.mem.startsWith(u8, text[i..], marker)) continue;
                var end = i;
                while (end < text.len and text[end] != '\n' and text[end] != '\r') end += 1;
                try out.append(a, .{ .start = @intCast(i), .end = @intCast(end) });
                i = end;
                continue :outer;
            }
            i += 1;
        }
        return out.items;
    }

    fn semanticTokens(self: *Server, a: Allocator, w: *json.Writer, params: ?Value) !void {
        const f = (try self.target(params)) orelse return w.null_();
        const an = f.analysis.?;
        const text = an.text;
        const Tok = struct { start: u32, end: u32, type: lsp.TokenType, mods: u32 };
        var toks: std.ArrayList(Tok) = .empty;
        // Each byte of the text belongs to at most one token: taken in
        // priority order (comments, strings, names, the other token rules,
        // keywords), a token overlapping one already taken is dropped
        const taken = try a.alloc(bool, text.len + 1);
        @memset(taken, false);
        const take = struct {
            fn run(list: *std.ArrayList(Tok), alloc: Allocator, owned: []bool, t: Tok) !void {
                if (t.end <= t.start or t.end > owned.len) return;
                for (owned[t.start..t.end]) |b| if (b) return;
                @memset(owned[t.start..t.end], true);
                try list.append(alloc, t);
            }
        }.run;

        for (try self.commentSpans(a, an)) |c| try take(&toks, a, taken, .{ .start = c.start, .end = c.end, .type = .comment, .mods = 0 });
        for (self.config.token_rules, an.token_nodes) |rule, nodes| {
            if (rule.type != .string) continue;
            for (nodes) |n| {
                const s = an.nodeSpan(n);
                try take(&toks, a, taken, .{ .start = s.start, .end = s.end, .type = .string, .mods = 0 });
            }
        }
        const declaration: u32 = 1 << @intFromEnum(lsp.Modifier.declaration);
        const library: u32 = 1 << @intFromEnum(lsp.Modifier.defaultLibrary);
        for (an.syms) |*s| {
            const t = self.kindOf(f, s).tokenType();
            const mods: u32 = if (s.builtin) library else 0;
            if (s.def) |d| try take(&toks, a, taken, .{ .start = d.start, .end = d.end, .type = t, .mods = mods | (if (s.origin_key == null) declaration else 0) });
            for (s.uses) |u| try take(&toks, a, taken, .{ .start = u.start, .end = u.end, .type = t, .mods = mods });
        }
        for (self.config.token_rules, an.token_nodes) |rule, nodes| {
            if (rule.type == .string) continue;
            for (nodes) |n| {
                const s = an.nodeSpan(n);
                try take(&toks, a, taken, .{ .start = s.start, .end = s.end, .type = rule.type, .mods = 0 });
            }
        }
        // Keywords: the grammar's words, wherever nothing else is
        if (self.keywords.count() != 0) {
            var i: usize = 0;
            while (i < text.len) {
                if (!isWordStart(text[i])) {
                    i += 1;
                    continue;
                }
                var end = i + 1;
                while (end < text.len and isWordChar(text[end])) end += 1;
                if (self.keywords.contains(text[i..end])) try take(&toks, a, taken, .{ .start = @intCast(i), .end = @intCast(end), .type = .keyword, .mods = 0 });
                i = end;
            }
        }

        std.sort.pdq(Tok, toks.items, {}, struct {
            fn lt(_: void, x: Tok, y: Tok) bool {
                return x.start < y.start;
            }
        }.lt);

        // Relative encoding, a token per line unless the client takes
        // multi-line ones
        const doc = &f.doc;
        var data: std.ArrayList(u32) = .empty;
        var prev_line: u32 = 0;
        var prev_char: u32 = 0;
        for (toks.items) |t| {
            var start = t.start;
            while (start < t.end) {
                const p = doc.positionOf(start, self.encoding);
                var piece_end = t.end;
                if (!self.client.multiline_tokens and p.line + 1 < doc.lines.items.len) {
                    const next_line = doc.lines.items[p.line + 1];
                    if (next_line < t.end) {
                        piece_end = next_line;
                        // (not the line break itself)
                        while (piece_end > start and (text[piece_end - 1] == '\n' or text[piece_end - 1] == '\r')) piece_end -= 1;
                    }
                }
                const length = switch (self.encoding) {
                    .utf8 => piece_end - start,
                    .utf16 => document.byteToUtf16(text[start..piece_end]),
                };
                if (length > 0) {
                    const delta_line = p.line - prev_line;
                    const delta_char = if (delta_line == 0) p.character - prev_char else p.character;
                    try data.appendSlice(a, &.{ delta_line, delta_char, length, @intFromEnum(t.type), t.mods });
                    prev_line = p.line;
                    prev_char = p.character;
                }
                if (piece_end == t.end) break;
                start = doc.lines.items[p.line + 1];
            }
        }
        try w.beginObject();
        try w.key("data");
        try w.beginArray();
        for (data.items) |v| try w.int(v);
        try w.endArray();
        try w.endObject();
    }

    fn completion(self: *Server, a: Allocator, w: *json.Writer, params: ?Value) !void {
        const f = (try self.target(params)) orelse return w.null_();
        const an = f.analysis.?;
        const offset = try self.offsetIn(f, params);
        const text = an.text;
        // The word being typed, and what's before it
        var start = offset;
        while (start > 0 and isWordChar(text[start - 1])) start -= 1;
        var seen: std.StringHashMapUnmanaged(void) = .empty;

        try w.beginObject();
        try w.fieldBool("isIncomplete", false);
        try w.key("items");
        try w.beginArray();

        // After `a.b.`: the members of what the chain names
        if (start > 0 and text[start - 1] == '.') {
            if (try self.chainScope(a, f, an, start - 1)) |scope| {
                for (scope.file.analysis.?.syms) |*m| {
                    if (m.scope != scope.node or m.builtin) continue;
                    try self.completionItem(a, w, &seen, scope.file, m, "0");
                }
            }
            try w.endArray();
            try w.endObject();
            return;
        }

        // The names visible here, innermost first
        if (an.checked) |checked| {
            const list = py.c.PyObject_CallMethod(checked, "visible", "L", @as(c_longlong, start)) orelse return error.Python;
            defer py.Py_DecRef(list);
            const n: usize = @intCast(py.c.PyList_Size(list));
            // The native copies, by defining node (builtins by name), for
            // their kinds and types
            var by_node: std.AutoHashMapUnmanaged(u32, *const Sym) = .empty;
            var builtins: std.StringHashMapUnmanaged(*const Sym) = .empty;
            for (an.syms) |*s| {
                if (s.def_node != NONE) try by_node.put(a, s.def_node, s) else try builtins.put(a, s.name, s);
            }
            for (0..n) |i| {
                const sym_obj = py.c.PyList_GetItem(list, @intCast(i));
                const node = try ph.attrInt(sym_obj, "node");
                const name = (try ph.attrString(a, sym_obj, "name")) orelse continue;
                const native: ?*const Sym = if (node) |d| by_node.get(@intCast(d)) else builtins.get(name);
                var order_buf: [8]u8 = undefined;
                const order = std.fmt.bufPrint(&order_buf, "{d}", .{@min(i, 9999999)}) catch "9";
                if (native) |s| {
                    try self.completionItem(a, w, &seen, f, s, order);
                } else if (!seen.contains(name)) {
                    try seen.put(a, name, {});
                    try w.beginObject();
                    try w.fieldString("label", name);
                    try w.fieldInt("kind", lsp.Kind.variable.completionKind());
                    try w.endObject();
                }
            }
        }
        for (self.config.keywords) |k| {
            if (seen.contains(k)) continue;
            try w.beginObject();
            try w.fieldString("label", k);
            try w.fieldInt("kind", 14);
            try w.fieldString("sortText", "~");
            try w.endObject();
        }
        try w.endArray();
        try w.endObject();
    }

    /// A symbol and the file it is in
    const Ref = struct { file: *File, sym: *const Sym };
    /// A scope node and the file it is in
    const ScopeRef = struct { file: *File, node: u32 };

    /// The scope whose members follow `a.b.` (the dot at `dot`): the names
    /// are read from the text, since what's being typed rarely parses. The
    /// first is looked up among the names visible where it's written; each
    /// next one among the members of the previous.
    fn chainScope(self: *Server, a: Allocator, f: *File, an: *const Analysis, dot: u32) !?ScopeRef {
        const text = an.text;
        var names: [16][]const u8 = undefined;
        var n: usize = 0;
        var p = dot;
        var first_at: u32 = 0;
        while (n < names.len) {
            while (p > 0 and (text[p - 1] == ' ' or text[p - 1] == '\t')) p -= 1;
            var s = p;
            while (s > 0 and isWordChar(text[s - 1])) s -= 1;
            if (s == p or !isWordStart(text[s])) return null; // not a name (a call's result, a literal)
            names[n] = text[s..p];
            n += 1;
            first_at = s;
            if (s > 0 and text[s - 1] == '.') {
                p = s - 1;
                continue;
            }
            break;
        }
        var cur = (try self.visibleNamed(a, f, an, first_at, names[n - 1])) orelse return null;
        var i = n - 1;
        while (i > 0) {
            i -= 1;
            const scope = self.scopeOf(cur) orelse return null;
            cur = self.memberNamed(scope, names[i]) orelse return null;
        }
        return self.scopeOf(cur);
    }

    /// The symbol a name written at `at` refers to, followed to its
    /// definition if imported.
    fn visibleNamed(self: *Server, a: Allocator, f: *File, an: *const Analysis, at: u32, name: []const u8) !?Ref {
        const checked = an.checked orelse return null;
        const list = py.c.PyObject_CallMethod(checked, "visible", "L", @as(c_longlong, at)) orelse return error.Python;
        defer py.Py_DecRef(list);
        const count: usize = @intCast(py.c.PyList_Size(list));
        for (0..count) |i| {
            const obj = py.c.PyList_GetItem(list, @intCast(i));
            const sym_name = (try ph.attrString(a, obj, "name")) orelse continue;
            if (!std.mem.eql(u8, sym_name, name)) continue;
            const node = (try ph.attrInt(obj, "node")) orelse return null; // a builtin: no members here
            for (an.syms) |*s| {
                if (s.def_node != @as(u32, @intCast(node))) continue;
                if (self.definitionOf(f, s)) |d| return .{ .file = d.file, .sym = d.sym };
                return .{ .file = f, .sym = s };
            }
            return null;
        }
        return null;
    }

    /// The scope whose members a symbol has: the one it names (a struct, a
    /// module), else that of its type (a variable of a struct type).
    fn scopeOf(self: *Server, r: Ref) ?ScopeRef {
        if (r.sym.owns != NONE) return .{ .file = r.file, .node = r.sym.owns };
        var t = r.sym.type_text orelse return null;
        while (t.len > 0 and t[t.len - 1] == '?') t = t[0 .. t.len - 1];
        const an = r.file.analysis orelse return null;
        for (an.syms) |*s| {
            if (!std.mem.eql(u8, s.name, t)) continue;
            const d = self.definitionOf(r.file, s) orelse continue;
            if (d.sym.owns != NONE) return .{ .file = d.file, .node = d.sym.owns };
        }
        return null;
    }

    fn memberNamed(self: *Server, scope: ScopeRef, name: []const u8) ?Ref {
        const an = scope.file.analysis orelse return null;
        for (an.syms) |*s| {
            if (s.scope != scope.node or !std.mem.eql(u8, s.name, name)) continue;
            if (self.definitionOf(scope.file, s)) |d| return .{ .file = d.file, .sym = d.sym };
            return .{ .file = scope.file, .sym = s };
        }
        return null;
    }

    fn completionItem(self: *Server, a: Allocator, w: *json.Writer, seen: *std.StringHashMapUnmanaged(void), f: *File, s: *const Sym, order: []const u8) !void {
        if (seen.contains(s.name)) return;
        try seen.put(a, s.name, {});
        try w.beginObject();
        try w.fieldString("label", s.name);
        try w.fieldInt("kind", self.kindOf(f, s).completionKind());
        if (s.type_text) |t| try w.fieldString("detail", t);
        // Locals first, builtins after
        const sort = try std.fmt.allocPrint(a, "{s}{s}", .{ if (s.builtin) "1" else "0", order });
        try w.fieldString("sortText", sort);
        try w.endObject();
    }
};

fn readPosition(v: ?Value) ?document.Position {
    const line = json.getInt(v, "line") orelse return null;
    const character = json.getInt(v, "character") orelse return null;
    if (line < 0 or character < 0) return null;
    return .{ .line = @intCast(@min(line, std.math.maxInt(u32))), .character = @intCast(@min(character, std.math.maxInt(u32))) };
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

fn isWordStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_' or c >= 0x80;
}

fn isWordChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c >= 0x80;
}
