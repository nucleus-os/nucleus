const path = require("path");

const nucleusCore = path.resolve(__dirname, "../../core");
const { makeNucleusBabelConfig } = require(path.join(
  nucleusCore,
  "packages/app/tools/babel-config",
));

module.exports = makeNucleusBabelConfig({
  reactCompiler: false,
  reanimated: false,
});
