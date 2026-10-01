// Runs the extension's tests inside a real VS Code (downloaded once into
// .vscode-test): a scratch workspace with tiny files, the extension loaded,
// and its server started with this machine's Python and zlsp.
//
//   ZLSP_PYTHON=/path/to/python npm test
//
// ZLSP_PYTHON is the Python with zlsp installed (default: python3); the
// server is examples/tiny/tiny.py of this repository.

const fs = require("fs");
const os = require("os");
const path = require("path");
const { runTests } = require("@vscode/test-electron");

async function main() {
  const extensionDevelopmentPath = path.resolve(__dirname, "..");
  const extensionTestsPath = path.resolve(__dirname, "suite", "index.js");
  const server = path.resolve(__dirname, "..", "..", "..", "examples", "tiny", "tiny.py");

  // The workspace: a program with mistakes, a clean one, and the settings
  // that start the server
  const workspace = fs.mkdtempSync(path.join(os.tmpdir(), "zlsp-vscode-"));
  fs.writeFileSync(
    path.join(workspace, "main.tiny"),
    "# A program with mistakes\nfn fib(n) {\n    if n < 2 { return n; }\n    return fib(n - 1) + fib(n - 2);\n}\n\nlet total = 0;\nlet i = 0;\nwhile i < 10 {\n    total = total + fib(i);\n    i = i + 1;\n}\nprint(total, missing);\nbreak;\n"
  );
  fs.writeFileSync(path.join(workspace, "clean.tiny"), "let x = 1;\nprint(x);\n");
  fs.writeFileSync(path.join(workspace, "broken.tiny"), "let y = ;\nprint(y);\n");
  fs.mkdirSync(path.join(workspace, ".vscode"));
  fs.writeFileSync(
    path.join(workspace, ".vscode", "settings.json"),
    JSON.stringify({
      "tiny.server.command": process.env.ZLSP_PYTHON || "python3",
      "tiny.server.args": [server],
    })
  );

  try {
    await runTests({
      extensionDevelopmentPath,
      extensionTestsPath,
      launchArgs: [workspace, "--disable-extensions", "--skip-welcome", "--skip-release-notes", "--disable-workspace-trust"],
      // (the server inherits it: a source build of zlsp, zgram and zrules)
      extensionTestsEnv: { PYTHONPATH: process.env.PYTHONPATH || "" },
    });
  } catch (err) {
    console.error("the tests failed:", err);
    process.exit(1);
  } finally {
    fs.rmSync(workspace, { recursive: true, force: true });
  }
}

main();
