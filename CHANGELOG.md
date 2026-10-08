# Changelog

All notable changes to zlsp are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.3] - 2026-10-08

### Changed
- Requires zgram 0.5.0 and zrules 0.2.0. A language's generic functions and types, unions and subtypes (zrules' `types()`) show in hovers, completions and diagnostics as zrules writes them (`fn(list[T]) -> T`, `int | str`), and its type parameters are names like any other (definition, references, rename); recovery from syntax errors keeps more of a broken file's structure (zgram's), and grammars compile once per machine (zgram's disk cache): the server starts faster.

## [0.1.2] - 2026-10-07

### Changed
- Built with PyOZ 0.13.10: on Windows, Python's data (None, the exceptions, the types) read at run time, never a constant holding an import slot's address (the Windows wheel of 0.1.1 had none, now one can't be built).

## [0.1.1] - 2026-10-07

### Changed
- Built with PyOZ 0.13.9.

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
- **Signature help**, **inlay hints** (inferred types), **type definition**, **selection ranges**, **code actions** (typo quick fixes for undefined names and members), **doc comments** in hover, **context-aware keyword completion** (zgram's `expected()`), **semantic token deltas**.
- **Hooks**: `hover=`, `completion=`, `code_actions=`, `format=` (document formatting), `configuration=` (workspace/didChangeConfiguration).
- **`log=`**: a log file of every message and analysis, timed.
- **`textmate()`**: a TextMate grammar generated from the grammar and the configuration.
- **Incremental checking**: an edit checks the edited files, their importers and what those import; an idle analysis gives way to incoming messages.
- **Workspace folders** added and removed at runtime; files with the same path in two folders kept apart, an import resolving in the importing file's folder.
- **Settings**: asked of the editor (`workspace/configuration`) at start and on each change, for the `configuration` hook (`section=`); pushed settings for editors that can't be asked.
- **Tracing**: `$/setTrace` and `$/logTrace` with each request's and analysis's time.
- **`examples/tiny`**: a complete server for a small language, using every hook; **`editors/vscode`**: an extension template with its TextMate grammar, tested in VS Code; **`editors/neovim/test.lua`**: the same features tested in Neovim.
