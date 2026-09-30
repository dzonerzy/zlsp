"""The outline, highlighting, folding, completion and workspace symbols."""

import pytest
from conftest import Client, typed_server

URI = "file:///a.ty"

SRC = """# Shapes
struct Point {
    x: float;
    y: float;
    fn norm() -> float {
        return x * x + y * y;
    }
}

fn origin() -> Point {
    return Point(0.0, 0.0);
}

let p = origin();
let label = "a # not a comment";
print(p.norm(), label, 42, true);
"""


@pytest.fixture
def opened(client):
    client.open(URI, SRC)
    return client


def tokens(client, uri=URI):
    """Semantic tokens as (text, type, modifiers)."""
    legend = client.server_legend
    data = client.request("textDocument/semanticTokens/full", {"textDocument": {"uri": uri}})["data"]
    lines = client.texts[uri].split("\n")
    out = []
    line = char = 0
    for i in range(0, len(data), 5):
        dl, dc, length, t, mods = data[i : i + 5]
        line += dl
        char = char + dc if dl == 0 else dc
        text = lines[line].encode("utf-16-le")[2 * char : 2 * (char + length)].decode("utf-16-le")
        names = {m for bit, m in enumerate(legend["tokenModifiers"]) if mods & (1 << bit)}
        out.append((text, legend["tokenTypes"][t], names))
    return out


@pytest.fixture(autouse=True)
def legend(client):
    # (kept on the client for tokens())
    client.server_legend = client.request("initialize", {"capabilities": {}})["capabilities"]["semanticTokensProvider"]["legend"] if False else None


class TestOutline:
    def test_hierarchical(self):
        c = Client(typed_server())
        c.initialize(textDocument={"documentSymbol": {"hierarchicalDocumentSymbolSupport": True}})
        c.open(URI, SRC)
        symbols = c.request("textDocument/documentSymbol", {"textDocument": {"uri": URI}})

        def shape(entries):
            return [(e["name"], e["kind"], shape(e["children"])) for e in entries]

        assert shape(symbols) == [
            ("Point", 23, [("x", 8, []), ("y", 8, []), ("norm", 12, [])]),
            ("origin", 12, []),
            ("p", 13, []),
            ("label", 13, []),
        ]
        point = symbols[0]
        assert point["range"]["start"] == {"line": 1, "character": 0} and point["range"]["end"] == {"line": 7, "character": 1}
        assert c.text_of(URI, point["selectionRange"]) == "Point"
        assert symbols[1]["detail"] == "fn() -> Point"

    def test_flat(self, opened):
        symbols = opened.request("textDocument/documentSymbol", {"textDocument": {"uri": URI}})
        assert [(s["name"], s["location"]["uri"]) for s in symbols][:2] == [("Point", URI), ("x", URI)]

    def test_workspace_symbols(self, opened):
        found = opened.request("workspace/symbol", {"query": "or"})
        assert sorted(s["name"] for s in found) == ["norm", "origin"]
        everything = opened.request("workspace/symbol", {"query": ""})
        assert [s["name"] for s in everything] == ["Point", "x", "y", "norm", "origin", "p", "label"]


class TestTokens:
    def test_kinds(self, opened):
        opened.server_legend = legend_of(opened)
        toks = tokens(opened)
        assert ("# Shapes", "comment", set()) in toks
        assert ("struct", "keyword", set()) in toks and ("fn", "keyword", set()) in toks and ("return", "keyword", set()) in toks
        assert ("Point", "struct", {"declaration"}) in toks and ("Point", "struct", set()) in toks
        assert ("origin", "function", {"declaration"}) in toks
        assert ("x", "property", {"declaration"}) in toks
        assert ('"a # not a comment"', "string", set()) in toks
        assert ("42", "number", set()) in toks and ("0.0", "number", set()) in toks
        assert ("true", "keyword", set()) in toks
        assert ("print", "function", {"defaultLibrary"}) in toks
        assert ("float", "type", {"defaultLibrary"}) in toks
        # the string's `#` isn't a comment; tokens don't overlap
        assert not any(t == "comment" and "not a comment" in s for s, t, _ in toks)

    def test_positions_after_non_ascii(self, client):
        client.server_legend = legend_of(client)
        client.open(URI, 'let s = "é😀"; let n = 1;\n')
        toks = tokens(client)
        assert ('"é😀"', "string", set()) in toks and ("n", "variable", {"declaration"}) in toks

    def test_multiline_tokens_are_split(self, client):
        client.server_legend = legend_of(client)
        client.open(URI, 'let s = "a\nb";\n')
        assert [t for t in tokens(client) if t[1] == "string"] == [('"a', "string", set()), ('b"', "string", set())]


