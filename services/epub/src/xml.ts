import { XMLParser, XMLValidator } from 'fast-xml-parser';
export function safeXml(source: string): string {
  // Plain HTML doctype is harmless; never accept external/internal declarations.
  const clean = source.replace(/<!DOCTYPE\s+html\s*>/gi, '');
  if (/<!\s*(DOCTYPE|ENTITY)/i.test(clean)) throw new Error('XML DTD/entity declarations are unsupported');
  if (XMLValidator.validate(clean) !== true) throw new Error('malformed XML');
  return clean;
}
export function parseXml(source: string): any {
  return new XMLParser({ ignoreAttributes: false, attributeNamePrefix: '@',
    removeNSPrefix: true, parseTagValue: false, parseAttributeValue: false,
    trimValues: true, maxNestedTags: 128,
  }).parse(safeXml(source));
}
export function array<T>(value: T | T[] | undefined): T[] {
  return value === undefined ? [] : Array.isArray(value) ? value : [value];
}
export function scalar(value: unknown): string {
  if (typeof value === 'string') return value;
  if (typeof value === 'object' && value !== null) return scalar((value as Record<string, unknown>)['#text']);
  return '';
}
export function xmlText(value: string): string {
  return value.replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&apos;' })[c]!);
}
export function chapterText(source: string): string {
  const nodes = new XMLParser({ preserveOrder: true, ignoreAttributes: false,
    removeNSPrefix: true, parseTagValue: false, trimValues: false,
    htmlEntities: true, maxNestedTags: 128,
  }).parse(safeXml(source));
  const walk = (items: any[]): string => items.map(node => Object.entries(node).map(([tag, value]) => {
    if (tag === '#text') return String(value);
    if (tag === ':@' || tag.startsWith('?') || ['head', 'script', 'style'].includes(tag)) return '';
    const text = Array.isArray(value) ? walk(value) : '';
    return /^(p|div|h[1-6]|li|br|section|article|tr|blockquote|pre|hr)$/.test(tag) ? `\n${text}\n` : text;
  }).join('')).join('');
  return walk(nodes).replace(/[ \t]+/g, ' ').replace(/ *\n */g, '\n').replace(/\n{3,}/g, '\n\n').trim();
}
