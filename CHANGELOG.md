# Changelog

All notable changes to zlsp are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - 2026-10-01

### Added
- **`Server(parser, rules, ...)`**: a Language Server Protocol server for a language defined with zgram and checked with zrules, configured with selectors (`symbols=`, `tokens=`, `folding=`), comment syntax, keywords and the language's file extensions.
- **Diagnostics as you type**: every syntax error (zgram's error recovery) and the rules' findings, for each file of the workspace, published when they change.
- **Navigation**: definition, declaration, references, document highlight, rename (with prepare), across files through imports.
- **Hover**, **document symbols** (hierarchical or flat), **workspace symbols**.
- **Semantic tokens**: keywords from the grammar, names by kind with `declaration` and `defaultLibrary`, numbers, strings, comments; no overlaps; split per line unless the client takes multi-line tokens.
- **Folding** of blocks and comment runs; **completion** of visible names, members after `.` through name chains and imports, and keywords.
- UTF-16 positions, or UTF-8 when the client offers it; incremental document sync; watched-file notifications; `$/cancelRequest`.
- **`start_io()`**: serves over stdin/stdout, analyzing when the input is idle; `sys.stdout` goes to stderr while it serves. **`handle(message)`** runs one message without I/O.
- **`examples/tiny`**: a complete server for a small language; **`editors/vscode`**: an extension template.
