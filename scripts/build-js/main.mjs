import { build } from 'esbuild';
import { entryPoints } from './entries.mjs';
const entries = entryPoints();
if (!entries.length) throw new Error('no TypeScript sources found under services/');
// bundle:false preserves every source module as its own CommonJS file and
// leaves relative require() specifiers untouched, so the emitted tree
// (dist/epub/src/*, dist/mobi/*, dist/kosync/*, dist/ascii/*) mirrors
// services/. Node resolves those relative files natively; no outfile
// bundle is produced. Pinned fflate is emitted per-file by tsc into
// build/vendor/ (scripts/tsconfig.vendor.json), which services import as
// ../../../build/vendor/index.js from both source and dist locations.
await build({ entryPoints: entries, outbase: 'services', outdir: 'dist',
  bundle: false, platform: 'node', format: 'cjs', target: 'node22' });
console.log(`emitted ${entries.length} modules to dist/ (no single-file bundle)`);
