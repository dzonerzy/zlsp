"""Inlay hints, type definitions, signature help, selection ranges, code
actions, doc comments, semantic token deltas; the Python hooks; workspace
folders and the configuration; the log; the TextMate grammar."""

import json

import pytest
from conftest import Client, typed_server, uri_of

URI = "file:///a.ty"

SRC = """# A point in the plane
struct Point {
    x: float;
    y: float;
}

# Where the axes cross.
# (the second line of its doc)
fn origin() -> Point {
    return Point(0.0, 0.0);
}

fn scale(p: Point, by: float) -> Point {
    return Point(p.x * by, p.y * by);
}

let p = origin();
let n: int = 1;
let count = 2;
"""


def opened(server=None, text=SRC, **caps):
    c = Client(server or typed_server())
    c.initialize(**caps)
    c.open(URI, text)
    return c


class TestInlayHints:
    def test_inferred_types(self):
        c = opened()
        whole = {"start": {"line": 0, "character": 0}, "end": {"line": 100, "character": 0}}
        hints = c.request("textDocument/inlayHint", {"textDocument": {"uri": URI}, "range": whole})
        labels = {(h["position"]["line"], h["label"]) for h in hints}
        # `let p` and `let count` don't write their types; `let n: int`,
        # the fields and the parameters do; functions and structs get none
        assert labels == {(16, ": Point"), (18, ": int")}
        p = next(h for h in hints if h["label"] == ": Point")
        assert p["position"] == c.pos(URI, "p = origin", 1) and p["kind"] == 1

    def test_only_in_the_range(self):
        c = opened()
        line16 = {"start": {"line": 16, "character": 0}, "end": {"line": 17, "character": 0}}
        hints = c.request("textDocument/inlayHint", {"textDocument": {"uri": URI}, "range": line16})
        assert [h["label"] for h in hints] == [": Point"]


class TestTypeDefinition:
    def test_of_a_variable(self):
        c = opened()
        loc = c.request("textDocument/typeDefinition", c.at(URI, "p = origin"))
        assert loc["uri"] == URI and c.text_of(URI, loc["range"]) == "Point"
        assert loc["range"]["start"] == c.pos(URI, "Point {")

    def test_of_a_parameter(self):
        c = opened()
        loc = c.request("textDocument/typeDefinition", c.at(URI, "p.x * by"))
        assert loc["range"]["start"] == c.pos(URI, "Point {")

    def test_of_a_basic_type(self):
        c = opened()
        assert c.request("textDocument/typeDefinition", c.at(URI, "count")) is None


class TestSignatureHelp:
    def help(self, c, needle, delta=0):
        return c.request("textDocument/signatureHelp", c.at(URI, needle, delta))

    def test_while_typing_a_call(self):
        c = opened(text=SRC + "let q = scale(p, ")
        h = self.help(c, "scale(p, ", 9)
        sig = h["signatures"][0]
        assert sig["label"] == "scale(p: Point, by: float) -> Point"
        assert h["activeParameter"] == 1
        params = [sig["label"][s:e] for s, e in (p["label"] for p in sig["parameters"])]
        assert params == ["p: Point", "by: float"]

    def test_the_first_argument_and_docs(self):
        c = opened(text=SRC + "let o = origin(")
        h = self.help(c, "origin(", 7, )
        sig = h["signatures"][0]
        assert sig["label"] == "origin() -> Point" and h["activeParameter"] == 0
        assert sig["documentation"]["value"] == "Where the axes cross.\n(the second line of its doc)"

    def test_nested_calls(self):
        c = opened(text=SRC + "let q = scale(origin(), len(")
        assert self.help(c, "len(", 4)["signatures"][0]["label"].startswith("len(")
        c.change(URI, SRC + "let q = scale(origin(), ")
        h = self.help(c, "origin(), ", 10)
        assert h["signatures"][0]["label"].startswith("scale(") and h["activeParameter"] == 1

    def test_outside_a_call(self):
        c = opened()
        assert self.help(c, "count") is None


