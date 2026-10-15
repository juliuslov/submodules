import { asciiBinary } from '../../ascii/bridge';
import { execFileSync } from 'node:child_process';
import { existsSync } from 'node:fs';
import { join } from 'node:path';
import { archiveBinary, ROOT } from './archive';
export function doctor(): object {
  let archive: { available: boolean; version?: string; error?: string };
  try { archive = { available: true, version: execFileSync(archiveBinary(), ['--version'], { encoding: 'utf8', timeout: 5000 }).trim() }; }
  catch (err) { archive = { available: false, error: (err as Error).message }; }
  let ascii: object;
  try { ascii = { available: true, version: execFileSync(asciiBinary(), ['--version'], { encoding: 'utf8', timeout: 5000 }).trim() }; }
  catch { ascii = { available: false, error: 'build the Rust ASCII service with make ascii' }; }
  return { ascii, node: process.version, archive, submodules: {
    stb: existsSync(join(ROOT, 'vendor/stb/stb_image.h')),
    miniz: existsSync(join(ROOT, 'vendor/miniz/miniz.h')),
    fflate: existsSync(join(ROOT, 'vendor/fflate/src/index.ts')),
    dkjson: existsSync(join(ROOT, 'vendor/dkjson/dkjson.lua')),
  } };
}
