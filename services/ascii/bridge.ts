import { execFile } from 'node:child_process';
import { join } from 'node:path';
import { promisify } from 'node:util';
import { ROOT } from '../epub/src/archive';
const execute = promisify(execFile);
export interface AsciiOptions { width?: number; height?: number; invert?: boolean; ramp?: string; background?: 'white' | 'black' }
export function asciiBinary(): string { return process.env.HIKARI_ASCII || process.env.WIZ_ASCII || join(ROOT, 'build/wiz-ascii'); }
export async function imageToAscii(path: string, options: AsciiOptions = {}): Promise<{ text: string; columns: number; rows: number }> {
  if (typeof path !== 'string' || !path || path.includes('\0')) throw new Error('image path is required');
  if (!options || typeof options !== 'object' || Array.isArray(options)) throw new Error('ASCII options must be an object');
  const args = [path];
  for (const [key, maximum] of [['width', 400], ['height', 200]] as const) {
    const value = options[key];
    if (value !== undefined) {
      if (!Number.isInteger(value) || value < 1 || value > maximum) throw new Error(`invalid ASCII ${key}`);
      args.push(`--${key}`, String(value));
    }
  }
  if (options.invert !== undefined && typeof options.invert !== 'boolean') throw new Error('invert must be boolean');
  if (options.invert) args.push('--invert');
  if (options.ramp !== undefined) {
    if (typeof options.ramp !== 'string' || !/^[\x20-\x7e]{2,64}$/.test(options.ramp)) throw new Error('invalid ASCII ramp');
    args.push('--ramp', options.ramp);
  }
  if (options.background !== undefined) {
    if (!['white', 'black'].includes(options.background)) throw new Error('invalid ASCII background');
    args.push('--background', options.background);
  }
  // Always append a flag, so a filename equal to --help/--version is not treated
  // as a standalone control command by the native CLI.
  if (options.width === undefined) args.push('--width', '80');
  let stdout: string;
  try {
    ({ stdout } = await execute(asciiBinary(), args, { encoding: 'utf8', timeout: 15000, maxBuffer: 256 * 1024 }));
  } catch (error) {
    const err = error as { stderr?: string; code?: string | number };
    throw new Error(`ASCII conversion failed: ${err.stderr?.trim() || String(err.code || 'process error')}`);
  }
  const lines = stdout.endsWith('\n') ? stdout.slice(0, -1).split('\n') : stdout.split('\n');
  return { text: stdout, columns: lines[0].length, rows: lines.length };
}