class TestSelectionRange:
    def test_word_then_outward(self):
        c = opened()
        result = c.request("textDocument/selectionRange", {"textDocument": {"uri": URI}, "positions": [c.pos(URI, "by: float", 1)]})
        texts = []
        r = result[0]
        while r:
            texts.append(c.text_of(URI, r["range"]))
            r = r.get("parent")
        assert texts[0] == "by"
        assert "by: float" in texts
        assert any(t.startswith("fn scale(") and t.endswith("}") for t in texts)
        assert texts[-1] == SRC
        # each contains the one before
        assert all(a in b for a, b in zip(texts, texts[1:]))


class TestCodeActions:
    def test_did_you_mean(self):
        c = opened(text=SRC + "print(cuont);\n")
        diag = next(d for d in c.diagnostics[URI] if "cuont" in d["message"])
        actions = c.request("textDocument/codeAction", {"textDocument": {"uri": URI}, "range": diag["range"], "context": {"diagnostics": [diag]}})
        assert actions[0]["title"] == "Change to 'count'" and actions[0]["isPreferred"]
        edit = actions[0]["edit"]["changes"][URI][0]
        assert edit["newText"] == "count" and edit["range"] == diag["range"]
        assert actions[0]["diagnostics"][0]["message"] == diag["message"]

    def test_a_member(self):
        c = opened(text=SRC + "print(p.z);\n")
        diag = next(d for d in c.diagnostics[URI] if "'z'" in d["message"])
        actions = c.request("textDocument/codeAction", {"textDocument": {"uri": URI}, "range": diag["range"], "context": {"diagnostics": [diag]}})
        assert sorted(a["title"] for a in actions) == ["Change to 'x'", "Change to 'y'"]

    def test_nothing_close(self):
        c = opened(text=SRC + "print(zzzzzz);\n")
        diag = next(d for d in c.diagnostics[URI] if "zzzzzz" in d["message"])
        assert c.request("textDocument/codeAction", {"textDocument": {"uri": URI}, "range": diag["range"], "context": {"diagnostics": [diag]}}) == []


class TestHover:
    def test_doc_comments(self):
        c = opened(text=SRC + "let o = origin();\n")
        value = c.request("textDocument/hover", c.at(URI, "origin();", occurrence=1))["contents"]["value"]
        assert value.endswith("\n\nWhere the axes cross.\n(the second line of its doc)")
        value = c.request("textDocument/hover", c.at(URI, "Point {"))["contents"]["value"]
        assert value.endswith("A point in the plane")

    def test_no_doc_after_a_blank_line(self):
        c = opened(text="# not about x\n\nlet x = 1;\n")
        value = c.request("textDocument/hover", c.at(URI, "x ="))["contents"]["value"]
        assert "about" not in value


class TestTokenDeltas:
    def test_delta(self):
        c = opened()
        full = c.request("textDocument/semanticTokens/full", {"textDocument": {"uri": URI}})
        assert full["resultId"]
        c.change(URI, SRC + "let more = count;\n")
        d = c.request("textDocument/semanticTokens/full/delta", {"textDocument": {"uri": URI}, "previousResultId": full["resultId"]})
        assert d["resultId"] != full["resultId"]
        # applying the edits gives the full tokens
        data = list(full["data"])
        for e in d["edits"]:
            data[e["start"] : e["start"] + e["deleteCount"]] = e.get("data", [])
        again = c.request("textDocument/semanticTokens/full", {"textDocument": {"uri": URI}})
        assert data == again["data"]
        # only the tail changed
        assert len(d["edits"]) == 1 and d["edits"][0]["start"] >= len(full["data"]) - 5

    def test_unchanged(self):
        c = opened()
        full = c.request("textDocument/semanticTokens/full", {"textDocument": {"uri": URI}})
        d = c.request("textDocument/semanticTokens/full/delta", {"textDocument": {"uri": URI}, "previousResultId": full["resultId"]})
        assert d["edits"] == []

    def test_unknown_previous_result(self):
        c = opened()
        d = c.request("textDocument/semanticTokens/full/delta", {"textDocument": {"uri": URI}, "previousResultId": "nope"})
        assert "data" in d and "edits" not in d


