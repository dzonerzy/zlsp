// A VS Code extension for one language: it starts the language's zlsp server
// (a Python script calling Server(...).start_io()) and connects the editor
// to it. Everything else (diagnostics, navigation, highlighting, completion)
// comes from the server.

const vscode = require("vscode");
const { LanguageClient, TransportKind } = require("vscode-languageclient/node");

let client;

function activate(context) {
  const config = vscode.workspace.getConfiguration("tiny.server");
  const serverOptions = {
    command: config.get("command"),
    args: config.get("args"),
    transport: TransportKind.stdio,
  };
  const clientOptions = {
    documentSelector: [{ scheme: "file", language: "tiny" }],
  };
  client = new LanguageClient("tiny", "tiny language server", serverOptions, clientOptions);
  context.subscriptions.push(client);
  return client.start();
}

function deactivate() {
  return client ? client.stop() : undefined;
}

module.exports = { activate, deactivate };
