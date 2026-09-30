"""The server as an editor runs it: a process speaking LSP over stdin/stdout."""

import json
import os
import queue
import subprocess
import sys
import textwrap
import threading

import pytest
from conftest import HERE

TINY = os.path.join(HERE, "..", "examples", "tiny", "tiny.py")


class Process:
    """An LSP server process: send() messages, next() what it writes."""

    def __init__(self, args, cwd=None):
        self.proc = subprocess.Popen(args, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, cwd=cwd)
        self.messages = queue.Queue()
        self.stderr = []
        threading.Thread(target=self._read, daemon=True).start()
        threading.Thread(target=self._read_stderr, daemon=True).start()
        self.next_id = 1

    def _read(self):
        out = self.proc.stdout
        while True:
            length = None
            while True:
                line = out.readline()
                if not line:
                    self.messages.put(None)
                    return
                line = line.strip()
                if not line:
                    break
                name, _, value = line.partition(b":")
                if name.strip().lower() == b"content-length":
                    length = int(value)
            self.messages.put(json.loads(out.read(length)))

    def _read_stderr(self):
        for line in self.proc.stderr:
            self.stderr.append(line.decode(errors="replace"))

    def send(self, message):
        body = json.dumps(message).encode()
        self.proc.stdin.write(b"Content-Length: %d\r\n\r\n" % len(body) + body)
        self.proc.stdin.flush()

    def next(self, timeout=10):
        return self.messages.get(timeout=timeout)

    def request(self, method, params=None):
        id = self.next_id
        self.next_id += 1
        self.send({"jsonrpc": "2.0", "id": id, "method": method, "params": params})
        while True:
            m = self.next()
            assert m is not None, "".join(self.stderr)
            if m.get("id") == id and "method" not in m:
                return m

    def notify(self, method, params=None):
        self.send({"jsonrpc": "2.0", "method": method, "params": params})

    def wait_for(self, method, timeout=10):
        while True:
            m = self.next(timeout)
            assert m is not None, "".join(self.stderr)
            if m.get("method") == method:
                return m

    def close(self):
        if self.proc.poll() is None:
            self.proc.kill()
        self.proc.wait(10)


@pytest.fixture
def tiny():
    p = Process([sys.executable, TINY])
    yield p
    p.close()


def test_a_session(tiny):
    r = tiny.request("initialize", {"processId": None, "capabilities": {}, "rootUri": None})
    assert r["result"]["serverInfo"]["name"] == "tiny"
    tiny.notify("initialized", {})
    uri = "file:///fib.tiny"
    tiny.notify("textDocument/didOpen", {"textDocument": {"uri": uri, "languageId": "tiny", "version": 1, "text": "let a = 1;\nprint(a, nope);\nbreak;\n"}})
    d = tiny.wait_for("textDocument/publishDiagnostics")["params"]
    assert d["uri"] == uri
    assert [x["code"] for x in d["diagnostics"]] == ["undefined-name", "break-outside-loop"]
    r = tiny.request("textDocument/definition", {"textDocument": {"uri": uri}, "position": {"line": 1, "character": 6}})
    assert r["result"]["range"]["start"] == {"line": 0, "character": 4}
    assert tiny.request("shutdown")["result"] is None
    tiny.notify("exit")
    assert tiny.proc.wait(10) == 0


def test_a_burst_of_edits_is_analyzed_once(tiny):
    tiny.request("initialize", {"processId": None, "capabilities": {}})
    tiny.notify("initialized", {})
    uri = "file:///a.tiny"
    tiny.notify("textDocument/didOpen", {"textDocument": {"uri": uri, "languageId": "tiny", "version": 1, "text": ""}})
    text = ""
    for i, ch in enumerate("print(nope);"):
        text += ch
        tiny.notify("textDocument/didChange", {"textDocument": {"uri": uri, "version": 2 + i}, "contentChanges": [{"text": text}]})
    r = tiny.request("textDocument/hover", {"textDocument": {"uri": uri}, "position": {"line": 0, "character": 1}})
    assert "print" in r["result"]["contents"]["value"]
    # the last diagnostics are for the whole text
    last = None
    while True:
        try:
            m = tiny.next(timeout=1)
        except queue.Empty:
            break
        if m and m.get("method") == "textDocument/publishDiagnostics":
            last = m
    diags = last["params"]["diagnostics"] if last else None
    assert diags is None or [x["code"] for x in diags] == ["undefined-name"]


def test_the_end_of_the_input_ends_the_server(tiny):
    tiny.request("initialize", {"processId": None, "capabilities": {}})
    tiny.proc.stdin.close()
    assert tiny.proc.wait(10) == 1


def test_print_in_a_rule_does_not_break_the_protocol(tmp_path):
    script = tmp_path / "server.py"
    script.write_text(
        textwrap.dedent(
            f"""
            import sys
            sys.path.insert(0, {os.path.dirname(TINY)!r})
            import tiny
            from zrules import Rules, custom
            from zlsp import Server

            def shout(node, ctx):
                print("checking", node.text())

            rules = Rules(tiny.PARSER, [custom("Call", shout)])
            sys.exit(Server(tiny.PARSER, rules, name="loud").start_io())
            """
        )
    )
    p = Process([sys.executable, str(script)])
    try:
        p.request("initialize", {"processId": None, "capabilities": {}})
        p.notify("initialized", {})
        p.notify("textDocument/didOpen", {"textDocument": {"uri": "file:///x.tiny", "languageId": "tiny", "version": 1, "text": "print(1);\n"}})
        assert p.wait_for("textDocument/publishDiagnostics")["params"]["diagnostics"] == []
        assert p.request("shutdown")["result"] is None
        p.notify("exit")
        assert p.proc.wait(10) == 0
        assert any("checking print(1)" in line for line in p.stderr)
    finally:
        p.close()


def test_a_failing_rule_is_logged_not_fatal(tmp_path):
    script = tmp_path / "server.py"
    script.write_text(
        textwrap.dedent(
            f"""
            import sys
            sys.path.insert(0, {os.path.dirname(TINY)!r})
            import tiny
            from zrules import Rules, custom
            from zlsp import Server

            def broken(node, ctx):
                raise ValueError("oops in a rule")

            rules = Rules(tiny.PARSER, [custom("Call", broken)])
            sys.exit(Server(tiny.PARSER, rules, name="failing").start_io())
            """
        )
    )
    p = Process([sys.executable, str(script)])
    try:
        p.request("initialize", {"processId": None, "capabilities": {}})
        p.notify("initialized", {})
        p.notify("textDocument/didOpen", {"textDocument": {"uri": "file:///x.tiny", "languageId": "tiny", "version": 1, "text": "print(1);\nlet = ;\n"}})
        log = p.wait_for("window/logMessage")["params"]
        assert log["type"] == 1 and "ValueError: oops in a rule" in log["message"]
        # still serving, with the syntax errors
        d = p.wait_for("textDocument/publishDiagnostics")["params"]["diagnostics"]
        assert [x["code"] for x in d] == ["syntax"]
        assert p.request("shutdown")["result"] is None
    finally:
        p.close()
