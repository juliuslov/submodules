import {
  conversionFormats, convertMobi, inspectMobi, readMetadata, rewriteMetadata, embedCover, inspectCover,
  convertDirectory, vendorSummary, type ConversionOptions, type MetadataField,
} from '../../mobi';
import { runKoSync, type KoSyncRequest } from '../../kosync';
import { imageToAscii, type AsciiOptions } from '../../ascii';
import { readFile } from 'node:fs/promises';
import { boundedRead } from './archive';
import { publish } from '../../mobi/io';
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
  /** Metadata fields to patch (`null` removes a field). */
  metadata?: Partial<Record<MetadataField, string | null>>;
  /** Cover image path for `mobi-cover`. */
  cover?: string;
  /** Batch target format and traversal options. */
  to?: 'epub' | 'mobi' | 'azw3';
  recursive?: boolean;
  concurrency?: number;
}

export const USAGE =
  'usage: cli.cjs convert|mobi-convert <input> <output.epub|output.mobi|output.azw3> [native|libmobi|calibre]; ' +
  'mobi-inspect <file>; libmobi-inspect <file>; mobi-metadata <file>; mobi-tag <file> <output> [--title T] [--author A]; ' +
  'mobi-cover <file> --image <cover.jpg> [--output <out.mobi>]; mobi-batch <directory> <output-dir> [--to mobi|epub|azw3] [--recursive]; ' +
  'convert flags: --title/--author/--language/--cover/--timeout; ' +
  'vendors; ascii <image> [width]; kosync-authorize|kosync-register; ' +
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
    case 'vendors': return vendorSummary();
    case 'libmobi-inspect': return inspectMobi(requiredPath(request.path), true);
    case 'mobi-inspect': return inspectMobi(requiredPath(request.path));
    case 'mobi-metadata': return readMetadata(boundedRead(requiredPath(request.path), 64 * 1024 * 1024));
    case 'mobi-tag': {
      const target = requiredPath(request.output);
      const changes = request.metadata ?? {};
      // Only EXTH text fields are patchable; the text records are never touched.
      const known = ['author', 'publisher', 'description', 'isbn', 'subject', 'publishDate', 'contributor',
        'rights', 'type', 'review', 'copyright', 'asin', 'title', 'language'] as const;
      if (!Object.keys(changes).length) throw new Error('no metadata changes supplied');
      for (const key of Object.keys(changes)) {
        if (!(known as readonly string[]).includes(key)) throw new Error(`unsupported metadata field: ${key}`);
        const value = changes[key as (typeof known)[number]];
        if (value !== null && (typeof value !== 'string' || Buffer.byteLength(value) > 4096)) throw new Error(`invalid value for ${key}`);
      }
      const updated = rewriteMetadata(boundedRead(requiredPath(request.path), 64 * 1024 * 1024), changes);
      publish(target, updated);
      return { path: target, bytes: updated.length, metadata: readMetadata(updated) };
    }
    case 'mobi-cover': {
      const source = requiredPath(request.path);
      const image = inspectCover(Buffer.from(await readFile(requiredPath(request.cover))));
      const embedded = embedCover(boundedRead(source, 64 * 1024 * 1024), image.bytes);
      if (request.output) publish(requiredPath(request.output), embedded.bytes);
      return { kind: embedded.kind, record: embedded.record, bytes: embedded.bytes.length, path: request.output ?? null };
    }
    case 'mobi-batch': return convertDirectory(requiredPath(request.path), requiredPath(request.output), {
      to: request.to, recursive: request.recursive, concurrency: request.concurrency, ...request.conversion,
    });
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
