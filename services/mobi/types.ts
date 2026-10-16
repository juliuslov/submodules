import type { EbookFormat } from './formats';
export interface MobiInfo {
  ok: true; version: number; compression: number; encoding: number;
  hybrid?: boolean; kf8?: boolean; publisher?: string; imprint?: string; description?: string; isbn?: string;
  subject?: string; publishdate?: string; review?: string; contributor?: string; copyright?: string; asin?: string;
  textBytes: number; records: number; title: string; author: string; language: string;
}
export interface ConversionResult {
  path: string; bytes: number; from: EbookFormat | 'text'; to: EbookFormat; backend: 'native' | 'libmobi' | 'calibre';
  title: string; chapters: number; lossless: false; warnings: string[];
  /** Kind of the attached cover, when one was embedded. */
  cover?: string;
}
export interface ConversionOptions {
  backend?: 'native' | 'libmobi' | 'calibre';
  timeoutMs?: number;
  /** Metadata overrides applied to the output book (text sources have none). */
  title?: string;
  author?: string;
  language?: string;
  /** Cover image (JPEG/PNG/GIF) attached to the output book. */
  cover?: string;
}