def legend_of(client):
    c = Client(typed_server())
    return c.request("initialize", {"capabilities": {}})["capabilities"]["semanticTokensProvider"]["legend"]


class TestFolding:
    def test_blocks_and_comments(self, opened):
        opened.change(URI, "# one\n# two\n# three\n" + SRC)
        folds = opened.request("textDocument/foldingRange", {"textDocument": {"uri": URI}})
        spans = [(f["startLine"], f["endLine"], f.get("kind")) for f in folds]
        # the comment run, the struct (closing brace line left out), its method, the function
        assert (0, 3, "comment") in spans
        assert (4, 9, None) in spans and (7, 8, None) in spans and (12, 12, None) not in spans

    def test_configured(self):
        c = Client(typed_server(folding="struct_def"))
        c.initialize()
        c.open(URI, SRC)
        folds = c.request("textDocument/foldingRange", {"textDocument": {"uri": URI}})
        assert [(f["startLine"], f["endLine"]) for f in folds if f.get("kind") != "comment"] == [(1, 6)]


class TestCompletion:
    def labels(self, client, text, at, delta=0):
        client.change(URI, text)
        result = client.request("textDocument/completion", client.at(URI, at, delta))
        return [i["label"] for i in result["items"]]

    def test_visible_names(self, opened):
        items = self.labels(opened, "fn f(a: int) -> int {\n    let b = a;\n    return b;\n}\nlet later = 1;\n", "return b", 7)
        # innermost first, the rest after; keywords last
        assert items[:4] == ["a", "b", "f", "later"]
        assert "print" in items and items.index("print") > items.index("later")
        assert "return" in items and "while" in items

    def test_items(self, opened):
        opened.change(URI, "fn f(a: int) -> int {\n    return a;\n}\nlet x = f(1);\n")
        result = opened.request("textDocument/completion", opened.at(URI, "f(1)"))
        f = next(i for i in result["items"] if i["label"] == "f")
        assert f["kind"] == 3 and f["detail"] == "fn(int) -> int"
        kw = next(i for i in result["items"] if i["label"] == "let")
        assert kw["kind"] == 14

    def test_members(self, opened):
        text = SRC + "print(p.)\n"
        items = self.labels(opened, text, "p.)", 2)
        assert items == ["x", "y", "norm"]

    def test_members_of_a_struct_name(self, opened):
        items = self.labels(opened, SRC + "Point.\n", "Point.\n", 6)
        assert items == ["x", "y", "norm"]

    def test_while_typing(self, opened):
        # the file doesn't parse at the cursor: completion still works
        opened.change(URI, "let alpha = 1;\nlet beta = al")
        result = opened.request("textDocument/completion", opened.at(URI, "al", 2, occurrence=1))
        items = [i["label"] for i in result["items"]]
        assert "alpha" in items and "beta" not in items

    def test_members_through_a_chain_and_imports(self, tmp_path):
        from conftest import uri_of

        (tmp_path / "shapes.ty").write_text("struct Point { x: float; y: float; }\nstruct Line { a: Point; b: Point; }\n")
        c = Client(typed_server())
        c.initialize(root=uri_of(tmp_path))
        uri = uri_of(tmp_path / "main.ty")
        c.open(uri, "from shapes import Line;\nfn f(l: Line) -> float {\n    return l.a.\n}\n")
        result = c.request("textDocument/completion", c.at(uri, "l.a.", 4))
        assert [i["label"] for i in result["items"]] == ["x", "y"]
