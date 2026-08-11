// Flat ESLint config for the workspace (ESM)
// - React Compiler hooks via react-hooks recommended-latest
// - JS (Flow shims) via @babel/eslint-parser
// - TS/TSX via @typescript-eslint/parser

import { defineConfig } from 'eslint/config';
import reactHooks from 'eslint-plugin-react-hooks';
import react from 'eslint-plugin-react';
import tsPlugin from '@typescript-eslint/eslint-plugin';
import tsParser from '@typescript-eslint/parser';
import babelParser from '@babel/eslint-parser';

export default defineConfig([
  // Global language options: enable JSX everywhere
  {
    files: ['**/*.{js,jsx,ts,tsx}'],
    languageOptions: {
      ecmaVersion: 'latest',
      sourceType: 'module',
      parser: babelParser,
      parserOptions: {
        requireConfigFile: false,
      },
    },
  },

  // React Hooks rules (includes compiler-aware rules)
  reactHooks.configs.flat['recommended-latest'],

  // JavaScript (RN shims use Flow)
  {
    files: ['**/*.js'],
    languageOptions: {
      parser: babelParser,
      parserOptions: {
        requireConfigFile: false,
        babelOptions: {
          plugins: ['@babel/plugin-syntax-flow', '@babel/plugin-transform-flow-strip-types'],
        },
      },
    },
    plugins: { react },
    settings: { react: { version: 'detect' } },
    rules: {
      'react/react-in-jsx-scope': 'off',
      'react/jsx-uses-react': 'off',
    },
  },
  // Ensure Babel parser for example app JS explicitly
  {
    files: ['apps/example/**/*.js'],
    languageOptions: {
      parser: babelParser,
      parserOptions: {
        requireConfigFile: false,
      },
    },
  },

  // TypeScript/TSX
  {
    files: ['**/*.{ts,tsx}'],
    languageOptions: {
      parser: tsParser,
      parserOptions: {
        sourceType: 'module',
        project: false,
      },
    },
    plugins: { '@typescript-eslint': tsPlugin, react },
    settings: { react: { version: 'detect' } },
    rules: {
      'react/react-in-jsx-scope': 'off',
      'react/jsx-uses-react': 'off',
    },
  },

  // Ignores (match Prettier ignores and Nucleus shim files)
  {
    ignores: [
      'node_modules/**',
      'build/**',
      'target/**',
      'CMakeFiles/**',
      'third-party/**',
      'cpp/build/**',
      'apps/*/node_modules/**',
      'tmp/**',
      'dist/**',
      '**/*.nucleus.js',
    ],
  },

  // Ensure the example app JS parses with the RN preset (JSX/Flow/modern syntax)
  {
    files: ['apps/example/**/*.{js,jsx}'],
    languageOptions: {
      parser: babelParser,
      parserOptions: {
        requireConfigFile: false,
        babelOptions: {
          presets: ['module:@react-native/babel-preset'],
        },
      },
    },
  },
]);
