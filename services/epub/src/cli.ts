import { conversionFormats } from '../../mobi/formats';
import { convertMobi, inspectMobi, type ConversionOptions } from '../../mobi/convert';
import { runKoSync } from '../../kosync/dispatch';
import type { KoSyncRequest } from '../../kosync/types';
import { imageToAscii, type AsciiOptions } from '../../ascii/bridge';
import { boundedRead } from './archive';
import { inspectBook, readChapter, createBook, scanLibrary, inspectArchive, doctor } from './index';
import type { BookInput } from './types';
interface Request { action: string; path?: string; index?: number; input?: BookInput; output?: string; query?: string; options?: AsciiOptions; sync?: KoSyncRequest; conversion?: ConversionOptions }
function path(value: unknown): string {
  if (typeof value !== 'string' || !value || value.includes('\0')) throw new Error('a nonempty path is required');
  return value;
}
async function stdin(): Promise<string> {
  const chunks: Buffer[] = []; let length = 0;
  for await (const chunk of process.stdin) {
    length += chunk.length;
    if (length > 12 * 1024 * 1024) throw new Error('request exceeds 12 MiB');
    chunks.push(Buffer.from(chunk));
  }
  return Buffer.concat(chunks).toString('utf8');
}
async function main(): Promise<void> {
  const [action, file, argument, backend] = process.argv.slice(2);
  let req: Request;
  if (action === 'rpc') req = JSON.parse(await stdin());
  else if (action === 'create') req = { action, input: JSON.parse(boundedRead(path(file), 12 * 1024 * 1024).toString('utf8')), output: argument };
  else if (action === 'mobi-convert' || action === 'convert') req = { action, path: file, output: argument, conversion: backend === undefined ? undefined : { backend: backend as ConversionOptions['backend'] } };
  else if (action?.startsWith('kosync-')) {
    const operation = action.slice(7);
    if (!['authorize', 'register', 'pull', 'push', 'document'].includes(operation)) throw new Error('unknown KoSync command');
    if (['authorize', 'register'].includes(operation) && file !== undefined) throw new Error('KoSync credentials come from environment, not command arguments');
    if (!['authorize', 'register'].includes(operation)) path(file);
    req = { action: 'kosync', sync: {
      operation: operation as KoSyncRequest['operation'], document: file, path: file,
      checksum: argument as 'binary' | 'filename' | undefined,
      inputPath: operation === 'push' ? file : undefined,
    } };
  }
  else if (action === 'ascii') req = { action, path: file, options: argument === undefined ? {} : { width: Number(argument) } };
  else req = { action, path: file, index: argument === undefined ? 0 : Number(argument), query: argument };
  if (!req || typeof req !== 'object') throw new Error('request object required');
  let data: unknown;
  switch (req.action) {
    case 'convert':
    case 'mobi-convert': data = await convertMobi(path(req.path), path(req.output), req.conversion); break;
    case 'formats': data = conversionFormats(); break;
    case 'mobi-inspect': data = await inspectMobi(path(req.path)); break;
    case 'kosync': data = await runKoSync(req.sync!); break;
    case 'ascii': data = await imageToAscii(path(req.path), req.options ?? {}); break;
    case 'inspect': data = inspectBook(path(req.path)); break;
    case 'read': data = readChapter(path(req.path), req.index ?? 0); break;
    case 'create': data = createBook(req.input!, path(req.output)); break;
    case 'scan':
      if (req.query !== undefined && typeof req.query !== 'string') throw new Error('query must be a string');
      data = scanLibrary(path(req.path), req.query); break;
    case 'archive': data = inspectArchive(path(req.path)); break;
    case 'doctor': data = doctor(); break;
    default: throw new Error('usage: cli.cjs convert|mobi-convert <input> <output.epub|output.mobi|output.azw3> [native|calibre]; mobi-inspect <file>; ascii <image> [width]; kosync-authorize|kosync-register; kosync-pull <document>; kosync-push <spec.json>; kosync-document <file> [binary|filename]; inspect|read|archive <file> [zero-based-index]; create <spec.json> <output.epub>; scan <directory> [query]; doctor; rpc');
  }
  process.stdout.write(JSON.stringify({ ok: true, data }) + '\n');
}
main().catch(error => {
  process.stderr.write(JSON.stringify({ ok: false, error: error instanceof Error ? error.message : String(error) }) + '\n');
  process.exitCode = 1;
});
