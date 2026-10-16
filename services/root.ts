import { existsSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

/** The checkout root every service resolves tool paths against.
 *
 * `dist/` is a multi-file ESM build whose shared code lives in chunks next to
 * the entry points, so a module can no longer assume that its own directory
 * depth inside the repository equals its depth inside `src/`. Walking up to
 * the package manifest keeps the location independent of the bundle layout
 * and of the working directory, and still works when the checkout is installed
 * as `stdpath('data')/site/pack/.../start/hikari`. */
function locate(start: string): string {
  let directory = start;
  for (let level = 0; level < 16; level += 1) {
    if (existsSync(join(directory, 'package.json')) &&
        (existsSync(join(directory, '.gitmodules')) || existsSync(join(directory, 'services')))) {
      return directory;
    }
    const parent = dirname(directory);
    if (parent === directory) break;
    directory = parent;
  }
  return start;
}

/** Explicit override for packaged or relocated checkouts. */
export const ROOT = process.env.HIKARI_ROOT
  ? resolve(process.env.HIKARI_ROOT)
  : locate(dirname(fileURLToPath(import.meta.url)));

export function rootPath(...parts: string[]): string {
  return resolve(ROOT, ...parts);
}
