import { posix } from 'node:path';
export function memberPath(name: string): string {
  if (!name || name.startsWith('/') || /[\\:\x00-\x1f\x7f]/u.test(name) ||
      name.replace(/\/$/, '').split('/').some(s => !s || s === '.' || s === '..')) {
    throw new Error(`unsafe archive path: ${name}`);
  }
  return name;
}
export function resolveHref(packagePath: string, href: string): string {
  if (typeof href !== 'string') throw new Error('missing manifest href');
  const decoded = decodeURIComponent(href.split('#')[0]);
  if (!decoded || decoded.startsWith('/') || /[\\:\x00-\x1f\x7f?]/u.test(decoded)) {
    throw new Error('external or unsafe EPUB reference');
  }
  return memberPath(posix.normalize(posix.join(posix.dirname(packagePath), decoded)));
}
