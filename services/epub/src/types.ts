export interface ArchiveEntry { name: string; size: number; compressedSize: number; method: number }
export interface Inventory { ok: true; totalBytes: number; entries: ArchiveEntry[] }
export interface Chapter { id: string; href: string; mediaType: string; linear: boolean }
export interface BookInfo {
  title: string; creators: string[]; language: string; identifier: string;
  packagePath: string; version: string; chapters: Chapter[];
}
export interface BookInput {
  title: string; author: string; language: string; identifier?: string; modified?: string;
  chapters: { title: string; text: string }[];
}
