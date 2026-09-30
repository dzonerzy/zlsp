"""Definition, references, highlights, rename, hover: in a file, and across
the files of a workspace."""

import os
import shutil

import pytest
from conftest import HERE, Client, ResponseError, typed_server, uri_of

URI = "file:///a.ty"
SRC = "fn f(a: int) -> int {\n    let b = a;\n    return b;\n}\nlet top = f(1);\nprint(top);\n"


@pytest.fixture
def opened(client):
    client.open(URI, SRC)
    return client


class TestOneFile:
    def test_definition(self, opened):
        loc = opened.request("textDocument/definition", opened.at(URI, "f(1)"))
        assert loc["uri"] == URI
        assert loc["range"]["start"] == {"line": 0, "character": 3}
        assert opened.text_of(URI, loc["range"]) == "f"
        # on the definition itself: itself
        assert opened.request("textDocument/definition", opened.at(URI, "f(a"))["range"] == loc["range"]
        # declaration: the same
        assert opened.request("textDocument/declaration", opened.at(URI, "f(1)")) == loc

    def test_nothing_there(self, opened):
        assert opened.request("textDocument/definition", opened.at(URI, "return")) is None
        # a builtin has no definition in the source
        assert opened.request("textDocument/definition", opened.at(URI, "print")) is None

    def test_references(self, opened):
        refs = opened.request("textDocument/references", {**opened.at(URI, "b = a"), "context": {"includeDeclaration": True}})
        assert [(r["range"]["start"]["line"], opened.text_of(URI, r["range"])) for r in refs] == [(1, "b"), (2, "b")]
        refs = opened.request("textDocument/references", {**opened.at(URI, "b;"), "context": {"includeDeclaration": False}})
        assert [r["range"]["start"]["line"] for r in refs] == [2]

    def test_highlights(self, opened):
        hl = opened.request("textDocument/documentHighlight", opened.at(URI, "top", occurrence=1))
        assert [(h["range"]["start"]["line"], h["kind"]) for h in hl] == [(4, 3), (5, 2)]

    def test_hover(self, opened):
        h = opened.request("textDocument/hover", opened.at(URI, "f(1)"))
        assert h["contents"] == {"kind": "markdown", "value": "```typed\nfunction f: fn(int) -> int\n```"}
        assert opened.text_of(URI, h["range"]) == "f"
        h = opened.request("textDocument/hover", opened.at(URI, "a;"))
        assert h["contents"]["value"] == "```typed\nparameter a: int\n```"
        h = opened.request("textDocument/hover", opened.at(URI, "print"))
        assert h["contents"]["value"] == "```typed\n(builtin) function print: fn(...) -> void\n```"
        assert opened.request("textDocument/hover", opened.at(URI, "return")) is None

    def test_prepare_rename(self, opened):
        r = opened.request("textDocument/prepareRename", opened.at(URI, "top", occurrence=1))
        assert r["placeholder"] == "top" and r["range"]["start"] == {"line": 5, "character": 6}
        assert opened.request("textDocument/prepareRename", opened.at(URI, "print")) is None

    def test_rename(self, opened):
        edit = opened.request("textDocument/rename", {**opened.at(URI, "a;"), "newName": "x"})
        changes = edit["changes"][URI]
        assert [(c["range"]["start"]["line"], opened.text_of(URI, c["range"]), c["newText"]) for c in changes] == [(0, "a", "x"), (1, "a", "x")]
        with pytest.raises(ResponseError):
            opened.request("textDocument/rename", opened.at(URI, "a;"))

    def test_results_follow_the_edits(self, opened):
        opened.change(URI, "\n\n" + SRC)
        loc = opened.request("textDocument/definition", opened.at(URI, "f(1)"))
        assert loc["range"]["start"] == {"line": 2, "character": 3}

    def test_in_broken_code(self, opened):
        # a syntax error elsewhere doesn't stop navigation
        opened.change(URI, SRC + "let broken = ;\n")
        loc = opened.request("textDocument/definition", opened.at(URI, "f(1)"))
        assert loc["range"]["start"] == {"line": 0, "character": 3}


@pytest.fixture
def workspace(tmp_path):
    for name in ("geometry.ty", "main.ty"):
        shutil.copy(os.path.join(HERE, name), tmp_path / name)
    (tmp_path / "notes.txt").write_text("not a .ty file")
    (tmp_path / ".hidden").mkdir()
    (tmp_path / ".hidden" / "skip.ty").write_text("let = ;")
    c = Client(typed_server())
    c.initialize(root=uri_of(tmp_path))
    return c, tmp_path


