import { spawn } from 'node:child_process';
import { mkdirSync, lstatSync } from 'node:fs';
import { join } from 'node:path';
import { boundedRead } from '../epub/src/archive';

export function calibreBinary(): string { return process.env.HIKARI_CALIBRE || process.env.WIZ_CALIBRE || 'ebook-convert'; }
/** Explicitly opt-in external engine. Private cwd/config, argv only, bounded logs
 * and a process-group deadline. This is NOT a filesystem/network/DRM sandbox. */
export async function runCalibre(input: string, output: string, directory: string, timeoutMs: number, flags: string[] = []): Promise<Buffer> {
  if (process.platform === 'win32') throw new Error('the Calibre adapter currently requires POSIX');
  const temp = join(directory, 'calibre-tmp');
  for (const name of ['calibre-tmp', 'calibre-config', 'calibre-cache']) mkdirSync(join(directory, name), { recursive: true, mode: 0o700 });
  await new Promise<void>((resolve, reject) => {
    const child = spawn(calibreBinary(), [input, output, ...flags], {
      cwd: directory, detached: true, stdio: ['ignore', 'pipe', 'pipe'],
      env: { ...process.env, CALIBRE_CONFIG_DIRECTORY: join(directory, 'calibre-config'),
        CALIBRE_CACHE_DIRECTORY: join(directory, 'calibre-cache'), CALIBRE_TEMP_DIR: temp,
        TMPDIR: temp, QT_QPA_PLATFORM: 'offscreen' },
    });
    let failure: string | undefined, size = 0;
    const kill = (): void => {
      if (child.pid) { try { process.kill(-child.pid, 'SIGKILL'); } catch { /* already reaped */ } }
    };
    const timer = setTimeout(() => { failure = 'Calibre conversion timed out'; kill(); }, timeoutMs);
    const log = (chunk: Buffer): void => {
      size += chunk.length;
      if (size > 1024 * 1024 && !failure) { failure = 'Calibre diagnostic output exceeds 1 MiB'; kill(); }
    };
    child.stdout.on('data', log); child.stderr.on('data', log);
    child.on('error', error => { failure = `cannot start Calibre ebook-convert: ${(error as NodeJS.ErrnoException).code || 'process error'}; install Calibre or configure HIKARI_CALIBRE`; });
    child.on('close', code => {
      clearTimeout(timer); kill(); // do not leave grandchildren holding private files
      if (failure || code !== 0) reject(new Error(failure || `Calibre conversion failed (exit ${code}); DRM and unsupported/damaged input are not converted`));
      else resolve();
    });
  });
  const info = lstatSync(output);
  if (!info.isFile() || info.isSymbolicLink()) throw new Error('Calibre must produce a regular output file');
  return boundedRead(output, 64 * 1024 * 1024);
}
