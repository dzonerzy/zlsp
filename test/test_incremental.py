"""An edit re-checks what it can have changed: the edited file, the files
importing it (directly or not), with what those import. Not the rest."""

import time

import pytest
import typed
import zlsp
from conftest import TYPED_CONFIG, Client, uri_of
from zrules import Rules, custom, flow, scopes, types

checked = []


def record(node, ctx):
    # each file starts with `# <name>`
    checked.append(node.text().split("\n", 1)[0][2:])


RULES = Rules(typed.PARSER, typed.STRUCTURE + [scopes(**typed.SCOPES), types(**typed.TYPES), flow(**typed.FLOW), custom("program", record)])

FILES = {
    # base <- mid <- top; other stands alone
    "base": "# base\nfn one() -> int { return 1; }\n",
    "mid": "# mid\nfrom base import one;\nfn two() -> int { return one() + one(); }\n",
    "top": "# top\nfrom mid import two;\nlet t = two();\n",
    "other": "# other\nlet o = 1;\n",
}


@pytest.fixture
def project(tmp_path):
    for name, text in FILES.items():
        (tmp_path / f"{name}.ty").write_text(text)
    c = Client(zlsp.Server(typed.PARSER, RULES, **TYPED_CONFIG))
    checked.clear()
    c.initialize(root=uri_of(tmp_path))
    assert sorted(checked) == ["base", "mid", "other", "top"]
    for name in FILES:
        c.open(uri_of(tmp_path / f"{name}.ty"), FILES[name])
    return c, tmp_path


def edit(c, root, name, text, version=2):
    checked.clear()
    c.change(uri_of(root / f"{name}.ty"), text, version)
    return sorted(set(checked))


def test_a_file_alone(project):
    c, root = project
    assert edit(c, root, "other", "# other\nlet o = 2;\n") == ["other"]


def test_the_importers_too(project):
    c, root = project
    # mid's importer (top) is checked again, with what they import (base)
    assert edit(c, root, "mid", "# mid\nfrom base import one;\nfn two() -> int { return one(); }\n") == ["base", "mid", "top"]
    # base: everything that depends on it, through mid
    assert edit(c, root, "base", "# base\nfn one() -> int { return 2; }\n", 3) == ["base", "mid", "top"]


def test_results_stay_right(project):
    c, root = project
    top = uri_of(root / "top.ty")
    # an edit two files away breaks top: it is reported there
    edit(c, root, "base", "# base\nfn uno() -> int { return 1; }\n")
    assert [d["code"] for d in c.diagnostics[uri_of(root / "mid.ty")]] == ["no-export"]
    assert c.diagnostics[top] == []
    edit(c, root, "mid", "# mid\nfn two() -> str { return \"s\"; }\n", 3)
    assert c.diagnostics[uri_of(root / "mid.ty")] == []
    edit(c, root, "top", "# top\nfrom mid import two;\nlet t: int = two();\n", 4)
    assert [d["code"] for d in c.diagnostics[top]] == ["type-mismatch"]


def test_a_new_import(project):
    c, root = project
    # other starts importing base: checked with it, and it resolves
    assert edit(c, root, "other", "# other\nfrom base import one;\nlet o = one();\n") == ["base", "other"]
    assert c.diagnostics[uri_of(root / "other.ty")] == []
    # and now base's edits reach it
    assert "other" in edit(c, root, "base", "# base\nfn one() -> int { return 3; }\n", 3)


def test_files_coming_and_going_check_everything(project):
    c, root = project
    checked.clear()
    c.open(uri_of(root / "new.ty"), "# new\nlet n = 1;\n")
    assert sorted(set(checked)) == ["base", "mid", "new", "other", "top"]


def test_big_workspace(tmp_path):
    # 300 files: an edit of one checks one
    for i in range(300):
        (tmp_path / f"f{i}.ty").write_text(f"# f{i}\n" + "".join(f"fn g{k}(a: int) -> int {{ return a + {k}; }}\n" for k in range(20)))
    c = Client(zlsp.Server(typed.PARSER, RULES, **TYPED_CONFIG))
    c.initialize(root=uri_of(tmp_path))
    uri = uri_of(tmp_path / "f7.ty")
    text = (tmp_path / "f7.ty").read_text()
    c.open(uri, text)
    checked.clear()
    start = time.perf_counter()
    c.change(uri, text + "let z = g1(1);\n")
    elapsed = time.perf_counter() - start
    assert sorted(set(checked)) == ["f7"]
    assert elapsed < 0.5, elapsed
