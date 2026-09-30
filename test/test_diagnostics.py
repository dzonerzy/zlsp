"""Diagnostics as you type, and positions in both encodings."""

from conftest import Client, typed_server

URI = "file:///a.ty"


def codes(client, uri=URI):
    return [(d["range"]["start"]["line"], d["code"]) for d in client.diagnostics[uri]]


class TestPublishing:
    def test_on_open(self, client):
        client.open(URI, "let a = 1;\nprint(nope);\nlet b = ;\n")
        diags = client.diagnostics[URI]
        assert codes(client) == [(1, "undefined-name"), (2, "syntax")]
        undefined = diags[0]
        assert undefined["message"] == "undefined name 'nope'"
        assert undefined["severity"] == 1 and undefined["source"] == "typed"
        assert client.text_of(URI, undefined["range"]) == "nope"

    def test_every_syntax_error_and_the_checks_around_them(self, client):
        client.open(URI, "let a = ;\nlet b = 2;\nlet c = * ;\nprint(b, nope);\n")
        assert codes(client) == [(0, "syntax"), (2, "syntax"), (3, "undefined-name")]

    def test_on_change(self, client):
        client.open(URI, "print(nope);\n")
        assert codes(client) == [(0, "undefined-name")]
        client.change(URI, "let nope = 1;\nprint(nope);\n")
        assert client.diagnostics[URI] == []

    def test_incremental_edits(self, client):
        client.open(URI, "let a = 1;\nprint(b);\n")
        assert codes(client) == [(1, "undefined-name")]
        client.edit(URI, {"line": 1, "character": 6}, {"line": 1, "character": 7}, "a")
        assert client.diagnostics[URI] == []

    def test_only_changes_are_published(self, client):
        client.open(URI, "print(nope);\n")
        n = len(client.notifications)
        client.change(URI, "print(nope);  \n")
        # same diagnostics (and same positions): nothing new sent
        assert len(client.notifications) == n
        client.change(URI, "print(nopes);\n")
        assert len(client.notifications) == n + 1

    def test_version(self, client):
        client.open(URI, "print(nope);\n", version=7)
        assert client.notifications[-1]["params"]["version"] == 7

    def test_warnings(self, client):
        client.open(URI, "fn f() -> int {\n    return 1;\n    print(2);\n}\n")
        assert [(d["code"], d["severity"]) for d in client.diagnostics[URI]] == [("unreachable", 2)]

    def test_related_information(self):
        c = Client(typed_server())
        c.initialize(textDocument={"publishDiagnostics": {"relatedInformation": True}})
        c.open(URI, "let a = 1;\nlet a = 2;\n")
        (d,) = c.diagnostics[URI]
        assert d["code"] == "redefined-name"
        (note,) = d["relatedInformation"]
        assert note["message"] == "first defined here" and note["location"]["range"]["start"]["line"] == 0

    def test_closing_clears(self, client):
        client.open(URI, "print(nope);\n")
        client.close(URI)
        assert client.diagnostics[URI] == []


class TestEncodings:
    SRC = 'let s = "héllo 😀";\nprint(s, nope);\nlet t = "😀😀"; print(nope2);\n'

    def test_utf16_by_default(self, client):
        client.open(URI, self.SRC)
        d = client.diagnostics[URI][-1]
        # `let t = "` (9), two emoji (2 UTF-16 units each), `"; print(` (9)
        assert client.text_of(URI, d["range"]) == "nope2"
        assert d["range"]["start"] == {"line": 2, "character": 22}

    def test_utf8_when_offered(self):
        c = Client(typed_server())
        result = c.initialize(encodings=["utf-8", "utf-16"])
        assert result["capabilities"]["positionEncoding"] == "utf-8"
        c.open(URI, self.SRC)
        d = c.diagnostics[URI][-1]
        # the emoji are 4 bytes each
        assert c.text_of(URI, d["range"]) == "nope2"
        assert d["range"]["start"] == {"line": 2, "character": 26}

    def test_edits_in_utf16(self, client):
        client.open(URI, 'let s = "😀"; print(x);\n')
        # replace the `x` after the emoji (2 UTF-16 units, 4 bytes)
        client.edit(URI, client.position(client.texts[URI], 19), client.position(client.texts[URI], 20), "s")
        assert client.diagnostics[URI] == []

    def test_crlf(self, tiny_client):
        # (tiny's whitespace takes \r; the typed language's doesn't)
        tiny_client.open("file:///a.tiny", "let a = 1;\r\nprint(a, nope);\r\n")
        (d,) = tiny_client.diagnostics["file:///a.tiny"]
        assert d["range"]["start"] == {"line": 1, "character": 9}
        assert d["range"]["end"] == {"line": 1, "character": 13}
