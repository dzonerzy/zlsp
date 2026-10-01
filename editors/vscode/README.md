# A VS Code extension for a zlsp language

VS Code starts language servers from extensions: this is a minimal one for the
`tiny` example. Copy the folder and change the language id (`tiny`), the file
extensions (`.tiny`), the comment syntax in `language-configuration.json`, and
the default server command in `package.json`.

```sh
npm install
```

Then open the folder in VS Code and press F5 (a window with the extension
loaded opens), or package it with `npx @vscode/vsce package` and install the
`.vsix` (Extensions view, `...` menu, *Install from VSIX*).

The server command runs from the workspace folder. Set it in the settings,
for example:

```json
{
  "tiny.server.command": "python",
  "tiny.server.args": ["/path/to/tiny.py"]
}
```

The Python that runs it needs zlsp installed (`pip install zlsp-py`).

## Tests

`test/` runs every feature inside a real VS Code (downloaded once into
`.vscode-test`), through its own LSP client, against `examples/tiny`:

```sh
ZLSP_PYTHON=$(which python) npm test        # on a headless Linux: xvfb-run -a npm test
```

CI runs it on every push.
