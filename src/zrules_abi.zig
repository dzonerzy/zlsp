//! zrules' results as native code reads them, through two capsules:
//! `Analysis.capsule` ("zrules.analysis.v1": the symbol table) and
//! `Selector.capsule` ("zrules.selector.v1": a match function over zgram's
//! tree capsule). zrules' src/native_abi.zig is the definition; this is the
//! consumer's copy. Everything a capsule points to stays valid while the
//! capsule (or the object it came from) is referenced.

const std = @import("std");
const tree_mod = @import("tree.zig");

/// Version of both interfaces below, bumped on any incompatible change.
pub const NATIVE_ABI: u32 = 1;
pub const ANALYSIS_CAPSULE = "zrules.analysis.v1";
pub const SELECTOR_CAPSULE = "zrules.selector.v1";

/// "None": a builtin's node, a global scope, no owned scope, ...
pub const NONE: u32 = std.math.maxInt(u32);

/// A string, not NUL-terminated; `ptr == null` means "none"
pub const Str = extern struct {
    ptr: ?[*]const u8 = null,
    len: usize = 0,
};

pub const Span = extern struct { start: u32, end: u32 };

pub const SYMBOL_BUILTIN: u32 = 1;

pub const SymbolView = extern struct {
    name: Str,
    namespace: Str,
    /// Its type as text (`fn(int) -> int`, `type[Point]`); none when unknown
    type: Str = .{},
    /// For a name imported in a project: the key of the file defining it,
    /// and the defining node there
    origin_key: Str = .{},
    origin_node: u32 = NONE,
    /// For a module's local name in a project: the key of the file
    module_key: Str = .{},
    /// The defining node and its span (NONE and 0..0 for a builtin)
    node: u32 = NONE,
    def: Span = .{ .start = 0, .end = 0 },
    /// The scope node it is defined in, and the one it names (NONE: none)
    scope: u32 = NONE,
    owns: u32 = NONE,
    /// Its uses: AnalysisView.uses[uses_start..][0..uses_len] (and use_nodes)
    uses_start: u32 = 0,
    uses_len: u32 = 0,
    flags: u32 = 0,
};

/// What `Analysis.capsule` points to: every symbol, in the order the rules
/// found them (Analysis.symbols' order)
pub const AnalysisView = extern struct {
    abi: u32 = NATIVE_ABI,
    symbol_count: u32 = 0,
    symbols: ?[*]const SymbolView = null,
    /// Spans and nodes of the uses, grouped by symbol
    uses: ?[*]const Span = null,
    use_nodes: ?[*]const u32 = null,
};

/// Writes the indices of the nodes of `tree` that match into `out` (room
/// for tree.node_count entries), in source order. Returns how many, or -1
/// (out of memory), or -2 (the tree is from another grammar).
pub const MatchFn = *const fn (ctx: *const anyopaque, tree: *const tree_mod.TreeView, out: [*]u32) callconv(.c) i64;

/// What `Selector.capsule` points to
pub const SelectorView = extern struct {
    abi: u32 = NATIVE_ABI,
    ctx: *const anyopaque,
    match: MatchFn,
};
