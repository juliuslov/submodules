#!/usr/bin/env node
// Builds the optional napi-rs ASCII addon.
//
// Rust is not required to use hikari: when no Cargo toolchain is present this
// script prints how to get the native renderer and exits successfully, and the
// TypeScript renderer in services/ascii/render/ is used instead. A toolchain
// that IS present and then fails to build is a real error and fails the build.
import { spawnSync } from 'node:child_process';
import { existsSync, readdirSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const crate = join(root, 'services/ascii/native/Cargo.toml');
const output = join(root, 'build');
const strict = process.argv.slice(2).includes('--require-native');
const configured = process.env.HIKARI_ASCII_NATIVE;

function notice(message) {
  console.log(`hikari: ${message}`);
}

function fail(message) {
  console.error(`hikari ascii: ${message}`);
  process.exitCode = 1;
}

function probe(command, args) {
  const result = spawnSync(command, args, { encoding: 'utf8', timeout: 20000 });
  return !result.error && result.status === 0 ? (result.stdout || result.stderr).trim() : null;
}

// 1. A prebuilt addon wins: no toolchain needed, which is the supported answer
//    for Termux/Android and for machines without Rust.
if (configured) {
  if (!existsSync(configured)) fail(`HIKARI_ASCII_NATIVE points at a missing file: ${configured}`);
  else notice(`using prebuilt ASCII addon ${configured}`);
  process.exit();
}

// 2. Build with napi-rs when both Cargo and the local @napi-rs/cli are present.
const cargo = process.env.HIKARI_CARGO || process.env.CARGO || 'cargo';
const version = existsSync(crate) ? probe(cargo, ['--version']) : null;
if (!version) {
  if (strict) {
    fail(`Rust toolchain not found (${cargo}). Install Rust 1.88+ or set HIKARI_ASCII_NATIVE to a prebuilt addon.`);
  } else {
    notice('Rust toolchain not found; keeping the built-in TypeScript ASCII renderer (make ascii is optional).');
    notice('native build: install Rust 1.88+ then run `npm run build:ascii`, or point HIKARI_ASCII_NATIVE at a .node file.');
  }
  process.exit();
}
const napi = probe(join(root, 'node_modules/.bin/napi'), ['--version']);
if (!napi) {
  fail('@napi-rs/cli is missing; run `npm ci` before building the native addon.');
  process.exit();
}
notice(`building the ASCII addon with ${version.split('\n')[0]} and @napi-rs/cli ${napi}`);
const build = spawnSync(
  join(root, 'node_modules/.bin/napi'),
  ['build', '--platform', '--release', '--strip', '--no-js',
    '--manifest-path', crate, '--package-json-path', join(root, 'package.json'), '--output-dir', output],
  { cwd: root, stdio: 'inherit' },
);
if (build.error) fail(`cannot run @napi-rs/cli: ${build.error.message}`);
else if (build.status !== 0) fail(`@napi-rs/cli exited with ${build.signal || build.status}`);
else {
  const built = existsSync(output) ? readdirSync(output).filter(name => name.startsWith('hikari-ascii.') && name.endsWith('.node')) : [];
  if (!built.length) fail('the addon build produced no hikari-ascii.*.node file');
  else notice(`built ${built.join(', ')} in build/`);
}
