import { build } from 'esbuild';
// TypeScript codec comes directly from the gitlink, not an npm substitute.
await build({ entryPoints: ['vendor/fflate/src/index.ts'], outfile: 'build/vendor/index.js',
  bundle: true, platform: 'node', format: 'cjs', target: 'node22' });
await build({ entryPoints: ['services/epub/src/cli.ts'], outfile: 'dist/cli.cjs',
  bundle: true, platform: 'node', format: 'cjs', target: 'node22' });
await build({ entryPoints: ['services/epub/src/index.ts'], outfile: 'dist/index.cjs',
  bundle: true, platform: 'node', format: 'cjs', target: 'node22' });
