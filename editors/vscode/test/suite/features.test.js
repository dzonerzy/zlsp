// Every feature, asked of VS Code itself: its LSP client talks to the tiny
// server the extension started.
//
// main.tiny (0-based lines):
//   0  # A program with mistakes
//   1  fn fib(n) {
//   2      if n < 2 { return n; }
//   3      return fib(n - 1) + fib(n - 2);
//   4  }
//   5
//   6  let total = 0;
//   7  let i = 0;
//   8  while i < 10 {
//   9      total = total + fib(i);
//  10      i = i + 1;
//  11  }
//  12  print(total, missing);
//  13  break;

const assert = require("assert");
const path = require("path");
const vscode = require("vscode");

const root = () => vscode.workspace.workspaceFolders[0].uri;
const fileUri = (name) => vscode.Uri.joinPath(root(), name);

async function waitFor(what, check, timeout = 30000) {
  const start = Date.now();
  for (;;) {
    const value = await check();
    if (value) return value;
    if (Date.now() - start > timeout) throw new Error(`timed out waiting for ${what}`);
    await new Promise((r) => setTimeout(r, 100));
  }
}

function codes(uri) {
  return vscode.languages.getDiagnostics(uri).map((d) => `${d.range.start.line}:${d.code}`);
}

suite("zlsp in VS Code", function () {
  let doc;
  const pos = (line, character) => new vscode.Position(line, character);

  suiteSetup(async function () {
    doc = await vscode.workspace.openTextDocument(fileUri("main.tiny"));
    await vscode.window.showTextDocument(doc);
    assert.strictEqual(doc.languageId, "tiny");
    // The server starts, analyzes, publishes
    await waitFor("the diagnostics of main.tiny", () => vscode.languages.getDiagnostics(doc.uri).length === 2);
  });

  test("diagnostics as published", () => {
    const diags = vscode.languages.getDiagnostics(doc.uri);
    assert.deepStrictEqual(codes(doc.uri), ["12:undefined-name", "13:break-outside-loop"]);
    assert.strictEqual(diags[0].message, "undefined name 'missing'");
    assert.strictEqual(diags[0].source, "tiny");
    assert.strictEqual(diags[0].severity, vscode.DiagnosticSeverity.Error);
    assert.strictEqual(doc.getText(diags[0].range), "missing");
  });

  test("files that aren't open are checked too", async () => {
    await waitFor("broken.tiny's syntax error", () => codes(fileUri("broken.tiny")).join() === "0:syntax");
    assert.deepStrictEqual(codes(fileUri("clean.tiny")), []);
  });

  test("go to definition", async () => {
    const locs = await vscode.commands.executeCommand("vscode.executeDefinitionProvider", doc.uri, pos(9, 21));
    assert.strictEqual(locs.length, 1);
    const loc = locs[0];
    const range = loc.targetRange || loc.range;
    const uri = loc.targetUri || loc.uri;
    assert.strictEqual(uri.toString(), doc.uri.toString());
    assert.deepStrictEqual([range.start.line, range.start.character], [1, 3]);
  });

  test("find references", async () => {
    const locs = await vscode.commands.executeCommand("vscode.executeReferenceProvider", doc.uri, pos(1, 4));
    const lines = locs.map((l) => l.range.start.line).sort((a, b) => a - b);
    assert.deepStrictEqual(lines, [1, 3, 3, 9]);
  });

  test("highlights", async () => {
    const hl = await vscode.commands.executeCommand("vscode.executeDocumentHighlights", doc.uri, pos(6, 5));
    assert.deepStrictEqual(hl.map((h) => h.range.start.line), [6, 9, 9, 12]);
    assert.strictEqual(hl[0].kind, vscode.DocumentHighlightKind.Write);
  });

  test("hover", async () => {
    const hovers = await vscode.commands.executeCommand("vscode.executeHoverProvider", doc.uri, pos(9, 21));
    const text = hovers.flatMap((h) => h.contents.map((c) => c.value || c)).join("\n");
    assert.match(text, /function fib/);
    // the comment above its definition
    assert.match(text, /A program with mistakes/);
  });

  test("hover: the hook's docs of a builtin", async () => {
    const hovers = await vscode.commands.executeCommand("vscode.executeHoverProvider", doc.uri, pos(12, 2));
    const text = hovers.flatMap((h) => h.contents.map((c) => c.value || c)).join("\n");
    assert.match(text, /function print/);
    assert.match(text, /Writes its arguments/);
  });

  test("signature help", async () => {
    const help = await vscode.commands.executeCommand("vscode.executeSignatureHelpProvider", doc.uri, pos(9, 24));
    assert.strictEqual(help.signatures[0].label, "fib(n)");
    assert.strictEqual(help.activeParameter, 0);
  });

  test("selection ranges", async () => {
    const [range] = await vscode.commands.executeCommand("vscode.executeSelectionRangeProvider", doc.uri, [pos(9, 22)]);
    const texts = [];
    for (let r = range; r; r = r.parent) texts.push(doc.getText(r.range));
    assert.strictEqual(texts[0], "fib");
    assert.ok(texts.includes("fib(i)"), texts.join(" | "));
    assert.strictEqual(texts[texts.length - 1], doc.getText());
  });

  test("outline", async () => {
    const symbols = await vscode.commands.executeCommand("vscode.executeDocumentSymbolProvider", doc.uri);
    assert.deepStrictEqual(symbols.map((s) => s.name), ["fib", "total", "i"]);
    assert.strictEqual(symbols[0].kind, vscode.SymbolKind.Function);
    assert.deepStrictEqual(symbols[0].children.map((s) => s.name), ["n"]);
  });

  test("workspace symbols", async () => {
    const found = await vscode.commands.executeCommand("vscode.executeWorkspaceSymbolProvider", "fib");
    assert.ok(found.some((s) => s.name === "fib" && path.basename(s.location.uri.fsPath) === "main.tiny"));
  });

  test("completion", async () => {
    const list = await vscode.commands.executeCommand("vscode.executeCompletionItemProvider", doc.uri, pos(12, 6));
    const labels = list.items.map((i) => (typeof i.label === "string" ? i.label : i.label.label));
    for (const name of ["fib", "total", "i", "print"]) assert.ok(labels.includes(name), `${name} in ${labels}`);
    // an argument: no statement keywords
    assert.ok(!labels.includes("while"), labels.join());
    // the hook's snippets: where a statement can start
    const snippets = async (p) => {
      const l = await vscode.commands.executeCommand("vscode.executeCompletionItemProvider", doc.uri, p);
      return l.items.filter((i) => i.kind === vscode.CompletionItemKind.Snippet);
    };
    assert.deepStrictEqual(await snippets(pos(12, 6)), []);
    const fn = (await snippets(pos(5, 0))).find((i) => (i.label.label || i.label) === "fn");
    assert.ok(fn, "the fn snippet");
    assert.ok(fn.insertText instanceof vscode.SnippetString);
  });

  test("a code action from the hook", async () => {
    const actions = await vscode.commands.executeCommand("vscode.executeCodeActionProvider", doc.uri, new vscode.Range(pos(13, 0), pos(13, 5)));
    const remove = actions.find((a) => a.title === "Remove the 'break'");
    assert.ok(remove, actions.map((a) => a.title).join());
    const [edit] = remove.edit.get(doc.uri);
    assert.deepStrictEqual([edit.range.start.line, edit.range.end.line, edit.newText], [13, 14, ""]);
  });

  test("formatting, by the hook", async () => {
    const messy = await vscode.workspace.openTextDocument(fileUri("messy.tiny"));
    const edits = await vscode.commands.executeCommand("vscode.executeFormatDocumentProvider", messy.uri, { tabSize: 4, insertSpaces: true });
    // (VS Code makes the whole-file edit minimal: applied, it gives the text)
    const edit = new vscode.WorkspaceEdit();
    edit.set(messy.uri, edits);
    await vscode.workspace.applyEdit(edit);
    assert.strictEqual(messy.getText(), "fn f(a) {\n    return a;\n}\nprint(f(1));\n");
  });

  test("a setting, asked of VS Code", async () => {
    const settings = vscode.workspace.getConfiguration("tiny");
    await settings.update("maxLineLength", 30, vscode.ConfigurationTarget.Workspace);
    await waitFor("the long line's warning", () => codes(doc.uri).includes("3:line-too-long"));
    await settings.update("maxLineLength", undefined, vscode.ConfigurationTarget.Workspace);
    await waitFor("no more", () => !codes(doc.uri).includes("3:line-too-long"));
  });

  test("semantic highlighting", async () => {
    const legend = await vscode.commands.executeCommand("vscode.provideDocumentSemanticTokensLegend", doc.uri);
    const tokens = await vscode.commands.executeCommand("vscode.provideDocumentSemanticTokens", doc.uri);
    const data = tokens.data;
    const decoded = [];
    let line = 0;
    let char = 0;
    for (let k = 0; k < data.length; k += 5) {
      line += data[k];
      char = data[k] === 0 ? char + data[k + 1] : data[k + 1];
      const text = doc.lineAt(line).text.substr(char, data[k + 2]);
      decoded.push(`${text}:${legend.tokenTypes[data[k + 3]]}`);
    }
    for (const t of ["# A program with mistakes:comment", "fn:keyword", "fib:function", "n:parameter", "total:variable", "while:keyword", "0:number", "print:function"]) {
      assert.ok(decoded.includes(t), `${t} in ${decoded}`);
    }
  });

  test("folding", async () => {
    const folds = await vscode.commands.executeCommand("vscode.executeFoldingRangeProvider", doc.uri);
    const spans = folds.map((f) => `${f.start}-${f.end}`);
    assert.ok(spans.includes("1-3"), spans.join());
    assert.ok(spans.includes("8-10"), spans.join());
  });

  test("rename", async () => {
    const edit = await vscode.commands.executeCommand("vscode.executeDocumentRenameProvider", doc.uri, pos(7, 4), "k");
    const edits = edit.get(doc.uri);
    assert.deepStrictEqual(edits.map((e) => e.range.start.line), [7, 8, 9, 10, 10]);
    assert.ok(edits.every((e) => e.newText === "k"));
  });

  test("diagnostics follow the edits", async () => {
    const editor = vscode.window.activeTextEditor;
    await editor.edit((b) => b.insert(pos(12, 0), "let missing = 1;\n"));
    await waitFor("the diagnostics after the edit", () => codes(doc.uri).join() === "14:break-outside-loop");
    // and typing a broken line: a syntax error, the rest still checked
    await editor.edit((b) => b.insert(pos(12, 0), "let oops = ;\n"));
    await waitFor("the syntax error", () => codes(doc.uri).join() === "12:syntax,15:break-outside-loop");
    const locs = await vscode.commands.executeCommand("vscode.executeDefinitionProvider", doc.uri, pos(9, 21));
    assert.strictEqual(locs.length, 1);
  });

  test("a quick fix for a typo", async () => {
    const editor = vscode.window.activeTextEditor;
    // (at the end, where `total` is defined)
    const line = doc.lineCount - 1;
    await editor.edit((b) => b.insert(pos(line, 0), "print(totl);\n"));
    await waitFor("the undefined name", () => codes(doc.uri).includes(`${line}:undefined-name`));
    const actions = await vscode.commands.executeCommand("vscode.executeCodeActionProvider", doc.uri, new vscode.Range(pos(line, 6), pos(line, 10)));
    const fix = actions.find((a) => a.title === "Change to 'total'");
    assert.ok(fix, actions.map((a) => a.title).join());
    await vscode.workspace.applyEdit(fix.edit);
    assert.strictEqual(doc.lineAt(line).text, "print(total);");
  });
});
