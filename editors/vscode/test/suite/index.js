// Mocha, inside VS Code's extension host.

const path = require("path");
const Mocha = require("mocha");

function run() {
  const mocha = new Mocha({ ui: "tdd", color: true, timeout: 60000 });
  mocha.addFile(path.resolve(__dirname, "features.test.js"));
  return new Promise((resolve, reject) => {
    mocha.run((failures) => (failures ? reject(new Error(`${failures} tests failed`)) : resolve()));
  });
}

module.exports = { run };