class TestHooks:
    def test_hover(self):
        calls = []

        def hover(uri, text, offset, analysis):
            calls.append((uri, text[offset : offset + 5], analysis is not None))
            return None if text.startswith("struct", offset) else "**more**"

        c = opened(typed_server(hover=hover))
        value = c.request("textDocument/hover", c.at(URI, "count"))["contents"]["value"]
        assert value.endswith("\n\n---\n\n**more**") and value.startswith("```typed\nvariable count")
        assert calls == [(URI, "count", True)]
        # on nothing: what the hook says alone
        assert c.request("textDocument/hover", c.at(URI, "    x"))["contents"]["value"] == "**more**"
        assert c.request("textDocument/hover", c.at(URI, "struct")) is None

    def test_completion(self):
        def completion(uri, text, offset, analysis):
            return ["snippet", {"label": "fancy", "kind": 15, "insertText": "fancy()"}, "count"]

        c = opened(typed_server(completion=completion), text=SRC + "let z = c")
        items = c.request("textDocument/completion", c.at(URI, "z = c", 5))["items"]
        labels = [i["label"] for i in items]
        assert "snippet" in labels and labels.count("count") == 1
        fancy = next(i for i in items if i["label"] == "fancy")
        assert fancy == {"label": "fancy", "kind": 15, "insertText": "fancy()"}

    def test_code_actions(self):
        seen = []

        def code_actions(uri, text, start, end, diagnostics, analysis):
            seen.append((start, end, [d["code"] for d in diagnostics]))
            return [{"title": "Rename to total", "edits": [(start, end, "total")], "preferred": True}, {"title": "Nothing"}]

        c = opened(typed_server(code_actions=code_actions), text=SRC + "print(zzz);\n")
        start = SRC.encode().__len__() + 6
        rng = {"start": c.pos(URI, "zzz"), "end": c.pos(URI, "zzz", 3)}
        actions = c.request("textDocument/codeAction", {"textDocument": {"uri": URI}, "range": rng, "context": {"diagnostics": []}})
        assert seen == [(start, start + 3, ["undefined-name"])]
        assert actions[0] == {
            "title": "Rename to total",
            "kind": "quickfix",
            "isPreferred": True,
            "edit": {"changes": {URI: [{"range": rng, "newText": "total"}]}},
        }
        assert actions[1] == {"title": "Nothing", "kind": "quickfix"}

    def test_format(self):
        def fmt(uri, text, analysis):
            return text.replace("  ", " ")

        c = Client(typed_server(format=fmt))
        caps = c.initialize()["capabilities"]
        assert caps["documentFormattingProvider"] is True
        c.open(URI, "let  a = 1;\n")
        edits = c.request("textDocument/formatting", {"textDocument": {"uri": URI}, "options": {"tabSize": 4, "insertSpaces": True}})
        assert [e["newText"] for e in edits] == ["let a = 1;\n"]
        assert c.text_of(URI, edits[0]["range"]) == "let  a = 1;\n"
        c.change(URI, "let a = 1;\n")
        assert c.request("textDocument/formatting", {"textDocument": {"uri": URI}, "options": {}}) == []

    def test_no_format_hook(self):
        c = Client(typed_server())
        assert "documentFormattingProvider" not in c.initialize()["capabilities"]

    def test_a_hook_raising_is_logged(self):
        def hover(uri, text, offset, analysis):
            raise ValueError("boom")

        c = opened(typed_server(hover=hover))
        value = c.request("textDocument/hover", c.at(URI, "count"))["contents"]["value"]
        assert value.startswith("```typed\nvariable count")
        logs = [n["params"]["message"] for n in c.notifications if n["method"] == "window/logMessage"]
        assert any("the hover hook failed: ValueError: boom" in m for m in logs)

    def test_a_hook_must_be_callable(self):
        with pytest.raises(TypeError, match="hover must be callable"):
            typed_server(hover=1)

    def test_configuration(self):
        got = []
        c = opened(typed_server(configuration=got.append))
        c.notify("workspace/didChangeConfiguration", {"settings": {"typed": {"strict": True}}})
        assert got == [{"typed": {"strict": True}}]


