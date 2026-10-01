"""A language server for tiny, a small language: zgram parses it, zrules
checks it, zlsp serves it to an editor.

    python tiny.py              # speaks LSP over stdin/stdout: point your editor at it
    python tiny.py --textmate   # prints its TextMate grammar (for VS Code)

The editor gets, as you type: syntax errors (every one, not just the first),
'break' outside a loop, 'return' outside a function, undefined and duplicate
names; go to definition, find references, rename, hover, signature help,
quick fixes, the outline, highlighting, folding and completion.

The hooks at the end add what only the language knows: the builtins' docs in
hover, snippets in completion, a quick fix that removes a stray 'break', a
formatter, and a setting (tiny.maxLineLength) for a rule of its own.
"""

import sys

import zgram
from zlsp import Server
from zrules import Rules, custom, forbid, inside, scopes

GRAMMAR = r"""
program     = ws (body:stmt ws)*                                      -> Program
@silent stmt = funcdef | while_stmt | if_stmt | return_stmt | break_stmt
             | let_stmt | assign | expr_stmt
funcdef     = 'fn' kw ws name:ident ws '(' ws (params:ident (ws ',' ws params:ident)*)? ws ')' ws body:block  -> FuncDef
block       = '{' ws (stmt ws)* '}'                                   -> list
while_stmt  = 'while' kw ws cond:expr ws body:block                   -> While
if_stmt     = 'if' kw ws cond:expr ws then:block (ws 'else' kw ws else_:block)?  -> If
return_stmt = 'return' kw (ws value:expr)? ws ';'                     -> Return
break_stmt  = 'break' kw ws ';'                                       -> Break()
let_stmt    = 'let' kw ws name:ident ws '=' ws value:expr ws ';'      -> Let
assign      = name:ident ws '=' !'=' ws value:expr ws ';'             -> Assign
@silent expr_stmt = expr ws ';'

@left expr "expression" = left:sum (ws op:cmpop ws right:sum)?        -> BinOp
@left sum  "expression" = left:term (ws op:addop ws right:term)*      -> BinOp
@left term "expression" = left:operand (ws op:mulop ws right:operand)*  -> BinOp
@silent operand = neg | primary
neg         = '-' ws operand:operand                                  -> Neg
@silent primary = number | string | call | ident | '(' ws expr ws ')'
call        = name:ident ws '(' ws (args:expr (ws ',' ws args:expr)*)? ws ')'  -> Call

number      = [0-9]+ ('.' [0-9]+)?                                    -> float
string      = '"' ('\\' . | [^"\\])* '"'                              -> unquote
ident "name"       = !keyword [a-zA-Z_] [a-zA-Z0-9_]*                 -> Name
cmpop "operator"   = '==' | '!=' | '<=' | '>=' | '<' | '>'            -> str
addop "operator"   = [+\-]                                            -> str
mulop "operator"   = [*/%]                                            -> str

@silent keyword = ('fn' | 'while' | 'if' | 'else' | 'return' | 'break' | 'let') kw
@silent kw      = ![a-zA-Z0-9_]
@silent ws      = ([ \t\n\r] | '#' [^\n]*)*
"""

PARSER = zgram.compile(GRAMMAR)

# The editor's settings for tiny (`tiny.*`), from the configuration hook
SETTINGS = {"maxLineLength": 0}


def long_lines(node, ctx):
    """A warning on each line longer than tiny.maxLineLength (0: off)."""
    limit = SETTINGS["maxLineLength"]
    if not limit:
        return
    at = node.start()
    for line in node.text().encode().split(b"\n"):
        if len(line.decode(errors="replace")) > limit:
            ctx.warning((at, at + len(line)), f"line longer than {limit} characters", code="line-too-long")
        at += len(line) + 1


RULES = Rules(
    PARSER,
    [
        inside("Break", within="While", stop_at="FuncDef", code="break-outside-loop", message="'break' outside loop"),
        inside("Return", within="FuncDef", code="return-outside-function", message="'return' outside function"),
        forbid("FuncDef FuncDef", code="nested-function", message="functions cannot be defined inside functions"),
        # One namespace: variables, parameters and functions. A function's own
        # name belongs to the scope outside it and is visible before its
        # definition; everything else is visible from its definition on.
        scopes(
            scope=("Program", "FuncDef"),
            define=("Let > .name", "FuncDef > .params"),
            define_outer="FuncDef > .name",
            use="Name",
            hoist="FuncDef > .name",
            after="Let > .name",  # `let a = a;` does not see the new `a`
            builtins=("print",),
            on_unused="warning",
        ),
        custom("Program", long_lines),
    ],
)

