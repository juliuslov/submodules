import type { ConversionOptions } from './types';

/** Conversion backend. `native` is the default and never falls back silently. */
export type Backend = 'native' | 'libmobi' | 'calibre';

export interface Settings {
  backend: Backend;
  timeout: number;
}

/** Validates conversion options; unknown keys are rejected as typos. */
export function settings(options: ConversionOptions): Settings {
  if (!options || typeof options !== 'object' || Array.isArray(options) ||
      Object.keys(options).some(key => !['backend', 'timeoutMs'].includes(key))) {
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
  return { backend, timeout };
}