class TestWorkspaceFolders:
    def test_added_and_removed(self, tmp_path):
        a, b = tmp_path / "a", tmp_path / "b"
        a.mkdir()
        b.mkdir()
        (a / "one.ty").write_text("let one = 1;\n")
        (b / "two.ty").write_text("let two = 2;\n")
        c = Client(typed_server())
        caps = c.initialize(folders=[uri_of(a)])["capabilities"]
        assert caps["workspace"]["workspaceFolders"] == {"supported": True, "changeNotifications": True}

        def names():
            return {s["name"] for s in c.request("workspace/symbol", {"query": ""})}

        assert names() == {"one"}
        c._send({"jsonrpc": "2.0", "method": "workspace/didChangeWorkspaceFolders", "params": {"event": {"added": [{"uri": uri_of(b), "name": "b"}], "removed": []}}})
        assert names() == {"one", "two"}
        c._send({"jsonrpc": "2.0", "method": "workspace/didChangeWorkspaceFolders", "params": {"event": {"added": [], "removed": [{"uri": uri_of(a), "name": "a"}]}}})
        assert names() == {"two"}

    def test_the_same_path_in_two_folders(self, tmp_path):
        # each folder's lib.ty imported by its main.ty: two files, two keys
        for name, value in (("client", "1"), ("server", "\"s\"")):
            d = tmp_path / name
            d.mkdir()
            (d / "lib.ty").write_text(f"let value = {value};\n")
        c = Client(typed_server())
        c.initialize(folders=[uri_of(tmp_path / "client"), uri_of(tmp_path / "server")])
        symbols = c.request("workspace/symbol", {"query": "value"})
        assert sorted(s["containerName"] for s in symbols) == ["lib", "server/lib"]
        assert sorted(s["location"]["uri"] for s in symbols) == sorted([uri_of(tmp_path / "client" / "lib.ty"), uri_of(tmp_path / "server" / "lib.ty")])


class TestLog:
    def test_messages_and_analyses(self, tmp_path):
        log = tmp_path / "zlsp.log"
        c = opened(typed_server(log=str(log)))
        c.request("textDocument/hover", c.at(URI, "count"))
        text = log.read_text()
        assert '--> {"jsonrpc": "2.0", "id": 1, "method": "initialize"' in text
        assert '<-- {"jsonrpc":"2.0","id":1,"result":' in text
        assert "textDocument/hover" in text and "analysis analyzed in" in text
        assert all(line.startswith("[") for line in text.splitlines())

    def test_a_bad_path(self, tmp_path):
        with pytest.raises(OSError, match="cannot open the log file"):
            typed_server(log=str(tmp_path / "no" / "such" / "dir" / "x.log"))


class TestTextMate:
    def test_grammar(self):
        g = json.loads(typed_server().textmate())
        assert g["scopeName"] == "source.typed" and g["name"] == "typed"
        repo = g["repository"]
        assert repo["comments"]["patterns"] == [{"name": "comment.line.typed", "match": "\\#.*$"}]
        assert [p["begin"] for p in repo["strings"]["patterns"]] == ['"']
        kw = repo["keywords"]["patterns"][0]["match"]
        assert kw.startswith("\\b(?:") and "|struct|" in kw and "continue" in kw

    def test_scope_and_block_comments(self):
        g = json.loads(typed_server(comments=["//", ("/*", "*/")]).textmate(scope="source.ty"))
        assert g["scopeName"] == "source.ty"
        pats = g["repository"]["comments"]["patterns"]
        assert {"name": "comment.block.typed", "begin": "\\/\\*", "end": "\\*\\/"} in pats
        assert {"name": "comment.line.typed", "match": "\\/\\/.*$"} in pats

    def test_the_vscode_extension_has_the_current_one(self):
        import os

        from conftest import HERE, tiny

        path = os.path.join(HERE, "..", "editors", "vscode", "syntaxes", "tiny.tmLanguage.json")
        with open(path) as f:
            assert json.load(f) == json.loads(tiny.make_server().textmate()), "regenerate: python examples/tiny/tiny.py --textmate"

    def test_the_regexes_match(self):
        import re

        g = json.loads(typed_server().textmate())
        kw = re.compile(g["repository"]["keywords"]["patterns"][0]["match"])
        assert kw.findall("let lettuce = struct;") == ["let", "struct"]
        num = re.compile(g["repository"]["numbers"]["patterns"][0]["match"])
        assert num.findall("x1 = 12 + 3.5 + 0xff") == ["12", "3.5", "0xff"]
