import { imageToAscii, type AsciiOptions } from '../../ascii/bridge';
import { boundedRead } from './archive';
import { inspectBook, readChapter, createBook, scanLibrary, inspectArchive, doctor } from './index';
import type { BookInput } from './types';
interface Request { action: string; path?: string; index?: number; input?: BookInput; output?: string; query?: string; options?: AsciiOptions }
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
  const [action, file, argument] = process.argv.slice(2);
  let req: Request;
  if (action === 'rpc') req = JSON.parse(await stdin());
  else if (action === 'create') req = { action, input: JSON.parse(boundedRead(path(file), 12 * 1024 * 1024).toString('utf8')), output: argument };
  else if (action === 'ascii') req = { action, path: file, options: argument === undefined ? {} : { width: Number(argument) } };
  else req = { action, path: file, index: argument === undefined ? 0 : Number(argument), query: argument };
  if (!req || typeof req !== 'object') throw new Error('request object required');
  let data: unknown;
  switch (req.action) {
    case 'ascii': data = await imageToAscii(path(req.path), req.options ?? {}); break;
    case 'inspect': data = inspectBook(path(req.path)); break;
    case 'read': data = readChapter(path(req.path), req.index ?? 0); break;
    case 'create': data = createBook(req.input!, path(req.output)); break;
    case 'scan':
      if (req.query !== undefined && typeof req.query !== 'string') throw new Error('query must be a string');
      data = scanLibrary(path(req.path), req.query); break;
    case 'archive': data = inspectArchive(path(req.path)); break;
    case 'doctor': data = doctor(); break;
    default: throw new Error('usage: cli.cjs inspect|read|archive <file> [zero-based-index]; create <spec.json> <output.epub>; scan <directory> [query]; doctor; rpc');
  }
  process.stdout.write(JSON.stringify({ ok: true, data }) + '\n');
}
main().catch(error => {
  process.stderr.write(JSON.stringify({ ok: false, error: error instanceof Error ? error.message : String(error) }) + '\n');
  process.exitCode = 1;
});
