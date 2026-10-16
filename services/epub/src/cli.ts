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

/** `convert <input> <output> [native|libmobi|calibre] [--title T] [--author A]
 *  [--language L] [--cover image] [--timeout ms]`.
 *
 * The backend stays a positional argument for compatibility with the original
 * CLI, while metadata overrides and the cover are named flags. */
function convertRequest(action: string, argv: string[]): Request {
  const [path, output, ...rest] = argv;
  const conversion: Record<string, unknown> = {};
  for (let at = 0; at < rest.length; at += 1) {
    const token = rest[at];
    if (!token.startsWith('--')) {
      if (conversion.backend !== undefined) throw new Error('only one conversion backend may be given');
      conversion.backend = token;
      continue;
    }
    const value = rest[at + 1];
    if (value === undefined) throw new Error(`${token} needs a value`);
    at += 1;
    const flag = token.toLowerCase();
    if (flag === '--cover') conversion.cover = value;
    else if (flag === '--title') conversion.title = value;
    else if (flag === '--author') conversion.author = value;
    else if (flag === '--language') conversion.language = value;
    else if (flag === '--timeout') conversion.timeoutMs = Number(value);
    else throw new Error(`unknown conversion flag: ${token}`);
  }
  return { action, path, output, conversion: Object.keys(conversion).length ? conversion as ConversionOptions : undefined };
}

/** `mobi-tag <file> <output> [--title T] [--author A] …` and `mobi-cover`.
 *
 * Flags are parsed here rather than in the service so a typo (`--titel`) fails
 * instead of being silently ignored. */
function metadataRequest(action: string, argv: string[]): Request {
  const [path, ...rest] = argv;
  const fields: Record<string, string | null> = {};
  const allowed = new Set(['--title', '--author', '--publisher', '--description', '--isbn', '--subject',
    '--publishdate', '--contributor', '--rights', '--type', '--review', '--copyright', '--asin', '--language']);
  let cover: string | undefined, target: string | undefined;
  const positionals: string[] = [];
  for (let at = 0; at < rest.length; at += 1) {
    const token = rest[at];
    if (!token.startsWith('--')) { positionals.push(token); continue; }
    const flag = token.toLowerCase();
    if (flag === '--recursive') throw new Error(`${flag} is not valid here`);
    const value = rest[at + 1];
    if (value === undefined) throw new Error(`${flag} needs a value`);
    at += 1;
    if (flag === '--cover' || flag === '--image') { cover = value; continue; }
    if (flag === '--output') { target = value; continue; }
    if (!allowed.has(flag)) throw new Error(`unknown metadata flag: ${flag}`);
    // An empty value clears the field instead of writing an empty EXTH record.
    fields[flag.slice(2).replace('publishdate', 'publishDate')] = value === '' ? null : value;
  }
  if (action === 'mobi-cover') {
    if (positionals.length) throw new Error('mobi-cover takes --output, not a positional path');
    if (!cover) throw new Error('mobi-cover needs --image <cover.jpg>');
    return { action, path, cover, output: target };
  }
  const output = target ?? positionals[0];
  if (!output) throw new Error('mobi-tag needs an output path (positional or --output)');
  return { action, path, output, metadata: fields as Request['metadata'] };
}

function batchRequest(argv: string[]): Request {
  const [path, output, ...flags] = argv;
  const request: Request = { action: 'mobi-batch', path, output };
  for (let at = 0; at < flags.length; at += 1) {
    const flag = flags[at].toLowerCase();
    if (flag === '--recursive') { request.recursive = true; continue; }
    const value = flags[at + 1];
    if (flag === '--to') { if (!value) throw new Error('--to needs epub, mobi or azw3'); (request as { to?: string }).to = value; at += 1; continue; }
    if (flag === '--concurrency') { if (!value || !Number.isInteger(Number(value))) throw new Error('--concurrency needs an integer'); request.concurrency = Number(value); at += 1; continue; }
    if (flag === '--backend') { if (!value) throw new Error('--backend needs native, libmobi or calibre'); request.conversion = { backend: value as ConversionOptions['backend'] }; at += 1; continue; }
    throw new Error(`unknown batch flag: ${flag}`);
  }
  return request;
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
  if (action === 'mobi-convert' || action === 'convert') return convertRequest(action, argv.slice(1));
  if (action === 'mobi-metadata') return { action, path: file };
  if (action === 'mobi-tag' || action === 'mobi-cover') return metadataRequest(action, argv.slice(1));
  if (action === 'mobi-batch' || action === 'convert-batch') return batchRequest(argv.slice(1));
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
