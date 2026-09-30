"""A small LSP client over Server.handle(), and the servers the tests use."""

import importlib.util
import json
import os
import sys

import pytest
import zlsp

HERE = os.path.dirname(__file__)
sys.path.insert(0, HERE)

import typed  # noqa: E402


def load_tiny():
    path = os.path.join(HERE, "..", "examples", "tiny", "tiny.py")
    spec = importlib.util.spec_from_file_location("tiny_example", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


tiny = load_tiny()


class ResponseError(Exception):
    def __init__(self, error):
        super().__init__(f"{error['code']}: {error['message']}")
        self.code = error["code"]


class Client:
    """Speaks LSP to a Server through handle(): requests return their
    result; notifications from the server are kept."""

    def __init__(self, server):
        self.server = server
        self.next_id = 1
        self.notifications = []
        self.diagnostics = {}
        self.requests = []
        self.texts = {}
        self.encoding = "utf-16"

    def _send(self, message):
        out = []
        for text in self.server.handle(json.dumps(message)):
            m = json.loads(text)
            if "method" in m and "id" in m:
                self.requests.append(m)
            elif "method" in m:
                self.notifications.append(m)
                if m["method"] == "textDocument/publishDiagnostics":
                    self.diagnostics[m["params"]["uri"]] = m["params"]["diagnostics"]
            else:
                out.append(m)
        return out

    def response(self, method, params=None):
        id = self.next_id
        self.next_id += 1
        out = self._send({"jsonrpc": "2.0", "id": id, "method": method, "params": params})
        assert len(out) == 1 and out[0]["id"] == id, out
        return out[0]

    def request(self, method, params=None):
        r = self.response(method, params)
        if "error" in r:
            raise ResponseError(r["error"])
        return r["result"]

    def notify(self, method, params=None):
        assert self._send({"jsonrpc": "2.0", "method": method, "params": params}) == []

    def initialize(self, root=None, folders=None, encodings=None, **capabilities):
        params = {"processId": None, "capabilities": capabilities, "rootUri": root}
        if folders is not None:
            params["workspaceFolders"] = [{"uri": u, "name": "w"} for u in folders]
        if encodings is not None:
            params["capabilities"].setdefault("general", {})["positionEncodings"] = encodings
        result = self.request("initialize", params)
        self.encoding = result["capabilities"]["positionEncoding"]
        self.notify("initialized", {})
        return result

    def open(self, uri, text, version=1, language="x"):
        self.texts[uri] = text
        self.notify("textDocument/didOpen", {"textDocument": {"uri": uri, "languageId": language, "version": version, "text": text}})

    def change(self, uri, text, version=2):
        """Replace the whole text (a full change)."""
        self.texts[uri] = text
        self.notify("textDocument/didChange", {"textDocument": {"uri": uri, "version": version}, "contentChanges": [{"text": text}]})

    def edit(self, uri, start, end, new_text, version=2):
        """An incremental change, between two positions."""
        self.notify(
            "textDocument/didChange",
            {"textDocument": {"uri": uri, "version": version}, "contentChanges": [{"range": {"start": start, "end": end}, "text": new_text}]},
        )

    def close(self, uri):
        self.notify("textDocument/didClose", {"textDocument": {"uri": uri}})

    def pos(self, uri, needle, delta=0, occurrence=0):
        """The position of `needle` (its n-th occurrence) in the text, plus `delta` characters."""
        text = self.texts[uri]
        at = -1
        for _ in range(occurrence + 1):
            at = text.index(needle, at + 1)
        return self.position(text, at + delta)

    def position(self, text, offset):
        line = text.count("\n", 0, offset)
        start = text.rfind("\n", 0, offset) + 1
        chunk = text[start:offset]
        if self.encoding == "utf-8":
            character = len(chunk.encode())
        else:
            character = len(chunk.encode("utf-16-le")) // 2
        return {"line": line, "character": character}

    def at(self, uri, needle, delta=0, occurrence=0):
        return {"textDocument": {"uri": uri}, "position": self.pos(uri, needle, delta, occurrence)}

    def text_of(self, uri, range_):
        """The text a range covers."""
        lines = self.texts[uri].split("\n")
        s, e = range_["start"], range_["end"]

        def offset(p):
            line = lines[p["line"]] if p["line"] < len(lines) else ""
            if self.encoding == "utf-8":
                return len(line.encode()[: p["character"]].decode(errors="ignore"))
            return len(line.encode("utf-16-le")[: 2 * p["character"]].decode("utf-16-le", errors="ignore"))

        if s["line"] == e["line"]:
            return lines[s["line"]][offset(s) : offset(e)]
        parts = [lines[s["line"]][offset(s) :]] + lines[s["line"] + 1 : e["line"]] + [lines[e["line"]][: offset(e)]]
        return "\n".join(parts)


TYPED_CONFIG = dict(
    name="typed",
    extensions=[".ty"],
    symbols={
        "funcdef > .name": "function",
        "struct_def > .name": "struct",
        "field > .name": "field",
        "param > .name": "parameter",
        "let_stmt > .name": "variable",
    },
    tokens={"int_lit, float_lit": "number", "string": "string", "bool_lit, nil_lit": "keyword"},
    comments=["#"],
)


def typed_server(**overrides):
    config = dict(TYPED_CONFIG)
    config.update(overrides)
    return zlsp.Server(typed.PARSER, typed.RULES, **config)


@pytest.fixture
def client():
    """A client of a typed-language server, initialized without a workspace."""
    c = Client(typed_server())
    c.initialize()
    return c


@pytest.fixture
def tiny_client():
    c = Client(tiny.make_server())
    c.initialize()
    return c


def uri_of(path):
    """The URI of a file, as zlsp spells those it finds on disk (Windows:
    file:///c:/..., the drive letter in lowercase)."""
    path = os.path.abspath(path).replace("\\", "/")
    if len(path) > 1 and path[1] == ":":
        path = path[0].lower() + path[1:]
    if not path.startswith("/"):
        path = "/" + path
    return "file://" + path
