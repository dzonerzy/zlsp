"""zrules' types as the editor shows them: generic functions and types,
unions, subtyping between declared types (zrules 0.2)."""

import pytest

URI = "file:///g.ty"
SRC = """fn first[T](xs: list[T]) -> T {
    return xs[0];
}
let x = first([1, 2]);
fn show(v: int | str) {
    print(v);
}
show(1);
show(2.5);
struct Animal { name: str; }
struct Dog: Animal { breed: str; }
fn speak(a: Animal) -> str { return a.name; }
fn bark(d: Dog) -> str { return speak(d); }
let w: int | nil = nil;
let n: Dog = nil;
"""


@pytest.fixture
def opened(client):
    client.open(URI, SRC)
    return client


def hover(client, needle):
    h = client.request("textDocument/hover", client.at(URI, needle))
    return h["contents"]["value"].removeprefix("```typed\n").removesuffix("\n```")


def test_generic_function(opened):
    assert hover(opened, "first[") == "function first: fn(list[T]) -> T"
    assert hover(opened, "xs:") == "parameter xs: list[T]"
    assert hover(opened, "T]") == "type T: type[T]"
    # (a call's result, T bound by its argument)
    assert hover(opened, "x =") == "variable x: int"


def test_unions(opened):
    assert hover(opened, "v)") == "parameter v: int | str"
    assert hover(opened, "w:") == "variable w: int | nil"


def test_diagnostics(opened):
    found = [(d["range"]["start"]["line"], d["code"], d["message"]) for d in opened.diagnostics[URI]]
    # (a float isn't in the union; a Dog is an Animal; nil isn't a Dog)
    assert found == [
        (8, "bad-argument", "argument 1 of show(): expected 'int | str', got 'float'"),
        (14, "type-mismatch", "expected 'Dog', got 'nil'"),
    ]


def test_type_parameters_are_names(opened):
    # (T is defined by the function's parameter list: its uses go there)
    loc = opened.request("textDocument/definition", opened.at(URI, "T]) -> T"))
    assert opened.text_of(URI, loc["range"]) == "T" and loc["range"]["start"]["line"] == 0
    refs = opened.request("textDocument/references", {**opened.at(URI, "T]"), "context": {"includeDeclaration": True}})
    assert len(refs) == 3
