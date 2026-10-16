import type { EbookFormat } from './formats';
export interface MobiInfo {
  ok: true; version: number; compression: number; encoding: number;
  hybrid?: boolean; kf8?: boolean; publisher?: string; imprint?: string; description?: string; isbn?: string;
  subject?: string; publishdate?: string; review?: string; contributor?: string; copyright?: string; asin?: string;
  textBytes: number; records: number; title: string; author: string; language: string;
}
export interface ConversionResult {
  path: string; bytes: number; from: EbookFormat; to: EbookFormat; backend: 'native' | 'libmobi' | 'calibre';
  title: string; chapters: number; lossless: false; warnings: string[];
}
export interface ConversionOptions { backend?: 'native' | 'libmobi' | 'calibre'; timeoutMs?: number }
