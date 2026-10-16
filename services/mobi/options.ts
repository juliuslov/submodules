import type { ConversionOptions } from './types';

/** Conversion backend. `native` is the default and never falls back silently. */
export type Backend = 'native' | 'libmobi' | 'calibre';

export interface Settings {
  backend: Backend;
  timeout: number;
  /** Metadata overrides; mainly for text sources that carry none. */
  title?: string;
  author?: string;
  language?: string;
  /** Cover image path applied to the output book. */
  cover?: string;
}

/** Validates conversion options; unknown keys are rejected as typos. */
export function settings(options: ConversionOptions): Settings {
  if (!options || typeof options !== 'object' || Array.isArray(options) ||
      Object.keys(options).some(key => !['backend', 'timeoutMs', 'title', 'author', 'language', 'cover'].includes(key))) {
    throw new Error('invalid conversion options');
  }
  const backend = options.backend ?? 'native';
  const timeout = options.timeoutMs ?? 45000;
  if (backend !== 'native' && backend !== 'libmobi' && backend !== 'calibre') {
    throw new Error('conversion backend must be native, libmobi or calibre');
  }
  if (!Number.isInteger(timeout) || timeout < 200 || timeout > 45000) {
    throw new Error('Calibre timeout must be 200..45000 milliseconds');
  }
  const text = (value: unknown, field: string, limit = 4096): string | undefined => {
    if (value === undefined) return undefined;
    if (typeof value !== 'string' || !value.trim() || Buffer.byteLength(value) > limit) throw new Error(`invalid ${field} override`);
    return value;
  };
  const language = text(options.language, 'language', 128);
  if (language !== undefined && !/^[A-Za-z]{2,8}(?:-[A-Za-z0-9]{1,8})*$/.test(language)) throw new Error('invalid language override');
  const cover = options.cover;
  if (cover !== undefined && (typeof cover !== 'string' || !cover || cover.includes('\0'))) throw new Error('invalid cover path');
  return {
    backend, timeout,
    ...(text(options.title, 'title') === undefined ? {} : { title: text(options.title, 'title')! }),
    ...(text(options.author, 'author') === undefined ? {} : { author: text(options.author, 'author')! }),
    ...(language === undefined ? {} : { language }),
    ...(cover === undefined ? {} : { cover }),
  };
}
