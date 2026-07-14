'use strict';

const fs = require('fs');
const path = require('path');

const repositoryRoot = path.resolve(__dirname, '..');
const reactNativeRoot = path.join(repositoryRoot, 'third-party/react-native/packages/react-native');
const outputRoot = path.join(repositoryRoot, '.rn-build/generated/FBReactNativeSpec');
const executorRoot = path.join(
  reactNativeRoot,
  'scripts/codegen/generate-artifacts-executor',
);
const {
  buildCodegenIfNeeded,
  findProjectRootLibraries,
  readPkgJsonInDirectory,
} = require(path.join(executorRoot, 'utils'));
const {generateSchemaInfo} = require(path.join(executorRoot, 'generateSchemaInfos'));
const {generateCode} = require(path.join(executorRoot, 'generateNativeCode'));

buildCodegenIfNeeded();
const packageJSON = readPkgJsonInDirectory(reactNativeRoot);
const library = findProjectRootLibraries(packageJSON, reactNativeRoot).find(
  candidate => candidate.config.name === 'FBReactNativeSpec',
);
if (!library) {
  throw new Error('FBReactNativeSpec is absent from the React Native package');
}

fs.rmSync(outputRoot, {recursive: true, force: true});
fs.mkdirSync(outputRoot, {recursive: true});
const schema = generateSchemaInfo(library, 'ios');
generateCode(outputRoot, schema, false, 'ios', true);
console.info(`[Nucleus Codegen] Generated FBReactNativeSpec at ${outputRoot}`);