# ---------------------------------------------------------------------------
# Hooks
# ---------------------------------------------------------------------------

BUILTIN_DOCS = {"print": "Writes its arguments, separated by spaces, then a new line."}


def hover(uri, text, offset, analysis):
    """The docs of a builtin, below what the server shows of it."""
    data = text.encode()
    start = end = offset
    while start > 0 and (data[start - 1 : start].isalnum() or data[start - 1 : start] == b"_"):
        start -= 1
    while end < len(data) and (data[end : end + 1].isalnum() or data[end : end + 1] == b"_"):
        end += 1
    return BUILTIN_DOCS.get(data[start:end].decode())


SNIPPETS = {
    "fn": "fn ${1:name}(${2}) {\n\t$0\n}",
    "while": "while ${1:condition} {\n\t$0\n}",
    "if": "if ${1:condition} {\n\t$0\n}",
}


def completion(uri, text, offset, analysis):
    """Snippets for the statements with a block, where the grammar takes
    their keyword (zgram's expected(), given the text before the word)."""
    data = text.encode()
    start = offset
    while start > 0 and (data[start - 1 : start].isalnum() or data[start - 1 : start] == b"_"):
        start -= 1
    allowed = PARSER.expected(data[:start]) or SNIPPETS
    return [{"label": k, "kind": 15, "detail": f"{k} ... {{ }}", "insertText": v, "insertTextFormat": 2} for k, v in SNIPPETS.items() if k in allowed]


def code_actions(uri, text, start, end, diagnostics, analysis):
    """Removing a 'break' outside a loop: the statement and its line, if it's alone there."""
    actions = []
    data = text.encode()
    for d in diagnostics:
        if d["code"] != "break-outside-loop":
            continue
        s, e = d["start"], d["end"]
        line_start = data.rfind(b"\n", 0, s) + 1
        line_end = data.find(b"\n", e)
        line_end = len(data) if line_end < 0 else line_end + 1
        if not data[line_start:s].strip() and not data[e:line_end].strip():
            s, e = line_start, line_end
        actions.append({"title": "Remove the 'break'", "edits": [(s, e, "")], "preferred": True})
    return actions


def format(uri, text, analysis):
    """Indents by 4 spaces a level of braces (outside strings and comments);
    no trailing spaces; one new line at the end."""
    out = []
    depth = 0
    for raw in text.split("\n"):
        line = raw.strip()
        code = _code_of(line)
        closing = len(code) - len(code.lstrip("}"))
        level = max(depth - closing, 0)
        out.append("    " * level + line if line else "")
        depth = max(depth + code.count("{") - code.count("}"), 0)
    return "\n".join(out).rstrip("\n") + "\n"


def _code_of(line):
    """The line without its strings and comment."""
    code, quoted, escaped = [], False, False
    for ch in line:
        if quoted:
            quoted = escaped or ch != '"'
            escaped = not escaped and ch == "\\"
        elif ch == '"':
            quoted = True
        elif ch == "#":
            break
        else:
            code.append(ch)
    return "".join(code)


def configuration(settings):
    """The editor's tiny.* settings changed."""
    settings = settings or {}
    SETTINGS["maxLineLength"] = int(settings.get("maxLineLength") or 0)


def make_server():
    return Server(
        PARSER,
        RULES,
        name="tiny",
        extensions=[".tiny"],
        # What names are, for the outline, highlighting and completion
        symbols={"FuncDef > .name": "function", "FuncDef > .params": "parameter", "Let > .name": "variable"},
        tokens={"number": "number", "string": "string", "cmpop, addop, mulop": "operator"},
        comments=["#"],
        hover=hover,
        completion=completion,
        code_actions=code_actions,
        format=format,
        configuration=configuration,
    )


if __name__ == "__main__":
    if "--textmate" in sys.argv:
        # the TextMate grammar of editors/vscode/syntaxes/tiny.tmLanguage.json
        import json

        print(json.dumps(json.loads(make_server().textmate()), indent=2))
        sys.exit(0)
    sys.exit(make_server().start_io())
