import type { ConversionOptions } from '../../mobi';
import type { KoSyncRequest } from '../../kosync';
import { boundedRead } from './archive';
import { dispatch, requiredPath, type Request } from './rpc';
import type { AsciiOptions } from '../../ascii';
import type { BookInput } from './types';

/** Command line front-end.
 *
 * It only translates argv/stdin into a `Request` and prints exactly one JSON
 * document: success on stdout, failure on stderr with a non-zero exit code.
 * No progress logs are written to stdout, so Lua and shell callers can parse
 * the output directly. */

async function stdin(): Promise<string> {
  const chunks: Buffer[] = [];
  let length = 0;
  for await (const chunk of process.stdin) {
    length += chunk.length;
    if (length > 12 * 1024 * 1024) throw new Error('request exceeds 12 MiB');
    chunks.push(Buffer.from(chunk));
  }
  return Buffer.concat(chunks).toString('utf8');
}

/** `ascii <image> [--width N] [--height N] [--ramp TEXT] [--invert] [--background white|black]`.
 *
 * The bare-number form (`ascii photo.png 100`) is kept for compatibility with
 * the retired standalone `wiz-ascii` CLI, which took the width positionally. */
function asciiRequest(argv: string[]): Request {
  const [path, ...rest] = argv;
  const options: Record<string, unknown> = {};
  if (rest.length && /^\d+$/.test(rest[0])) options.width = Number(rest.shift());
  const numeric = new Set(['--width', '--height']);
  for (let at = 0; at < rest.length; at += 1) {
    const flag = rest[at];
    if (flag === '--invert') { options.invert = true; continue; }
    if (!numeric.has(flag) && flag !== '--ramp' && flag !== '--background') throw new Error(`unknown ascii option: ${flag}`);
    const value = rest[at + 1];
    if (value === undefined) throw new Error(`${flag} needs a value`);
    options[flag.slice(2)] = numeric.has(flag) ? Number(value) : value;
    at += 1;
  }
  return { action: 'ascii', path, options: options as AsciiOptions };
}

function koSyncRequest(action: string, file: string | undefined, argument: string | undefined): Request {
  const operation = action.slice(7);
  if (!['authorize', 'register', 'pull', 'push', 'document'].includes(operation)) throw new Error('unknown KoSync command');
  if (['authorize', 'register'].includes(operation) && file !== undefined) throw new Error('KoSync credentials come from environment, not command arguments');
  if (!['authorize', 'register'].includes(operation)) requiredPath(file);
  return {
    action: 'kosync',
    sync: {
      operation: operation as KoSyncRequest['operation'],
      document: file,
      path: file,
      checksum: argument as 'binary' | 'filename' | undefined,
      inputPath: operation === 'push' ? file : undefined,
    },
  };
}

async function requestFromArgv(argv: string[]): Promise<Request> {
  const [action, file, argument, backend] = argv;
  if (action === 'rpc') return JSON.parse(await stdin()) as Request;
  if (action === 'create') {
    return { action, input: JSON.parse(boundedRead(requiredPath(file), 12 * 1024 * 1024).toString('utf8')) as BookInput, output: argument };
  }
  if (action === 'mobi-convert' || action === 'convert') {
    return { action, path: file, output: argument, conversion: backend === undefined ? undefined : { backend: backend as ConversionOptions['backend'] } };
  }
  if (action?.startsWith('kosync-')) return koSyncRequest(action, file, argument);
  if (action === 'ascii') return asciiRequest(argv.slice(1));
  return { action, path: file, index: argument === undefined ? 0 : Number(argument), query: argument };
}

async function main(): Promise<void> {
  const data = await dispatch(await requestFromArgv(process.argv.slice(2)));
  process.stdout.write(`${JSON.stringify({ ok: true, data })}\n`);
}

main().catch((error: unknown) => {
  process.stderr.write(`${JSON.stringify({ ok: false, error: error instanceof Error ? error.message : String(error) })}\n`);
  process.exitCode = 1;
});
