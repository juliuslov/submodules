import { readdirSync } from 'node:fs';
import { join } from 'node:path';
// One entry per TypeScript source file: esbuild is used as a per-file
// transpiler (bundle:false), never as a single-file bundler. See
// https://esbuild.github.io/api/#outdir and docs/BUILD.md.
export function entryPoints(root = 'services') {
  return readdirSync(root, { recursive: true, withFileTypes: true })
    .filter((e) => e.isFile() && e.name.endsWith('.ts'))
    .map((e) => join(e.parentPath, e.name))
    .sort();
}
