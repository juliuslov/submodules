import { readdirSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { inspectBook } from './reader';
import type { BookInfo } from './types';
export function scanLibrary(directory: string, query = ''): {
  books: { path: string; info: BookInfo }[]; errors: { path: string; error: string }[];
} {
  const books = [], errors = [];
  // Deliberately nonrecursive: no symlink traversal or unbounded tree walking.
  const entries = readdirSync(directory, { withFileTypes: true });
  const candidates = entries.filter(e => e.isFile() && /\.epub$/i.test(e.name)).sort((a, b) => a.name.localeCompare(b.name));
  if (candidates.length > 256) throw new Error('library exceeds 256 EPUB files; choose a smaller directory');
  for (const entry of candidates) {
    const path = join(resolve(directory), entry.name);
    try {
      const info = inspectBook(path);
      if (`${info.title}\n${info.creators.join('\n')}`.toLocaleLowerCase().includes(query.toLocaleLowerCase())) books.push({ path, info });
    } catch (error) { errors.push({ path, error: (error as Error).message }); }
  }
  return { books, errors };
}
