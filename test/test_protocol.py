"""The protocol: lifecycle, errors, capabilities, cancellation."""

import json

import pytest
import zlsp
from conftest import Client, ResponseError, typed_server


def test_version():
    assert isinstance(zlsp.version(), str) and zlsp.version()


class TestLifecycle:
    def test_requests_before_initialize_fail(self):
        c = Client(typed_server())
        with pytest.raises(ResponseError) as e:
            c.request("textDocument/hover", {"textDocument": {"uri": "file:///x.ty"}, "position": {"line": 0, "character": 0}})
        assert e.value.code == -32002

    def test_notifications_before_initialize_are_dropped(self):
        c = Client(typed_server())
        c.open("file:///x.ty", "let a = ;")
        assert c.diagnostics == {}

    def test_initialize(self):
        c = Client(typed_server(version="1.2"))
        result = c.initialize()
        caps = result["capabilities"]
        assert result["serverInfo"] == {"name": "typed", "version": "1.2"}
        assert caps["textDocumentSync"] == {"openClose": True, "change": 2}
        for provider in ("definitionProvider", "referencesProvider", "hoverProvider", "documentSymbolProvider", "foldingRangeProvider", "documentHighlightProvider", "workspaceSymbolProvider"):
            assert caps[provider] is True
        assert caps["renameProvider"] == {"prepareProvider": True}
        assert caps["completionProvider"]["triggerCharacters"] == ["."]
        legend = caps["semanticTokensProvider"]["legend"]
        assert "keyword" in legend["tokenTypes"] and "declaration" in legend["tokenModifiers"]

    def test_shutdown_and_exit(self):
        c = Client(typed_server())
        c.initialize()
        assert c.server.exit_code is None
        assert c.request("shutdown") is None
        with pytest.raises(ResponseError) as e:
            c.request("textDocument/hover", {"textDocument": {"uri": "file:///x.ty"}, "position": {"line": 0, "character": 0}})
        assert e.value.code == -32600
        c.notify("exit")
        assert c.server.exit_code == 0

    def test_exit_without_shutdown(self):
        c = Client(typed_server())
        c.initialize()
        c.notify("exit")
        assert c.server.exit_code == 1


class TestErrors:
    def test_unknown_method(self, client):
        with pytest.raises(ResponseError) as e:
            client.request("textDocument/nope", {})
        assert e.value.code == -32601

    def test_unknown_notifications_are_ignored(self, client):
        client.notify("$/setTrace", {"value": "off"})
        client.notify("textDocument/didSave", {"textDocument": {"uri": "file:///x.ty"}})

    def test_invalid_json(self, client):
        out = [json.loads(m) for m in client.server.handle("{not json")]
        assert out == [{"jsonrpc": "2.0", "id": None, "error": {"code": -32700, "message": "the message is not valid JSON"}}]

    def test_invalid_params(self, client):
        with pytest.raises(ResponseError) as e:
            client.request("textDocument/definition", {"position": {"line": 0, "character": 0}})
        assert e.value.code == -32602

    def test_unknown_document(self, client):
        assert client.request("textDocument/definition", {"textDocument": {"uri": "file:///nope.ty"}, "position": {"line": 0, "character": 0}}) is None

    def test_string_ids(self, client):
        out = [json.loads(m) for m in client.server.handle(json.dumps({"jsonrpc": "2.0", "id": "abc", "method": "shutdown"}))]
        assert out == [{"jsonrpc": "2.0", "id": "abc", "result": None}]

    def test_bytes_messages(self, client):
        out = client.server.handle(json.dumps({"jsonrpc": "2.0", "id": 9, "method": "shutdown"}).encode())
        assert json.loads(out[0])["id"] == 9


def test_cancelled_request(client):
    client.open("file:///a.ty", "let a = 1;")
    client.notify("$/cancelRequest", {"id": 42})
    out = [json.loads(m) for m in client.server.handle(json.dumps({"jsonrpc": "2.0", "id": 42, "method": "textDocument/hover", "params": {"textDocument": {"uri": "file:///a.ty"}, "position": {"line": 0, "character": 4}}}))]
    assert out[0]["error"]["code"] == -32800
    # (only once)
    out = [json.loads(m) for m in client.server.handle(json.dumps({"jsonrpc": "2.0", "id": 42, "method": "shutdown"}))]
    assert out[0]["result"] is None


class TestConfiguration:
    def test_bad_selector(self):
        with pytest.raises(ValueError, match="no rule or class 'nope'"):
            typed_server(symbols={"nope": "function"})

    def test_bad_kind(self):
        with pytest.raises(ValueError, match="unknown symbol kind 'fn'"):
            typed_server(symbols={"funcdef > .name": "fn"})

    def test_bad_token_type(self):
        with pytest.raises(ValueError, match="unknown token type 'numbr'"):
            typed_server(tokens={"int_lit": "numbr"})

    def test_bad_comments(self):
        with pytest.raises(ValueError, match="block comment"):
            typed_server(comments=[("/*",)])

    def test_bad_resolve(self):
        with pytest.raises(TypeError, match="resolve must be callable"):
            typed_server(resolve=3)

    def test_without_rules(self):
        import typed

        c = Client(zlsp.Server(typed.PARSER, name="typed"))
        c.initialize()
        c.open("file:///a.ty", "let a = ;\nprint(nope);\n")
        # syntax errors only: no rules to check names
        assert [(d["code"], d["message"]) for d in c.diagnostics["file:///a.ty"]] == [("syntax", "expected expr")]
        assert c.request("textDocument/hover", c.at("file:///a.ty", "nope")) is None
