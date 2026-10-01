"""A language server for tiny, a small language: zgram parses it, zrules
checks it, zlsp serves it to an editor.

    python tiny.py              # speaks LSP over stdin/stdout: point your editor at it
    python tiny.py --textmate   # prints its TextMate grammar (for VS Code)

The editor gets, as you type: syntax errors (every one, not just the first),
'break' outside a loop, 'return' outside a function, undefined and duplicate
names; go to definition, find references, rename, hover, the outline,
highlighting, folding and completion.
"""

import sys

import zgram
from zlsp import Server
from zrules import Rules, forbid, inside, scopes

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
    ],
)


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
    )


if __name__ == "__main__":
    if "--textmate" in sys.argv:
        # the TextMate grammar of editors/vscode/syntaxes/tiny.tmLanguage.json
        import json

        print(json.dumps(json.loads(make_server().textmate()), indent=2))
        sys.exit(0)
    sys.exit(make_server().start_io())
