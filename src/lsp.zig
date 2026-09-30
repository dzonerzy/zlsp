//! LSP's vocabulary: symbol kinds, semantic token types and modifiers,
//! error codes.

const std = @import("std");

/// What a name is, as configured (`symbols={"FuncDef > .name": "function"}`)
pub const Kind = enum(u8) {
    variable,
    function,
    method,
    parameter,
    constant,
    type,
    class,
    @"struct",
    @"enum",
    enumMember,
    interface,
    property,
    field,
    namespace,
    module,
    typeParameter,
    event,
    operator,

    pub fn parse(name: []const u8) ?Kind {
        return std.meta.stringToEnum(Kind, name);
    }

    /// LSP SymbolKind (document symbols, workspace symbols)
    pub fn symbolKind(k: Kind) i64 {
        return switch (k) {
            .variable => 13,
            .function => 12,
            .method => 6,
            .parameter => 13,
            .constant => 14,
            .type => 5,
            .class => 5,
            .@"struct" => 23,
            .@"enum" => 10,
            .enumMember => 22,
            .interface => 11,
            .property => 7,
            .field => 8,
            .namespace => 3,
            .module => 2,
            .typeParameter => 26,
            .event => 24,
            .operator => 25,
        };
    }

    /// LSP CompletionItemKind
    pub fn completionKind(k: Kind) i64 {
        return switch (k) {
            .variable, .parameter => 6,
            .function => 3,
            .method => 2,
            .constant => 21,
            .type, .class => 7,
            .@"struct" => 22,
            .@"enum" => 13,
            .enumMember => 20,
            .interface => 8,
            .property => 10,
            .field => 5,
            .namespace, .module => 9,
            .typeParameter => 25,
            .event => 23,
            .operator => 24,
        };
    }

    /// The semantic token type a name of this kind gets
    pub fn tokenType(k: Kind) TokenType {
        return switch (k) {
            .variable, .constant => .variable,
            .function => .function,
            .method => .method,
            .parameter => .parameter,
            .type => .type,
            .class => .class,
            .@"struct" => .@"struct",
            .@"enum" => .@"enum",
            .enumMember => .enumMember,
            .interface => .interface,
            .property, .field => .property,
            .namespace, .module => .namespace,
            .typeParameter => .typeParameter,
            .event => .event,
            .operator => .operator,
        };
    }
};

/// Semantic token types, in the order of the legend sent to the client
pub const TokenType = enum(u8) {
    namespace,
    type,
    class,
    @"enum",
    interface,
    @"struct",
    typeParameter,
    parameter,
    variable,
    property,
    enumMember,
    event,
    function,
    method,
    macro,
    keyword,
    modifier,
    comment,
    string,
    number,
    regexp,
    operator,
    decorator,

    pub fn parse(name: []const u8) ?TokenType {
        return std.meta.stringToEnum(TokenType, name);
    }
};

/// Semantic token modifiers, bit positions in the legend's order
pub const Modifier = enum(u5) {
    declaration,
    readonly,
    defaultLibrary,
};

pub const DiagnosticSeverity = struct {
    pub const err: i64 = 1;
    pub const warning: i64 = 2;
    pub const information: i64 = 3;
    pub const hint: i64 = 4;
};

pub const ErrorCode = struct {
    pub const parse_error: i64 = -32700;
    pub const invalid_request: i64 = -32600;
    pub const method_not_found: i64 = -32601;
    pub const invalid_params: i64 = -32602;
    pub const internal_error: i64 = -32603;
    pub const server_not_initialized: i64 = -32002;
    pub const request_cancelled: i64 = -32800;
    pub const content_modified: i64 = -32801;
};