class TestWorkspace:
    def test_files_on_disk_are_checked(self, workspace):
        c, root = workspace
        # published without being opened: both are clean
        assert c.diagnostics == {uri_of(root / "geometry.ty"): [], uri_of(root / "main.ty"): []}

    def test_definition_in_another_file(self, workspace):
        c, root = workspace
        main = uri_of(root / "main.ty")
        c.open(main, (root / "main.ty").read_text())
        loc = c.request("textDocument/definition", c.at(main, "origin()"))
        assert loc["uri"] == uri_of(root / "geometry.ty")
        assert loc["range"]["start"] == {"line": 11, "character": 3}

    def test_references_across_files(self, workspace):
        c, root = workspace
        geometry = uri_of(root / "geometry.ty")
        main = uri_of(root / "main.ty")
        c.open(geometry, (root / "geometry.ty").read_text())
        refs = c.request("textDocument/references", {**c.at(geometry, "origin"), "context": {"includeDeclaration": True}})
        assert sorted((r["uri"] == main, r["range"]["start"]["line"]) for r in refs) == [(False, 11), (True, 0), (True, 10)]

    def test_rename_across_files(self, workspace):
        c, root = workspace
        geometry = uri_of(root / "geometry.ty")
        main = uri_of(root / "main.ty")
        c.open(geometry, (root / "geometry.ty").read_text())
        edit = c.request("textDocument/rename", {**c.at(geometry, "largest"), "newName": "biggest"})
        assert set(edit["changes"]) == {geometry, main}
        assert [e["range"]["start"]["line"] for e in edit["changes"][main]] == [0, 16]

    def test_an_edit_in_one_file_is_seen_in_the_other(self, workspace):
        c, root = workspace
        geometry = uri_of(root / "geometry.ty")
        main = uri_of(root / "main.ty")
        c.open(geometry, (root / "geometry.ty").read_text())
        c.change(geometry, c.texts[geometry].replace("fn origin()", "fn center()"))
        assert [d["code"] for d in c.diagnostics[main]] == ["no-export"]
        c.change(geometry, c.texts[geometry].replace("fn center()", "fn origin()"), version=3)
        assert c.diagnostics[main] == []

    def test_closing_goes_back_to_the_disk(self, workspace):
        c, root = workspace
        main = uri_of(root / "main.ty")
        c.open(main, "print(nope);\n")
        assert [d["code"] for d in c.diagnostics[main]] == ["undefined-name"]
        c.close(main)
        assert c.diagnostics[main] == []

    def test_watched_files(self, workspace):
        c, root = workspace
        extra = root / "extra.ty"
        extra.write_text("print(nope);\n")
        c.notify("workspace/didChangeWatchedFiles", {"changes": [{"uri": uri_of(extra), "type": 1}]})
        assert [d["code"] for d in c.diagnostics[uri_of(extra)]] == ["undefined-name"]
        extra.write_text("print(1);\n")
        c.notify("workspace/didChangeWatchedFiles", {"changes": [{"uri": uri_of(extra), "type": 2}]})
        assert c.diagnostics[uri_of(extra)] == []
        c.notify("workspace/didChangeWatchedFiles", {"changes": [{"uri": uri_of(root / "geometry.ty"), "type": 3}]})
        assert [d["code"] for d in c.diagnostics[uri_of(root / "main.ty")]] == ["no-module"]

    def test_watchers_registered(self, tmp_path):
        c = Client(typed_server())
        c.initialize(root=uri_of(tmp_path), workspace={"didChangeWatchedFiles": {"dynamicRegistration": True}})
        (req,) = c.requests
        assert req["method"] == "client/registerCapability"
        (reg,) = req["params"]["registrations"]
        assert reg["registerOptions"]["watchers"] == [{"globPattern": "**/*.ty"}]

    def test_workspace_folders(self, tmp_path):
        a = tmp_path / "a"
        b = tmp_path / "b"
        a.mkdir()
        b.mkdir()
        (a / "one.ty").write_text("print(nope);\n")
        (b / "two.ty").write_text("let x = ;\n")
        c = Client(typed_server())
        c.initialize(folders=[uri_of(a), uri_of(b)])
        assert set(c.diagnostics) == {uri_of(a / "one.ty"), uri_of(b / "two.ty")}
