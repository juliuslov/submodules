import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { BINARY_ENV, PROCESS_MAX_OUTPUT, PROCESS_TIMEOUT_MS } from '../limits';
import type { AsciiGridOptions, AsciiRender } from '../types';

/** Optional compatibility backend for an external `wiz-ascii` executable.
 *
 * It exists for setups that already ship a standalone CLI (or want to point
 * hikari at one they built themselves) through `HIKARI_ASCII`/`WIZ_ASCII`.
 * Arguments are passed as an argv vector — never a shell string — and a
 * `--width` flag is always appended so a file literally named `--help` cannot
 * turn into a control command. */

const execute = promisify(execFile);

export function configuredBinary(): string | null {
  for (const name of BINARY_ENV) {
    const value = process.env[name];
    if (value) return value;
  }
  return null;
}

export function processStatus(): { available: boolean; detail: string } {
  const binary = configuredBinary();
  if (!binary) return { available: false, detail: `unset: set ${BINARY_ENV.join(' or ')} to use an external wiz-ascii executable` };
  return { available: true, detail: binary };
}

export async function renderWithProcess(binary: string, path: string, options: AsciiGridOptions): Promise<AsciiRender> {
  const args = [path, '--width', String(options.width)];
  if (options.height !== undefined) args.push('--height', String(options.height));
  if (options.invert) args.push('--invert');
  if (options.ramp !== undefined) args.push('--ramp', options.ramp);
  args.push('--background', options.background === 0 ? 'black' : 'white');
  let stdout: string;
  try {
    ({ stdout } = await execute(binary, args, { encoding: 'utf8', timeout: PROCESS_TIMEOUT_MS, maxBuffer: PROCESS_MAX_OUTPUT }));
  } catch (error) {
    const failed = error as { stderr?: string; code?: string | number };
    // The shared prefix is added by imageToAscii(), not here.
    throw new Error(failed.stderr?.trim() || String(failed.code || 'process error'));
  }
  const lines = stdout.endsWith('\n') ? stdout.slice(0, -1).split('\n') : stdout.split('\n');
  return { text: stdout, columns: lines[0].length, rows: lines.length };
}
