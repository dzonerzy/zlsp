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
    /// The client's trace setting ($/setTrace): what to send as $/logTrace
    trace_level: enum { off, messages, verbose } = .off,
    /// The id of our workspace/configuration request awaiting its answer
    settings_request: ?i64 = null,
    /// For the semantic tokens' result ids
    next_result_id: u64 = 1,
    /// The log file (`log=` in Python): every message in and out, and the
    /// analyses' times; the time it was opened (ms)
    log_file: ?std.Io.File = null,
    log_start: i64 = 0,
    /// Set by the transport: is input waiting? (stops an idle analysis)
    interrupt: ?project_mod.Project.Interrupt = null,
    client: struct {
        multiline_tokens: bool = false,
        hierarchical_symbols: bool = false,
        related_information: bool = false,
        watched_files: bool = false,
        /// workspace/configuration (pulling settings), and registering for
        /// workspace/didChangeConfiguration
        configuration: bool = false,
        configuration_changes: bool = false,
    } = .{},

    pub fn init(gpa: Allocator, io: std.Io, config: *const Config) !Server {
        var s = Server{ .gpa = gpa, .io = io, .config = config, .project = .{ .gpa = gpa, .config = config } };
        for (config.keywords) |k| try s.keywords.put(gpa, k, {});
        return s;
    }

    pub fn deinit(self: *Server) void {
        if (self.log_file) |file| file.close(self.io);
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

    /// Log to the file at `path` (created, or emptied).
    pub fn openLog(self: *Server, path: []const u8) !void {
        self.log_file = try std.Io.Dir.cwd().createFile(self.io, path, .{});
        self.log_start = std.Io.Clock.awake.now(self.io).toMilliseconds();
    }

    fn micros(self: *const Server) i64 {
        return @intCast(@divTrunc(std.Io.Clock.awake.now(self.io).toNanoseconds(), 1000));
    }

    fn setTrace(self: *Server, value: ?[]const u8) void {
        const v = value orelse return;
        self.trace_level = if (std.mem.eql(u8, v, "verbose")) .verbose else if (std.mem.eql(u8, v, "messages")) .messages else .off;
    }

    /// $/logTrace, if the client traces: `message`, and `verbose` too if it
    /// traces verbosely. Also in the log file.
    fn logTrace(self: *Server, message: []const u8, verbose: ?[]const u8) !void {
        self.trace("{s}", .{message});
        if (self.trace_level == .off) return;
        var w = json.Writer.init(self.gpa);
        defer w.deinit();
        try w.beginObject();
        try w.fieldString("jsonrpc", "2.0");
        try w.fieldString("method", "$/logTrace");
        try w.key("params");
        try w.beginObject();
        try w.fieldString("message", message);
        if (self.trace_level == .verbose) {
            if (verbose) |v| try w.fieldString("verbose", v);
        }
        try w.endObject();
        try w.endObject();
        // (not through send(): its own log line would repeat the message)
        try self.out.append(self.gpa, try w.toOwned());
    }

    fn millis(self: *const Server) i64 {
        return std.Io.Clock.awake.now(self.io).toMilliseconds();
    }

    /// A line of the log, with the time since it was opened.
    fn trace(self: *Server, comptime fmt: []const u8, args: anytype) void {
        const file = self.log_file orelse return;
        const ms = self.millis() - self.log_start;
        const line = std.fmt.allocPrint(self.gpa, "[{d}.{d:0>3}] " ++ fmt ++ "\n", .{ @divTrunc(ms, 1000), @as(u64, @intCast(@mod(ms, 1000))) } ++ args) catch return;
        defer self.gpa.free(line);
        file.writeStreamingAll(self.io, line) catch {};
    }

    /// Handle one message (a JSON body).
    pub fn handle(self: *Server, body: []const u8) !void {
        self.trace("--> {s}", .{body});
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

        const m = method orelse {
            // A response to one of our requests
            const req_id = id orelse return;
            if (self.settings_request) |sid| {
                if (std.mem.eql(u8, req_id, try std.fmt.allocPrint(a, "{d}", .{sid}))) {
                    self.settings_request = null;
                    const items = json.getArray(msg, "result") orelse return;
                    if (items.len > 0) try self.applySettings(items[0]);
                }
            }
            return;
        };
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

    /// Nothing more to read for now: analyze and publish. The analysis stops
    /// between files if `interrupt` says input arrived (it goes on at the
    /// next idle, after that input).
    pub fn idle(self: *Server) !void {
        if (!self.initialized) return;
        if (try self.analyzeWith(self.interrupt) == .interrupted) return;
        try self.publishAll();
    }

    /// Bring the analysis up to date, completely (a request needs it).
    fn analyze(self: *Server) !void {
        _ = try self.analyzeWith(null);
    }

    fn analyzeWith(self: *Server, interrupt: ?project_mod.Project.Interrupt) !project_mod.Project.Outcome {
        var buf: [512]u8 = undefined;
        var len: usize = 0;
        const t0 = self.micros();
        const outcome = try self.project.analyze(&buf, &len, interrupt);
        if (outcome != .unchanged and (self.log_file != null or self.trace_level != .off)) {
            const us = self.micros() - t0;
            const msg = try std.fmt.allocPrint(self.gpa, "analysis {s} in {d}.{d:0>3} ms: {d} of {d} files checked", .{ @tagName(outcome), @divTrunc(us, 1000), @as(u64, @intCast(@mod(us, 1000))), self.project.last_checked, self.project.files.count() });
            defer self.gpa.free(msg);
            var keys: std.ArrayList(u8) = .empty;
            defer keys.deinit(self.gpa);
            if (self.trace_level == .verbose) {
                for (self.project.files.values()) |f| {
                    if (f.checked_at != self.project.analyzed) continue;
                    if (keys.items.len != 0) try keys.appendSlice(self.gpa, ", ");
                    try keys.appendSlice(self.gpa, f.key);
                }
            }
            try self.logTrace(msg, if (keys.items.len != 0) keys.items else null);
        }
        if (outcome != .failed) return outcome;
        const text = buf[0..len];
        if (self.project.last_failure) |prev| {
            if (std.mem.eql(u8, prev, text)) return outcome;
            self.gpa.free(prev);
        }
        self.project.last_failure = try self.gpa.dupe(u8, text);
        var msg: [600]u8 = undefined;
        try self.logMessage(1, std.fmt.bufPrint(&msg, "analysis failed: {s}", .{text}) catch text);
        return outcome;
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
            .{ "textDocument/semanticTokens/full/delta", semanticTokensDelta },
            .{ "textDocument/foldingRange", foldingRange },
            .{ "textDocument/completion", completion },
            .{ "textDocument/inlayHint", inlayHint },
            .{ "textDocument/typeDefinition", typeDefinition },
            .{ "textDocument/signatureHelp", signatureHelp },
            .{ "textDocument/selectionRange", selectionRange },
            .{ "textDocument/codeAction", codeAction },
            .{ "textDocument/formatting", formatting },
            .{ "workspace/symbol", workspaceSymbol },
        };
        for (table) |entry| {
            if (!std.mem.eql(u8, entry[0], method)) continue;
            const t0 = self.micros();
            defer if (self.trace_level != .off or self.log_file != null) {
                const us = self.micros() - t0;
                if (std.fmt.allocPrint(self.gpa, "{s} answered in {d}.{d:0>3} ms", .{ method, @divTrunc(us, 1000), @as(u64, @intCast(@mod(us, 1000))) })) |msg| {
                    defer self.gpa.free(msg);
                    self.logTrace(msg, null) catch {};
                } else |_| {}
            };
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
            try self.registerCapabilities();
            if (self.config.configuration_hook != null and self.client.configuration) try self.requestSettings();
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
        } else if (std.mem.eql(u8, method, "workspace/didChangeWorkspaceFolders")) {
            const event = json.get(params, "event");
            for (json.getArray(event, "removed") orelse &.{}) |folder| {
                const u = json.getString(folder, "uri") orelse continue;
                try self.removeRoot(u);
            }
            for (json.getArray(event, "added") orelse &.{}) |folder| {
                const u = json.getString(folder, "uri") orelse continue;
                const p = (try uri_mod.toPath(self.gpa, u)) orelse continue;
                try self.roots.append(self.gpa, p);
                self.scanWorkspace(p) catch {};
            }
        } else if (std.mem.eql(u8, method, "workspace/didChangeConfiguration")) {
            try self.configurationChanged(params);
        } else if (std.mem.eql(u8, method, "$/setTrace")) {
            self.setTrace(json.getString(params, "value"));
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
        self.trace("<-- {s}", .{body});
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
        self.setTrace(json.getString(params, "trace"));
        self.client.configuration = json.getBool(json.get(caps, "workspace"), "configuration") orelse false;
        self.client.configuration_changes = json.getBool(json.path(caps, &.{ "workspace", "didChangeConfiguration" }), "dynamicRegistration") orelse false;

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
        try w.fieldBool("inlayHintProvider", true);
        try w.fieldBool("typeDefinitionProvider", true);
        try w.fieldBool("selectionRangeProvider", true);
        try w.key("codeActionProvider");
        try w.beginObject();
        try w.key("codeActionKinds");
        try w.beginArray();
        try w.string("quickfix");
        try w.endArray();
        try w.endObject();
        if (self.config.format_hook != null) try w.fieldBool("documentFormattingProvider", true);
        try w.key("signatureHelpProvider");
        try w.beginObject();
        try w.key("triggerCharacters");
        try w.beginArray();
        try w.string("(");
        try w.string(",");
        try w.endArray();
        try w.key("retriggerCharacters");
        try w.beginArray();
        try w.string(")");
        try w.endArray();
        try w.endObject();
        try w.key("completionProvider");
        try w.beginObject();
        try w.key("triggerCharacters");
        try w.beginArray();
        try w.string(".");
        try w.endArray();
        try w.endObject();
        try w.key("workspace");
        try w.beginObject();
        try w.key("workspaceFolders");
        try w.beginObject();
        try w.fieldBool("supported", true);
        try w.fieldBool("changeNotifications", true);
        try w.endObject();
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
        try w.key("full");
        try w.beginObject();
        try w.fieldBool("delta", true);
        try w.endObject();
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
    /// disk (workspace/didChangeWatchedFiles) and, for the `configuration`
    /// hook, to its settings (workspace/didChangeConfiguration).
    fn registerCapabilities(self: *Server) !void {
        const watch = self.client.watched_files and self.config.extensions.len != 0;
        const settings = self.client.configuration_changes and self.config.configuration_hook != null;
        if (!watch and !settings) return;
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
        if (settings) {
            try w.beginObject();
            try w.fieldString("id", "zlsp-settings");
            try w.fieldString("method", "workspace/didChangeConfiguration");
            try w.key("registerOptions");
            try w.beginObject();
            try w.fieldString("section", self.config.section);
            try w.endObject();
            try w.endObject();
        }
        if (watch) {
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
        }
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

    /// The key zrules knows a new file by (allocated in `a`): its path under
    /// its workspace folder without the extension (`lib/util`), else its
    /// name without it. Unique: if another file has it (the same path under
    /// two workspace folders), it is prefixed with its folder's name
    /// (`client/lib/util`), then numbered.
    fn keyOf(self: *Server, a: Allocator, path_opt: ?[]const u8, uri: []const u8) !Project.Key {
        const p = path_opt orelse {
            const k = try a.dupe(u8, uri);
            return .{ .key = k, .rel = k, .folder = "" };
        };
        var rel: []const u8 = std.fs.path.basename(p);
        var folder: []const u8 = "";
        for (self.roots.items) |root| {
            if (isUnder(p, root)) {
                rel = std.mem.trimStart(u8, p[root.len..], "/\\");
                folder = root;
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
        const out = Project.Key{ .key = key, .rel = key, .folder = folder };
        if (self.project.byKey(key) == null) return out;
        const folder_name = std.fs.path.basename(std.mem.trimEnd(u8, folder, "/\\"));
        if (folder_name.len != 0) {
            const prefixed = try std.fmt.allocPrint(a, "{s}/{s}", .{ folder_name, key });
            if (self.project.byKey(prefixed) == null) return .{ .key = prefixed, .rel = key, .folder = folder };
        }
        var n: usize = 2;
        while (true) : (n += 1) {
            const numbered = try std.fmt.allocPrint(a, "{s}#{d}", .{ key, n });
            if (self.project.byKey(numbered) == null) return .{ .key = numbered, .rel = key, .folder = folder };
        }
    }

    /// A workspace folder closed: its files go, except those open.
    fn removeRoot(self: *Server, uri: []const u8) !void {
        const root = (try uri_mod.toPath(self.gpa, uri)) orelse return;
        defer self.gpa.free(root);
        for (self.roots.items, 0..) |r, i| {
            if (!std.mem.eql(u8, r, root)) continue;
            self.gpa.free(self.roots.orderedRemove(i));
            break;
        }
        var gone: std.ArrayList([]u8) = .empty;
        defer {
            for (gone.items) |u| self.gpa.free(u);
            gone.deinit(self.gpa);
        }
        for (self.project.files.values()) |f| {
            const p = f.path orelse continue;
            if (f.open or !isUnder(p, root)) continue;
            try gone.append(self.gpa, try self.gpa.dupe(u8, f.uri));
        }
        for (gone.items) |u| try self.forget(u);
    }

    /// workspace/didChangeConfiguration. A client that answers
    /// workspace/configuration is asked for the settings (it may send none
    /// here); else they are these: the section's, if they have it.
    fn configurationChanged(self: *Server, params: ?Value) !void {
        if (self.config.configuration_hook == null) return;
        if (self.client.configuration) return self.requestSettings();
        const settings = json.get(params, "settings") orelse return;
        if (settings == .null) return;
        try self.applySettings(json.get(settings, self.config.section) orelse settings);
    }

    /// Ask the client for the settings of the section.
    fn requestSettings(self: *Server) !void {
        var w = json.Writer.init(self.gpa);
        defer w.deinit();
        try w.beginObject();
        try w.fieldString("jsonrpc", "2.0");
        try w.fieldInt("id", self.next_request_id);
        self.settings_request = self.next_request_id;
        self.next_request_id += 1;
        try w.fieldString("method", "workspace/configuration");
        try w.key("params");
        try w.beginObject();
        try w.key("items");
        try w.beginArray();
        try w.beginObject();
        try w.fieldString("section", self.config.section);
        try w.endObject();
        try w.endArray();
        try w.endObject();
        try w.endObject();
        try self.send(&w);
    }

    /// The settings go to the `configuration` hook (null: None), and the
    /// project is checked again (the hook may change what the rules do).
    fn applySettings(self: *Server, settings: Value) !void {
        const hook = self.config.configuration_hook orelse return;
        const text = try std.json.Stringify.valueAlloc(self.gpa, settings, .{});
        defer self.gpa.free(text);
        const result = try self.callHook("configuration", hook, &.{jsonToPython(text)});
        if (result) |r| py.Py_DecRef(r);
        self.project.structure_gen += 1;
        self.project.generation += 1;
    }

    /// Call a feature hook with `(uri, text, *extra, analysis)` (the zrules
    /// Analysis, or None); its result, null for None or if it raised (then
    /// logged). Takes the `extra` references.
    fn callFileHook(self: *Server, a: Allocator, name: []const u8, hook: *PyObject, f: *File, extra: []const ?*PyObject) !?*PyObject {
        const args = try a.alloc(?*PyObject, extra.len + 3);
        args[0] = ph.newString(f.uri);
        args[1] = ph.newString(f.doc.text.items);
        @memcpy(args[2 .. 2 + extra.len], extra);
        const checked: *PyObject = if (f.analysis) |an| an.checked orelse py.Py_None() else py.Py_None();
        py.Py_IncRef(checked);
        args[args.len - 1] = checked;
        return self.callHook(name, hook, args);
    }

    /// Call a hook with `args` (taking the references; a null one means
    /// creating it raised); null for None or if it raised (then logged).
    fn callHook(self: *Server, name: []const u8, hook: *PyObject, args: []const ?*PyObject) !?*PyObject {
        defer for (args) |o| if (o) |x| py.Py_DecRef(x);
        for (args) |o| if (o == null) {
            try self.hookFailed(name);
            return null;
        };
        const tuple = py.c.PyTuple_New(@intCast(args.len)) orelse {
            try self.hookFailed(name);
            return null;
        };
        defer py.Py_DecRef(tuple);
        for (args, 0..) |o, i| {
            py.Py_IncRef(o.?);
            _ = py.c.PyTuple_SetItem(tuple, @intCast(i), o.?);
        }
        const result = py.c.PyObject_Call(hook, tuple, null) orelse {
            try self.hookFailed(name);
            return null;
        };
        if (result == py.Py_None()) {
            py.Py_DecRef(result);
            return null;
        }
        return result;
    }

    /// A hook raised: the editor gets the error in its log.
    fn hookFailed(self: *Server, name: []const u8) !void {
        var buf: [512]u8 = undefined;
        const text = ph.takeError(&buf);
        var msg: [600]u8 = undefined;
        try self.logMessage(1, std.fmt.bufPrint(&msg, "the {s} hook failed: {s}", .{ name, text }) catch text);
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
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        _ = try self.project.add(u, path, try self.keyOf(arena.allocator(), path, u), text);
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
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const f = try self.project.add(uri, p, try self.keyOf(arena.allocator(), p, uri), text);
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
            if (isUnder(path, root)) return true;
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
        // Without a type (no types() rule, a builtin): a name only ever
        // used as `name(...)` is a function
        if (s.uses.len > 0) {
            if (f.analysis) |an| {
                const called = for (s.uses) |u| {
                    var i: usize = u.end;
                    while (i < an.text.len and (an.text[i] == ' ' or an.text[i] == '\t')) i += 1;
                    if (i >= an.text.len or an.text[i] != '(') break false;
                } else true;
                if (called) return .function;
            }
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

    /// The hover: the symbol's kind, name and type, the comments written
    /// above its definition, and what the `hover` hook adds.
    fn hover(self: *Server, a: Allocator, w: *json.Writer, params: ?Value) !void {
        const f = (try self.target(params)) orelse return w.null_();
        const offset = try self.offsetIn(f, params);
        const extra: ?[]const u8 = if (self.config.hover_hook) |hook| blk: {
            const r = (try self.callFileHook(a, "hover", hook, f, &.{py.c.PyLong_FromLongLong(offset)})) orelse break :blk null;
            defer py.Py_DecRef(r);
            const s = ph.utf8(r, "the hover hook's result") orelse {
                try self.hookFailed("hover");
                break :blk null;
            };
            break :blk try a.dupe(u8, s);
        } else null;
        const at_sym = f.analysis.?.symbolAt(offset);
        if (at_sym == null) {
            const md = extra orelse return w.null_();
            try w.beginObject();
            try w.key("contents");
            try w.beginObject();
            try w.fieldString("kind", "markdown");
            try w.fieldString("value", md);
            try w.endObject();
            try w.endObject();
            return;
        }
        const at = .{ .file = f, .sym = at_sym.?, .offset = offset };
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
        if (self.definitionOf(at.file, s)) |d| {
            if (try self.docComment(a, d.file, d.sym.def.?.start)) |doc| {
                try text.appendSlice(a, "\n\n");
                try text.appendSlice(a, doc);
            }
        }
        if (extra) |md| {
            try text.appendSlice(a, "\n\n---\n\n");
            try text.appendSlice(a, md);
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

    /// The comments written right above the line of `offset` (each alone on
    /// its line, none with a blank line after), without their markers; null
    /// if none.
    fn docComment(self: *Server, a: Allocator, f: *File, offset: u32) !?[]const u8 {
        const an = f.analysis orelse return null;
        const text = an.text;
        const comments = try self.commentSpans(a, an);
        var boundary: usize = lineStart(text, offset);
        var first: usize = comments.len; // the topmost comment taken
        var i = comments.len;
        while (i > 0) {
            i -= 1;
            const c = comments[i];
            if (c.end > boundary) continue;
            const between = text[c.end..boundary];
            if (std.mem.trim(u8, between, " \t\r\n").len != 0 or std.mem.count(u8, between, "\n") != 1) break;
            const ls = lineStart(text, c.start);
            if (std.mem.trim(u8, text[ls..c.start], " \t").len != 0) break;
            first = i;
            boundary = ls;
        }
        if (first == comments.len) return null;
        var out: std.ArrayList(u8) = .empty;
        for (comments[first..]) |c| {
            if (c.end > lineStart(text, offset)) break;
            const body = self.commentBody(text[c.start..c.end]);
            var lines = std.mem.splitScalar(u8, body.text, '\n');
            while (lines.next()) |raw| {
                var line = std.mem.trimEnd(u8, raw, " \t\r");
                if (body.block) {
                    // (in a block comment: a leading `*` column goes)
                    const t = std.mem.trimStart(u8, line, " \t");
                    if (t.len > 0 and t[0] == '*') line = std.mem.trimStart(u8, t[1..], " ");
                }
                if (out.items.len != 0) try out.append(a, '\n');
                try out.appendSlice(a, line);
            }
        }
        const doc = std.mem.trim(u8, out.items, " \t\r\n");
        return if (doc.len == 0) null else doc;
    }

    /// A comment without its markers (`// x`, `/// x`, `/* x */`, `/** x */`).
    fn commentBody(self: *Server, c: []const u8) struct { text: []const u8, block: bool } {
        for (self.config.block_comments) |pair| {
            if (!std.mem.startsWith(u8, c, pair[0])) continue;
            var body = c[pair[0].len..];
            if (std.mem.endsWith(u8, body, pair[1])) body = body[0 .. body.len - pair[1].len];
            const last = pair[0][pair[0].len - 1];
            while (body.len > 0 and body[0] == last) body = body[1..];
            return .{ .text = body, .block = true };
        }
        for (self.config.line_comments) |marker| {
            if (!std.mem.startsWith(u8, c, marker)) continue;
            var body = c[marker.len..];
            const last = marker[marker.len - 1];
            while (body.len > 0 and (body[0] == last or body[0] == '!')) body = body[1..];
            if (body.len > 0 and body[0] == ' ') body = body[1..];
            return .{ .text = body, .block = false };
        }
        return .{ .text = c, .block = false };
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
        const data = try self.tokenData(a, f);
        try self.keepTokens(f, data);
        try w.beginObject();
        try w.fieldString("resultId", try std.fmt.allocPrint(a, "{d}", .{f.tokens_id}));
        try w.key("data");
        try w.beginArray();
        for (data) |v| try w.int(v);
        try w.endArray();
        try w.endObject();
    }

    /// The tokens as an edit of those last sent (the client's
    /// `previousResultId`): the part between what's common at both ends.
    fn semanticTokensDelta(self: *Server, a: Allocator, w: *json.Writer, params: ?Value) !void {
        const f = (try self.target(params)) orelse return w.null_();
        const prev_id = json.getString(params, "previousResultId") orelse "";
        const prev_opt = f.tokens;
        const matches = prev_opt != null and std.mem.eql(u8, prev_id, try std.fmt.allocPrint(a, "{d}", .{f.tokens_id}));
        if (!matches) return self.semanticTokens(a, w, params);
        const prev = try a.dupe(u32, prev_opt.?);
        const data = try self.tokenData(a, f);
        try self.keepTokens(f, data);
        var head: usize = 0;
        while (head < prev.len and head < data.len and prev[head] == data[head]) head += 1;
        var tail: usize = 0;
        while (tail < prev.len - head and tail < data.len - head and prev[prev.len - 1 - tail] == data[data.len - 1 - tail]) tail += 1;
        try w.beginObject();
        try w.fieldString("resultId", try std.fmt.allocPrint(a, "{d}", .{f.tokens_id}));
        try w.key("edits");
        try w.beginArray();
        if (head != prev.len or head != data.len) {
            try w.beginObject();
            try w.fieldInt("start", @intCast(head));
            try w.fieldInt("deleteCount", @intCast(prev.len - head - tail));
            try w.key("data");
            try w.beginArray();
            for (data[head .. data.len - tail]) |v| try w.int(v);
            try w.endArray();
            try w.endObject();
        }
        try w.endArray();
        try w.endObject();
    }

    /// Remember the tokens sent for `f` (under a new result id).
    fn keepTokens(self: *Server, f: *File, data: []const u32) !void {
        const copy = try self.gpa.dupe(u32, data);
        if (f.tokens) |t| self.gpa.free(t);
        f.tokens = copy;
        f.tokens_id = self.next_result_id;
        self.next_result_id += 1;
    }

    /// The semantic tokens of a file, encoded as the protocol wants.
    fn tokenData(self: *Server, a: Allocator, f: *File) ![]u32 {
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
        return data.items;
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
            if (self.config.completion_hook) |hook| {
                if (try self.callFileHook(a, "completion", hook, f, &.{py.c.PyLong_FromLongLong(offset)})) |list| {
                    defer py.Py_DecRef(list);
                    try self.hookItems(a, w, "completion", list, &seen);
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
        // The keywords the grammar takes here (all, if it can't tell)
        const allowed = try self.expectedWords(a, text[0..start]);
        for (self.config.keywords) |k| {
            if (seen.contains(k)) continue;
            if (allowed) |set| if (!set.contains(k)) continue;
            try w.beginObject();
            try w.fieldString("label", k);
            try w.fieldInt("kind", 14);
            try w.fieldString("sortText", "~");
            try w.endObject();
        }
        if (self.config.completion_hook) |hook| {
            if (try self.callFileHook(a, "completion", hook, f, &.{py.c.PyLong_FromLongLong(offset)})) |list| {
                defer py.Py_DecRef(list);
                try self.hookItems(a, w, "completion", list, &seen);
            }
        }
        try w.endArray();
        try w.endObject();
    }

    /// The completion items a hook returned (str labels, or dicts of
    /// CompletionItem fields), written out.
    fn hookItems(self: *Server, a: Allocator, w: *json.Writer, name: []const u8, list: *PyObject, seen: *std.StringHashMapUnmanaged(void)) !void {
        const seq = py.c.PySequence_Fast(list, "the hook must return a list") orelse return self.hookFailed(name);
        defer py.Py_DecRef(seq);
        const n: usize = @intCast(py.c.PySequence_Size(seq));
        for (0..n) |i| {
            const item = py.c.PySequence_GetItem(seq, @intCast(i)) orelse return self.hookFailed(name);
            defer py.Py_DecRef(item);
            if (py.PyUnicode_Check(item)) {
                const label = ph.utf8(item, "label") orelse return self.hookFailed(name);
                if (seen.contains(label)) continue;
                try seen.put(a, try a.dupe(u8, label), {});
                try w.beginObject();
                try w.fieldString("label", label);
                try w.endObject();
            } else if (py.PyDict_Check(item)) {
                const text = (try pythonToJson(a, item)) orelse return self.hookFailed(name);
                try w.raw(text);
            } else {
                ph.raise(py.PyExc_TypeError(), "the {s} hook's items must be str or dict", .{name});
                return self.hookFailed(name);
            }
        }
    }

    /// The words the grammar could take after `prefix` (zgram's
    /// `expected()`); null if it can't tell (an error before).
    fn expectedWords(self: *Server, a: Allocator, prefix: []const u8) !?std.StringHashMapUnmanaged(void) {
        if (self.config.keywords.len == 0) return null;
        const bytes = py.c.PyBytes_FromStringAndSize(prefix.ptr, @intCast(prefix.len)) orelse return error.Python;
        defer py.Py_DecRef(bytes);
        const list = py.c.PyObject_CallMethod(self.config.parser, "expected", "O", bytes) orelse {
            // (a zgram without expected(): every keyword)
            py.c.PyErr_Clear();
            return null;
        };
        defer py.Py_DecRef(list);
        const n: usize = @intCast(py.c.PyList_Size(list));
        if (n == 0) return null;
        var set: std.StringHashMapUnmanaged(void) = .empty;
        for (0..n) |i| {
            const item = py.c.PyList_GetItem(list, @intCast(i));
            const s = ph.utf8(item, "literal") orelse return error.Python;
            try set.put(a, try a.dupe(u8, s), {});
        }
        return set;
    }

    /// The inferred types of the definitions in the range that don't write
    /// theirs (`let x = 1` shows `x: int`); not of functions and types.
    fn inlayHint(self: *Server, a: Allocator, w: *json.Writer, params: ?Value) !void {
        _ = a;
        const f = (try self.target(params)) orelse return w.null_();
        const an = f.analysis.?;
        const range = json.get(params, "range");
        const lo = f.doc.offsetOf(readPosition(json.get(range, "start")) orelse return error.InvalidParams, self.encoding);
        const hi = f.doc.offsetOf(readPosition(json.get(range, "end")) orelse return error.InvalidParams, self.encoding);
        try w.beginArray();
        for (an.syms) |*s| {
            const d = s.def orelse continue;
            const t = s.type_text orelse continue;
            if (s.builtin or s.origin_key != null or d.start < lo or d.end > hi) continue;
            if (t.len == 0 or std.mem.eql(u8, t, "unknown")) continue;
            switch (self.kindOf(f, s)) {
                .variable, .constant, .parameter, .field, .property => {},
                else => continue,
            }
            if (hasTypeWritten(an, s.def_node)) continue;
            try w.beginObject();
            try w.key("position");
            try self.writePosition(w, &f.doc, d.end);
            var buf: [256]u8 = undefined;
            try w.fieldString("label", std.fmt.bufPrint(&buf, ": {s}", .{t}) catch t);
            try w.fieldInt("kind", 1);
            try w.endObject();
        }
        try w.endArray();
    }

    /// Whether the construct defining a name (the name node's parent) has
    /// a child labelled `type`.
    fn hasTypeWritten(an: *const Analysis, name_node: u32) bool {
        if (an.type_field == 0 or name_node == NONE or name_node >= an.parents.len) return false;
        const p = an.parents[name_node];
        if (p == NONE) return false;
        var j: u32 = p + 1;
        const last = p + an.nodes[p].subtree_size;
        while (j <= last) : (j += an.nodes[j].subtree_size + 1) {
            if (an.nodes[j].fieldId() == an.type_field) return true;
        }
        return false;
    }

    /// The definition of the type of the symbol at the position.
    fn typeDefinition(self: *Server, a: Allocator, w: *json.Writer, params: ?Value) !void {
        _ = a;
        const at = (try self.symbolAtRequest(params)) orelse return w.null_();
        const s = (self.definitionOf(at.file, at.sym) orelse Definition{ .file = at.file, .sym = at.sym }).sym;
        const t = typeName(s.type_text orelse return w.null_());
        const d = self.typeNamed(at.file, t) orelse return w.null_();
        try self.writeLocation(w, d.file, d.sym.def.?);
    }

    /// The definition of a type name seen from `f`: its own or imported
    /// one, else one defined anywhere in the project.
    fn typeNamed(self: *Server, f: *File, name: []const u8) ?Definition {
        if (name.len == 0) return null;
        if (f.analysis) |an| {
            for (an.syms) |*s| {
                if (!std.mem.eql(u8, s.name, name)) continue;
                if (self.definitionOf(f, s)) |d| return d;
            }
        }
        for (self.project.files.values()) |other| {
            const an = other.analysis orelse continue;
            for (an.syms) |*s| {
                if (s.def == null or s.origin_key != null or !std.mem.eql(u8, s.name, name)) continue;
                switch (self.kindOf(other, s)) {
                    .type, .class, .@"struct", .@"enum", .interface => return .{ .file = other, .sym = s },
                    else => {},
                }
            }
        }
        return null;
    }

    /// The signature of the call the cursor is in, with the argument it is
    /// at: from the callee's type (`fn(int, str) -> bool`) and its
    /// parameters' names.
    fn signatureHelp(self: *Server, a: Allocator, w: *json.Writer, params: ?Value) !void {
        const f = (try self.target(params)) orelse return w.null_();
        const an = f.analysis.?;
        const text = an.text;
        const offset = try self.offsetIn(f, params);
        // Back to the unclosed `(`, counting the commas at its level
        var depth: usize = 0;
        var commas: u32 = 0;
        var i: usize = @min(offset, text.len);
        const floor = i -| 4096;
        const open = while (i > floor) {
            i -= 1;
            switch (text[i]) {
                ')', ']', '}' => depth += 1,
                '[', '{' => {
                    if (depth == 0) return w.null_();
                    depth -= 1;
                },
                '(' => {
                    if (depth == 0) break i;
                    depth -= 1;
                },
                ',' => if (depth == 0) {
                    commas += 1;
                },
                ';' => if (depth == 0) return w.null_(),
                else => {},
            }
        } else return w.null_();
        var name_end = open;
        while (name_end > 0 and (text[name_end - 1] == ' ' or text[name_end - 1] == '\t')) name_end -= 1;
        var name_start = name_end;
        while (name_start > 0 and isWordChar(text[name_start - 1])) name_start -= 1;
        if (name_start == name_end) return w.null_();
        const name = text[name_start..name_end];

        // The callee: the name there, else looked up (what's being typed
        // rarely parses)
        var callee: ?Ref = null;
        if (an.symbolAt(@intCast(name_start))) |s| {
            const d = self.definitionOf(f, s) orelse Definition{ .file = f, .sym = s };
            callee = .{ .file = d.file, .sym = d.sym };
        } else if (name_start > 0 and text[name_start - 1] == '.') {
            if (try self.chainScope(a, f, an, @intCast(name_start - 1))) |scope| callee = self.memberNamed(scope, name);
        } else callee = try self.visibleNamed(a, f, an, @intCast(name_start), name);
        const c = callee orelse return w.null_();

        // Its parameters: types from its type, names from its scope
        var types: std.ArrayList([]const u8) = .empty;
        var result: ?[]const u8 = null;
        if (c.sym.type_text) |t| {
            if (std.mem.startsWith(u8, t, "fn(")) {
                if (matchingParen(t, 2)) |close| {
                    var parts = splitTopLevel(t[3..close]);
                    while (parts.next()) |p| {
                        const trimmed = std.mem.trim(u8, p, " ");
                        if (trimmed.len != 0) try types.append(a, trimmed);
                    }
                    const rest = std.mem.trim(u8, t[close + 1 ..], " ");
                    if (std.mem.startsWith(u8, rest, "->")) result = std.mem.trim(u8, rest[2..], " ");
                }
            }
        }
        var names: std.ArrayList([]const u8) = .empty;
        if (c.sym.owns != NONE) {
            if (c.file.analysis) |can| {
                var ps: std.ArrayList(*const Sym) = .empty;
                for (can.syms) |*s| {
                    if (s.scope == c.sym.owns and s.def != null and self.kindOf(c.file, s) == .parameter) try ps.append(a, s);
                }
                std.sort.pdq(*const Sym, ps.items, {}, struct {
                    fn lt(_: void, x: *const Sym, y: *const Sym) bool {
                        return x.def.?.start < y.def.?.start;
                    }
                }.lt);
                for (ps.items) |s| try names.append(a, s.name);
            }
        }
        const count = @max(types.items.len, names.items.len);
        if (count == 0 and c.sym.type_text == null) return w.null_();

        var label: std.ArrayList(u8) = .empty;
        try label.appendSlice(a, c.sym.name);
        try label.append(a, '(');
        const Param = struct { start: usize, end: usize };
        const ranges = try a.alloc(Param, count);
        for (0..count) |k| {
            if (k > 0) try label.appendSlice(a, ", ");
            const start = label.items.len;
            if (k < names.items.len) try label.appendSlice(a, names.items[k]);
            if (k < types.items.len) {
                if (k < names.items.len) try label.appendSlice(a, ": ");
                try label.appendSlice(a, types.items[k]);
            }
            ranges[k] = .{ .start = start, .end = label.items.len };
        }
        try label.append(a, ')');
        if (result) |r| {
            try label.appendSlice(a, " -> ");
            try label.appendSlice(a, r);
        }

        try w.beginObject();
        try w.key("signatures");
        try w.beginArray();
        try w.beginObject();
        try w.fieldString("label", label.items);
        if (c.sym.def != null) {
            if (try self.docComment(a, c.file, c.sym.def.?.start)) |doc| {
                try w.key("documentation");
                try w.beginObject();
                try w.fieldString("kind", "markdown");
                try w.fieldString("value", doc);
                try w.endObject();
            }
        }
        try w.key("parameters");
        try w.beginArray();
        for (ranges) |r| {
            // (offsets in the label, in the position encoding's units)
            const s = self.unitsOf(label.items[0..r.start]);
            const e = s + self.unitsOf(label.items[r.start..r.end]);
            try w.beginObject();
            try w.key("label");
            try w.beginArray();
            try w.int(s);
            try w.int(e);
            try w.endArray();
            try w.endObject();
        }
        try w.endArray();
        try w.endObject();
        try w.endArray();
        try w.fieldInt("activeSignature", 0);
        try w.fieldInt("activeParameter", if (count == 0) 0 else @min(commas, count - 1));
        try w.endObject();
    }

    fn unitsOf(self: *const Server, s: []const u8) u32 {
        return switch (self.encoding) {
            .utf8 => @intCast(s.len),
            .utf16 => document.byteToUtf16(s),
        };
    }

    /// For each position: the word there, then each node around it, out
    /// to the whole file.
    fn selectionRange(self: *Server, a: Allocator, w: *json.Writer, params: ?Value) !void {
        const f = (try self.target(params)) orelse return w.null_();
        const an = f.analysis.?;
        try w.beginArray();
        for (json.getArray(params, "positions") orelse return error.InvalidParams) |pos| {
            const offset = f.doc.offsetOf(readPosition(pos) orelse return error.InvalidParams, self.encoding);
            var chain: std.ArrayList(Span) = .empty;
            // The innermost node at the offset, then its ancestors
            var nodes: std.ArrayList(u32) = .empty;
            if (an.nodes.len > 0) {
                var cur: u32 = 0;
                try nodes.append(a, 0);
                descend: while (true) {
                    var j: u32 = cur + 1;
                    const last = cur + an.nodes[cur].subtree_size;
                    while (j <= last) : (j += an.nodes[j].subtree_size + 1) {
                        const n = an.nodes[j];
                        if (n.text_start <= offset and offset < n.text_end) {
                            cur = j;
                            try nodes.append(a, j);
                            continue :descend;
                        }
                    }
                    break;
                }
            }
            var word = Span{ .start = offset, .end = offset };
            while (word.start > 0 and isWordChar(an.text[word.start - 1])) word.start -= 1;
            while (word.end < an.text.len and isWordChar(an.text[word.end])) word.end += 1;
            if (word.end > word.start) try chain.append(a, word);
            var k = nodes.items.len;
            while (k > 0) {
                k -= 1;
                const span = an.nodeSpan(nodes.items[k]);
                if (span.start > word.start or span.end < word.end) continue;
                if (chain.items.len > 0) {
                    const prev = chain.items[chain.items.len - 1];
                    if (prev.start == span.start and prev.end == span.end) continue;
                }
                try chain.append(a, span);
            }
            const whole = Span{ .start = 0, .end = @intCast(an.text.len) };
            if (chain.items.len == 0 or chain.items[chain.items.len - 1].start != 0 or chain.items[chain.items.len - 1].end != whole.end) try chain.append(a, whole);
            for (chain.items, 0..) |span, idx| {
                try w.beginObject();
                try w.key("range");
                try self.writeRange(w, &f.doc, span);
                if (idx + 1 < chain.items.len) try w.key("parent");
            }
            for (chain.items) |_| try w.endObject();
        }
        try w.endArray();
    }

    /// Quick fixes: for a name that isn't defined, the visible ones it may
    /// be a typo of ("Change to 'count'"); and those of the `code_actions`
    /// hook.
    fn codeAction(self: *Server, a: Allocator, w: *json.Writer, params: ?Value) !void {
        const f = (try self.target(params)) orelse return w.null_();
        const an = f.analysis.?;
        const range = json.get(params, "range");
        const lo = f.doc.offsetOf(readPosition(json.get(range, "start")) orelse return error.InvalidParams, self.encoding);
        const hi = f.doc.offsetOf(readPosition(json.get(range, "end")) orelse return error.InvalidParams, self.encoding);
        try w.beginArray();
        for (an.diags) |d| {
            if (d.span.end < lo or d.span.start > hi) continue;
            const word = an.text[d.span.start..d.span.end];
            if (word.len == 0 or !isWordStart(word[0])) continue;
            for (word) |ch| if (!isWordChar(ch)) break else continue;
            if (an.symbolAt(d.span.start) != null) continue;
            for (try self.similarNames(a, f, an, d.span.start, word), 0..) |name, k| {
                try w.beginObject();
                try w.fieldString("title", try std.fmt.allocPrint(a, "Change to '{s}'", .{name}));
                try w.fieldString("kind", "quickfix");
                if (k == 0) try w.fieldBool("isPreferred", true);
                try w.key("diagnostics");
                try w.beginArray();
                try self.writeDiagnostic(w, f, d);
                try w.endArray();
                try w.key("edit");
                try self.writeEdits(w, f, &.{.{ .span = d.span, .text = name }});
                try w.endObject();
            }
        }
        if (self.config.code_action_hook) |hook| try self.hookActions(a, w, hook, f, lo, hi);
        try w.endArray();
    }

    const Edit = struct { span: Span, text: []const u8 };

    /// A WorkspaceEdit of `edits` in `f`.
    fn writeEdits(self: *Server, w: *json.Writer, f: *File, edits: []const Edit) !void {
        try w.beginObject();
        try w.key("changes");
        try w.beginObject();
        try w.key(f.uri);
        try w.beginArray();
        for (edits) |e| {
            try w.beginObject();
            try w.key("range");
            try self.writeRange(w, &f.doc, e.span);
            try w.fieldString("newText", e.text);
            try w.endObject();
        }
        try w.endArray();
        try w.endObject();
        try w.endObject();
    }

    fn writeDiagnostic(self: *Server, w: *json.Writer, f: *File, d: project_mod.Diag) !void {
        try w.beginObject();
        try w.key("range");
        try self.writeRange(w, &f.doc, d.span);
        try w.fieldInt("severity", d.severity);
        if (d.code.len != 0) try w.fieldString("code", d.code);
        try w.fieldString("source", self.config.name);
        try w.fieldString("message", d.message);
        try w.endObject();
    }

    /// The names visible at `at` (the members, after a dot) close to
    /// `word`: at most 3, the closest first.
    fn similarNames(self: *Server, a: Allocator, f: *File, an: *const Analysis, at: u32, word: []const u8) ![]const []const u8 {
        var candidates: std.ArrayList([]const u8) = .empty;
        if (at > 0 and an.text[at - 1] == '.') {
            if (try self.chainScope(a, f, an, at - 1)) |scope| {
                for (scope.file.analysis.?.syms) |*m| {
                    if (m.scope == scope.node and !m.builtin) try candidates.append(a, m.name);
                }
            }
        } else if (an.checked) |checked| {
            const list = py.c.PyObject_CallMethod(checked, "visible", "L", @as(c_longlong, at)) orelse return error.Python;
            defer py.Py_DecRef(list);
            const n: usize = @intCast(py.c.PyList_Size(list));
            for (0..n) |i| {
                const obj = py.c.PyList_GetItem(list, @intCast(i));
                if ((try ph.attrString(a, obj, "name"))) |name| try candidates.append(a, name);
            }
        }
        const Scored = struct { name: []const u8, dist: usize };
        var scored: std.ArrayList(Scored) = .empty;
        const limit = @max(1, (word.len + 1) / 3);
        outer: for (candidates.items) |name| {
            if (std.mem.eql(u8, name, word)) continue;
            for (scored.items) |s| if (std.mem.eql(u8, s.name, name)) continue :outer;
            const dist = try editDistance(a, word, name);
            if (dist <= limit) try scored.append(a, .{ .name = name, .dist = dist });
        }
        std.sort.pdq(Scored, scored.items, {}, struct {
            fn lt(_: void, x: Scored, y: Scored) bool {
                return x.dist < y.dist;
            }
        }.lt);
        const out = try a.alloc([]const u8, @min(3, scored.items.len));
        for (out, 0..) |*o, i| o.* = scored.items[i].name;
        return out;
    }

    /// The code actions of the hook: called with (uri, text, start, end,
    /// diagnostics, analysis), it returns dicts `{"title", "edits": [(start,
    /// end, text)], "kind"?, "preferred"?}`.
    fn hookActions(self: *Server, a: Allocator, w: *json.Writer, hook: *PyObject, f: *File, lo: u32, hi: u32) !void {
        const an = f.analysis.?;
        const diags = py.c.PyList_New(0) orelse return error.Python;
        for (an.diags) |d| {
            if (d.span.end < lo or d.span.start > hi) continue;
            const item = py.c.Py_BuildValue("{s:I,s:I,s:L,s:s#,s:s#}", "start", @as(c_uint, d.span.start), "end", @as(c_uint, d.span.end), "severity", @as(c_longlong, d.severity), "code", d.code.ptr, @as(py.Py_ssize_t, @intCast(d.code.len)), "message", d.message.ptr, @as(py.Py_ssize_t, @intCast(d.message.len))) orelse {
                py.Py_DecRef(diags);
                return error.Python;
            };
            defer py.Py_DecRef(item);
            if (py.c.PyList_Append(diags, item) != 0) {
                py.Py_DecRef(diags);
                return error.Python;
            }
        }
        const result = (try self.callFileHook(a, "code_actions", hook, f, &.{ py.c.PyLong_FromLongLong(lo), py.c.PyLong_FromLongLong(hi), diags })) orelse return;
        defer py.Py_DecRef(result);
        self.writeHookActions(a, w, f, result) catch |e| switch (e) {
            error.Python => return self.hookFailed("code_actions"),
            else => return e,
        };
    }

    fn writeHookActions(self: *Server, a: Allocator, w: *json.Writer, f: *File, result: *PyObject) !void {
        const seq = py.c.PySequence_Fast(result, "the code_actions hook must return a list") orelse return error.Python;
        defer py.Py_DecRef(seq);
        const n: usize = @intCast(py.c.PySequence_Size(seq));
        const text_len: u32 = @intCast(f.doc.text.items.len);
        // (all read before any is written: an error leaves no half action)
        const Action = struct { title: []const u8, kind: []const u8, preferred: bool, edits: []const Edit };
        var actions: std.ArrayList(Action) = .empty;
        for (0..n) |i| {
            const item = py.c.PySequence_GetItem(seq, @intCast(i)) orelse return error.Python;
            defer py.Py_DecRef(item);
            const title = try dictString(a, item, "title") orelse {
                ph.raise(py.PyExc_TypeError(), "a code action needs a 'title'", .{});
                return error.Python;
            };
            const kind = try dictString(a, item, "kind") orelse "quickfix";
            const preferred = if (py.c.PyDict_GetItemString(item, "preferred")) |p| py.c.PyObject_IsTrue(p) == 1 else false;
            var edits: std.ArrayList(Edit) = .empty;
            if (py.c.PyDict_GetItemString(item, "edits")) |list| {
                const es = py.c.PySequence_Fast(list, "'edits' must be a list") orelse return error.Python;
                defer py.Py_DecRef(es);
                const m: usize = @intCast(py.c.PySequence_Size(es));
                for (0..m) |j| {
                    const e = py.c.PySequence_GetItem(es, @intCast(j)) orelse return error.Python;
                    defer py.Py_DecRef(e);
                    const span = (try ph.toSpan(e)) orelse return error.Python;
                    const t = py.c.PySequence_GetItem(e, 2) orelse return error.Python;
                    defer py.Py_DecRef(t);
                    const s = ph.utf8(t, "an edit's text") orelse return error.Python;
                    try edits.append(a, .{ .span = .{ .start = @min(span[0], text_len), .end = @min(@max(span[0], span[1]), text_len) }, .text = try a.dupe(u8, s) });
                }
            }
            try actions.append(a, .{ .title = title, .kind = kind, .preferred = preferred, .edits = edits.items });
        }
        for (actions.items) |act| {
            try w.beginObject();
            try w.fieldString("title", act.title);
            try w.fieldString("kind", act.kind);
            if (act.preferred) try w.fieldBool("isPreferred", true);
            if (act.edits.len != 0) {
                try w.key("edit");
                try self.writeEdits(w, f, act.edits);
            }
            try w.endObject();
        }
    }

    /// The `format` hook's text for the file (called with (uri, text,
    /// analysis)), as one edit of the whole file.
    fn formatting(self: *Server, a: Allocator, w: *json.Writer, params: ?Value) !void {
        const hook = self.config.format_hook orelse return w.null_();
        const u = json.getString(json.get(params, "textDocument"), "uri") orelse return error.InvalidParams;
        const f = self.project.get(u) orelse return w.null_();
        try self.analyze();
        const result = (try self.callFileHook(a, "format", hook, f, &.{})) orelse return w.null_();
        defer py.Py_DecRef(result);
        const text = ph.utf8(result, "the format hook's result") orelse {
            try self.hookFailed("format");
            return w.null_();
        };
        try w.beginArray();
        if (!std.mem.eql(u8, text, f.doc.text.items)) {
            try w.beginObject();
            try w.key("range");
            try self.writeRange(w, &f.doc, .{ .start = 0, .end = @intCast(f.doc.text.items.len) });
            try w.fieldString("newText", text);
            try w.endObject();
        }
        try w.endArray();
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

/// The name of the type a type text is of: `Point` for `Point?`,
/// `list[Point]` is a `list`, `type[Point]` (a type itself) a `Point`.
fn typeName(text: []const u8) []const u8 {
    var t = std.mem.trim(u8, text, " ");
    if (std.mem.startsWith(u8, t, "type[") and std.mem.endsWith(u8, t, "]")) t = t[5 .. t.len - 1];
    var end: usize = 0;
    while (end < t.len and (isWordChar(t[end]) or t[end] == '.')) end += 1;
    return t[0..end];
}

/// The index of the `)` closing the `(` at `open`.
fn matchingParen(text: []const u8, open: usize) ?usize {
    var depth: usize = 0;
    for (text[open..], open..) |c, i| switch (c) {
        '(', '[', '{' => depth += 1,
        ')', ']', '}' => {
            depth -= 1;
            if (depth == 0) return if (c == ')') i else null;
        },
        else => {},
    };
    return null;
}

/// Split on the commas outside brackets.
fn splitTopLevel(text: []const u8) TopLevelSplit {
    return .{ .text = text };
}

const TopLevelSplit = struct {
    text: []const u8,
    pos: usize = 0,
    done: bool = false,

    fn next(self: *TopLevelSplit) ?[]const u8 {
        if (self.done) return null;
        var depth: usize = 0;
        var i = self.pos;
        while (i < self.text.len) : (i += 1) {
            switch (self.text[i]) {
                '(', '[', '{' => depth += 1,
                ')', ']', '}' => depth -|= 1,
                ',' => if (depth == 0) {
                    const part = self.text[self.pos..i];
                    self.pos = i + 1;
                    return part;
                },
                else => {},
            }
        }
        self.done = true;
        return self.text[self.pos..];
    }
};

/// The edits from `x` to `y`: a letter inserted, deleted, replaced, or two
/// swapped (optimal string alignment).
fn editDistance(a: Allocator, x: []const u8, y: []const u8) !usize {
    const width = y.len + 1;
    const d = try a.alloc(usize, (x.len + 1) * width);
    for (0..x.len + 1) |i| {
        for (0..width) |j| {
            if (i == 0 or j == 0) {
                d[i * width + j] = i + j;
                continue;
            }
            const cost: usize = if (x[i - 1] == y[j - 1]) 0 else 1;
            var best = @min(@min(d[(i - 1) * width + j] + 1, d[i * width + j - 1] + 1), d[(i - 1) * width + j - 1] + cost);
            if (i > 1 and j > 1 and x[i - 1] == y[j - 2] and x[i - 2] == y[j - 1]) best = @min(best, d[(i - 2) * width + j - 2] + 1);
            d[i * width + j] = best;
        }
    }
    return d[x.len * width + y.len];
}

/// `d[key]` as a str copied into `a`; null if absent or None.
fn dictString(a: Allocator, d: *PyObject, key: [*:0]const u8) !?[]const u8 {
    if (!py.PyDict_Check(d)) {
        ph.raise(py.PyExc_TypeError(), "a code action must be a dict", .{});
        return error.Python;
    }
    const v = py.c.PyDict_GetItemString(d, key) orelse return null;
    if (v == py.Py_None()) return null;
    const s = ph.utf8(v, std.mem.span(key)) orelse return error.Python;
    return try a.dupe(u8, s);
}

/// `json.loads(text)`, or null with the error set.
fn jsonToPython(text: []const u8) ?*PyObject {
    const mod = py.c.PyImport_ImportModule("json") orelse return null;
    defer py.Py_DecRef(mod);
    const s = ph.newString(text) orelse return null;
    defer py.Py_DecRef(s);
    return py.c.PyObject_CallMethod(mod, "loads", "O", s);
}

/// `json.dumps(obj)` copied into `a`, or null with the error set.
fn pythonToJson(a: Allocator, obj: *PyObject) !?[]const u8 {
    const mod = py.c.PyImport_ImportModule("json") orelse return null;
    defer py.Py_DecRef(mod);
    const s = py.c.PyObject_CallMethod(mod, "dumps", "O", obj) orelse return null;
    defer py.Py_DecRef(s);
    const text = ph.utf8(s, "json") orelse return null;
    return try a.dupe(u8, text);
}

/// Whether `path` is in the directory `root` (`/a/b/c` is in `/a/b`, `/a/bc`
/// isn't).
fn isUnder(path: []const u8, root: []const u8) bool {
    if (root.len == 0 or path.len <= root.len or !std.mem.startsWith(u8, path, root)) return false;
    const last = root[root.len - 1];
    return last == '/' or last == '\\' or path[root.len] == '/' or path[root.len] == '\\';
}

fn lineStart(text: []const u8, offset: usize) usize {
    var i = @min(offset, text.len);
    while (i > 0 and text[i - 1] != '\n') i -= 1;
    return i;
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
