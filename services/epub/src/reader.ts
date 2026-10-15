import { unpackEpub } from './archive';
import { memberPath, resolveHref } from './paths';
import { array, scalar, parseXml, chapterText } from './xml';
import type { BookInfo, Chapter } from './types';

export function loadBook(path: string): { info: BookInfo; files: Record<string, Uint8Array> } {
  const files = unpackEpub(path);
  const xml = (name: string): any => {
    if (!Object.hasOwn(files, name)) throw new Error(`missing EPUB resource: ${name}`);
    return parseXml(new TextDecoder('utf-8', { fatal: true }).decode(files[name]));
  };
  const container = xml('META-INF/container.xml');
  const roots = array<any>(container.container?.rootfiles?.rootfile);
  const root = roots.find(r => r['@media-type'] === 'application/oebps-package+xml');
  if (!root || typeof root['@full-path'] !== 'string') throw new Error('missing EPUB package rootfile');
  const packagePath = memberPath(root['@full-path']);
  const pkg = xml(packagePath).package;
  if (!pkg || !['2.0', '3.0'].includes(pkg['@version'])) throw new Error('unsupported EPUB package version');
  const items = new Map<string, any>();
  for (const item of array<any>(pkg.manifest?.item)) {
    const id = item['@id'];
    if (typeof id !== 'string' || !id || items.has(id)) throw new Error('invalid or duplicate manifest ID');
    items.set(id, { ...item, path: resolveHref(packagePath, item['@href']) });
  }
  const chapters: Chapter[] = array<any>(pkg.spine?.itemref).map(ref => {
    const item = items.get(ref['@idref']);
    if (!item) throw new Error('spine references missing manifest item');
    if (item['@media-type'] !== 'application/xhtml+xml') throw new Error('only XHTML spine content is supported');
    if (!Object.hasOwn(files, item.path)) throw new Error('missing spine resource');
    return { id: ref['@idref'], href: item.path, mediaType: item['@media-type'], linear: ref['@linear'] !== 'no' };
  });
  if (!chapters.length) throw new Error('EPUB spine is empty');
  const metadata = pkg.metadata;
  const identifier = array<any>(metadata?.identifier).find(id => id?.['@id'] === pkg['@unique-identifier']);
  return { files, info: {
    title: scalar(array(metadata?.title)[0]), creators: array(metadata?.creator).map(scalar),
    language: scalar(array(metadata?.language)[0]), identifier: scalar(identifier),
    packagePath, version: pkg['@version'], chapters,
  } };
}
export function inspectBook(path: string): BookInfo { return loadBook(path).info; }
export function readChapter(path: string, index: number): { chapter: Chapter; text: string } {
  const { info, files } = loadBook(path);
  if (!Number.isInteger(index) || index < 0 || index >= info.chapters.length) throw new Error('chapter index out of range (zero based)');
  const chapter = info.chapters[index];
  return { chapter, text: chapterText(new TextDecoder('utf-8', { fatal: true }).decode(files[chapter.href])) };
}
