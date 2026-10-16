import { conversionFormats, convertMobi, inspectMobi, type ConversionOptions } from '../../mobi';
import { runKoSync, type KoSyncRequest } from '../../kosync';
import { imageToAscii, type AsciiOptions } from '../../ascii';
import { inspectBook, readChapter, createBook, scanLibrary, inspectArchive, doctor } from './index';
import type { BookInput } from './types';

/** JSON-RPC request envelope accepted on stdin and from argv. */
export interface Request {
  action: string;
  path?: string;
  index?: number;
  input?: BookInput;
  output?: string;
  query?: string;
  options?: AsciiOptions;
  sync?: KoSyncRequest;
  conversion?: ConversionOptions;
}

export const USAGE =
  'usage: cli.cjs convert|mobi-convert <input> <output.epub|output.mobi|output.azw3> [native|libmobi|calibre]; ' +
  'mobi-inspect <file>; libmobi-inspect <file>; ascii <image> [width]; kosync-authorize|kosync-register; ' +
  'kosync-pull <document>; kosync-push <spec.json>; kosync-document <file> [binary|filename]; ' +
  'inspect|read|archive <file> [zero-based-index]; create <spec.json> <output.epub>; scan <directory> [query]; ' +
  'formats; doctor; rpc';

/** Every request path is validated before it reaches a service. */
export function requiredPath(value: unknown): string {
  if (typeof value !== 'string' || !value || value.includes('\0')) throw new Error('a nonempty path is required');
  return value;
}

/** Runs one request. Successful results are returned as JSON-serialisable data;
 * every failure throws so the single caller can emit one error document. */
export async function dispatch(request: Request): Promise<unknown> {
  if (!request || typeof request !== 'object') throw new Error('request object required');
  switch (request.action) {
    case 'convert':
    case 'mobi-convert': return convertMobi(requiredPath(request.path), requiredPath(request.output), request.conversion);
    case 'formats': return conversionFormats();
    case 'libmobi-inspect': return inspectMobi(requiredPath(request.path), true);
    case 'mobi-inspect': return inspectMobi(requiredPath(request.path));
    case 'kosync': return runKoSync(request.sync!);
    case 'ascii': return imageToAscii(requiredPath(request.path), request.options ?? {});
    case 'inspect': return inspectBook(requiredPath(request.path));
    case 'read': return readChapter(requiredPath(request.path), request.index ?? 0);
    case 'create': return createBook(request.input!, requiredPath(request.output));
    case 'scan':
      if (request.query !== undefined && typeof request.query !== 'string') throw new Error('query must be a string');
      return scanLibrary(requiredPath(request.path), request.query);
    case 'archive': return inspectArchive(requiredPath(request.path));
    case 'doctor': return doctor();
    default: throw new Error(USAGE);
  }
}
