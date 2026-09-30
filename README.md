<div align="center">

<img src="https://raw.githubusercontent.com/dzonerzy/zlsp/main/docs/assets/logo.svg" alt="zlsp Logo" width="150">

# zlsp

**A native language server for any language defined with [zgram](https://github.com/dzonerzy/zgram) and checked with [zrules](https://github.com/dzonerzy/zrules).**

Write the grammar and the rules; zlsp gives your language an editor: errors as you type, go to definition, find references, rename, hover, outline, highlighting, folding and completion, in VS Code, Neovim, Helix, Emacs or any editor that speaks the Language Server Protocol.

[![GitHub Stars](https://img.shields.io/github/stars/dzonerzy/zlsp?style=flat)](https://github.com/dzonerzy/zlsp)
[![Python](https://img.shields.io/badge/python-3.10+-blue)](https://www.python.org/)
[![Zig](https://img.shields.io/badge/zig-0.16+-orange)](https://ziglang.org/)
[![License](https://img.shields.io/badge/license-MIT-green)](https://github.com/dzonerzy/zlsp/blob/main/LICENSE)

Built with [PyOZ](https://github.com/pyozig/PyOZ)

</div>

---

```python
from zlsp import Server

Server(
    parser, rules,                       # your zgram parser and zrules rules
    name="tiny",
    extensions=[".tiny"],
    symbols={"FuncDef > .name": "function", "Let > .name": "variable"},
    tokens={"number": "number", "string": "string"},
    comments=["#"],
).start_io()
```

That's the whole server. What your editor gets:

- **Diagnostics as you type**: every syntax error in the file (zgram's error recovery, not just the first), and every finding of your rules around them: undefined names, type errors, unreachable code. Nothing is reported about the broken text itself, or because of it.
- **Navigation**: go to definition and declaration, find references, highlight occurrences, rename, across the files of the project through imports.
- **Hover**: what a name is and its type.
- **Outline and workspace symbols**: the definitions of the file, nested by scope, and a project-wide search.
- **Semantic highlighting**: keywords from the grammar, names by what they are (functions, parameters, types, fields...), definitions marked, builtins marked, numbers, strings and comments.
- **Folding**: blocks and runs of comments.
- **Completion**: the names visible at the cursor, the members after `a.b.`, and the keywords.

The protocol, the documents and every feature are native (Zig); Python only configures the server and runs your rules.

## Performance

Every edit parses and checks the whole file again, and the project around it: that is fast enough for any file a person edits. With the typed example language (names, types and flow checked), after each keystroke:

| File | Parse, check, publish | Semantic tokens | Outline | Completion |
|------|----------------------|-----------------|---------|------------|
| 54 KB (500 functions) | 2.2 ms | 1.6 ms | 0.7 ms | 0.6 ms |
| 553 KB (5,000 functions) | 18.5 ms | 13.5 ms | 6.3 ms | 5.5 ms |

A burst of keystrokes costs one analysis: edits are applied as they arrive, and the analysis runs when no more input is waiting. Only the edited file is parsed again; zrules checks the project in parallel.

## An example: tiny

[`examples/tiny/tiny.py`](https://github.com/dzonerzy/zlsp/blob/main/examples/tiny/tiny.py) is a complete language server in about 90 lines: the grammar, the rules (`break` outside a loop, `return` outside a function, undefined, duplicate and unused names), and the `Server`. `python tiny.py` speaks LSP over stdin and stdout; point your editor at it (below) and open [`fib.tiny`](https://github.com/dzonerzy/zlsp/blob/main/examples/tiny/fib.tiny).

## Installation

```bash
pip install zlsp-py
```

The import name is `zlsp`. Pre-built wheels for Linux (x86_64) and Windows (x86_64), CPython 3.10+; zgram and zrules come with it.

### From source

```bash
git clone https://github.com/dzonerzy/zlsp
cd zlsp
pip install pyoz
pyoz build --release
pip install dist/*.whl
```

## Quick Start

1. Write the language: a zgram grammar and zrules rules (see their documentation). A `scopes()` rule gives the names (definition, references, rename, completion); a `types()` rule adds types to hover and completion.
2. Write the server script: `Server(parser, rules, ...).start_io()`.
3. Tell your editor to run the script for the language's files.

## Editors

The server is a program that speaks LSP over stdin and stdout: `python /path/to/server.py`. Each editor needs to know which files it serves.

**Neovim** (0.11+), in `init.lua`:

```lua
vim.filetype.add({ extension = { tiny = "tiny" } })
vim.lsp.config("tiny", {
  cmd = { "python", "/path/to/tiny.py" },
  filetypes = { "tiny" },
  root_markers = { ".git" },
})
vim.lsp.enable("tiny")
```

**Helix**, in `languages.toml`:

```toml
[language-server.tiny]
command = "python"
args = ["/path/to/tiny.py"]

[[language]]
name = "tiny"
scope = "source.tiny"
file-types = ["tiny"]
comment-token = "#"
language-servers = ["tiny"]
```

**Emacs** (eglot):

```elisp
(define-derived-mode tiny-mode prog-mode "tiny")
(add-to-list 'auto-mode-alist '("\\.tiny\\'" . tiny-mode))
(with-eval-after-load 'eglot
  (add-to-list 'eglot-server-programs '(tiny-mode "python" "/path/to/tiny.py")))
```

**VS Code** starts language servers from extensions: [`editors/vscode`](https://github.com/dzonerzy/zlsp/tree/main/editors/vscode) is a minimal one to copy (a language id, its file extensions, and the command that runs the server).

## Configuration

```python
Server(parser, rules=None, *, name=None, version=None, extensions=None, resolve=None,
       symbols=None, tokens=None, comments=None, folding=None, keywords=None)
```

| Option | |
|--------|---|
| `parser` | the zgram parser |
| `rules` | the zrules `Rules`; without them, the server reports syntax errors only |
| `name`, `version` | what the server calls itself (the diagnostics' source, the language in hovers) |
| `extensions` | the language's file extensions (`[".tiny"]`): the files of the workspace, read from disk and checked together, so imports resolve and every file's problems are listed |
| `resolve` | as zrules' `analyze_project`: `resolve(module, importing_key) -> key or None`. A file's key is its path under the workspace without the extension (`lib/util`) |
| `symbols` | `{selector: kind}`: what the names defined by the matching nodes are, for the outline, highlighting and completion (`"FuncDef > .name": "function"`). Kinds: `variable`, `function`, `method`, `parameter`, `constant`, `type`, `class`, `struct`, `enum`, `enumMember`, `interface`, `property`, `field`, `namespace`, `module`, `typeParameter`, `event`, `operator`. With `symbols`, the outline shows only the names of these kinds |
| `tokens` | `{selector: token type}`: highlighting for nodes (`"number": "number"`, `"string": "string"`). Types: LSP's semantic token types (`number`, `string`, `comment`, `keyword`, `operator`, `type`, `function`, `variable`, ...) |
| `comments` | the comment syntax: line prefixes (`"#"`, `"//"`) and `(open, close)` pairs (`("/*", "*/")`), for highlighting and folding |
| `folding` | selectors of the foldable nodes; by default every node with children that spans lines |
| `keywords` | the keywords, for highlighting and completion; by default the grammar's word literals (`parser.literals()`) |

Selectors are zrules selectors. Names defined without a configured kind show as functions if their type is a function's, as types if they name a type, and as variables otherwise.

## Features in detail

**Diagnostics.** Each file of the project gets the syntax errors of its text and the findings of the rules, published when they change. A file that isn't open is read from disk; an open one uses the editor's text. Notes attached to a finding ("first defined here") become related information when the editor supports it.

**Definition, references, rename.** From the symbol table of the `scopes()` rule. A name imported from another file leads to its definition there, and references and renames include every file that imports it. Builtins can't be renamed.

**Hover.** The kind, name and type of the name under the cursor: `function f: fn(int) -> int`.

**Highlighting.** Each character belongs to at most one token, taken in this order: comments, strings, names (their kind, `declaration` on definitions, `defaultLibrary` on builtins), the other token rules, keywords. Multi-line tokens are split per line unless the editor takes them whole.

**Completion.** The names a name written at the cursor could refer to, by the scope rules (ordering, hoisting, imports), innermost first, then builtins, then keywords. After a `.`, the members of what the name chain before it stands for: a struct's fields and methods, a module's names, the fields of a variable's type. The chain is read from the text, since the line being typed rarely parses.

**Positions** are in UTF-16 code units, as LSP expects, or UTF-8 when the editor offers it.

## API Reference

| | |
|---|---|
| `Server(parser, rules=None, **options)` | a language server (see Configuration) |
| `server.start_io()` | serve over stdin/stdout until the editor sends `exit` or closes the input; returns the exit code (0 after `shutdown`). While it serves, `sys.stdout` is `sys.stderr`, so a `print()` in a rule doesn't break the protocol |
| `server.handle(message)` | run one JSON-RPC message (`str` or `bytes`) and return the messages to send (JSON `str`s), diagnostics included: for tests, and for embedding the server in another transport |
| `server.exit_code` | set once the editor sent `exit` |
| `zlsp.version()` | the version |

A rule raising an exception doesn't stop the server: the editor gets a `window/logMessage` with the error, and the files keep their syntax errors until the rule works again.

## Architecture

```
editor ──stdin──► reader thread ──queue──► main loop ──stdout──► editor
                  (frames messages)        │
                                           ├─ documents: text, line index, UTF-8/16 positions
                                           ├─ when idle: parse changed files (zgram, recover=True)
                                           │             check the project (zrules, in parallel)
                                           │             read trees and symbols through capsules
                                           └─ requests: answered from the native copies
```

- **One thread with the GIL**, which waits for input without it. A second thread only reads stdin.
- **Native all the way.** Trees are read through zgram's `zgram.tree.v1` capsule, the symbol table through zrules' `zrules.analysis.v1`, and selectors run through `zrules.selector.v1`: no Python object is made per node, symbol or use.
- **Debounced by the input**: edits are applied as they arrive; the analysis runs when the input queue is empty, so a burst of keystrokes costs one.
- **Cancellation**: a request cancelled before the server reached it is answered with `RequestCancelled`.

## Known Issues

- Incremental parsing: every edit parses the whole file again (18 ms for 553 KB, well within typing speed for files people edit).
- Semantic tokens are sent whole, not as deltas.
- Formatting, code actions and signature help are not provided.

## Project Structure

```
src/
  lib.zig          # Python module: Server, configuration, the stdin/stdout loop
  server.zig       # LSP messages and every feature
  project.zig      # workspace files, parsing and checking, the native copies of the results
  document.zig     # text, edits, line index, UTF-8/UTF-16 positions
  transport.zig    # Content-Length framing
  json.zig         # writing JSON; reading helpers over std.json
  uri.zig          # file:// URIs and paths
  lsp.zig          # symbol kinds, token types, error codes
  tree.zig         # zgram's tree capsule (consumer copy)
  zrules_abi.zig   # zrules' analysis and selector capsules (consumer copy)
  pyhelp.zig       # Python C API helpers
examples/tiny/     # a complete language server for a small language
editors/vscode/    # a VS Code extension to copy
test/              # the protocol, diagnostics, navigation, features, over stdio
```

## License

MIT
