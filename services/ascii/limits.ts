/** Hard limits for the ASCII service.
 *
 * They are duplicated in the Rust addon (`services/ascii/native/src/limits.rs`)
 * on purpose: the TypeScript fallback must reject the same hostile inputs even
 * when no native addon was built. Keep both files in sync. */

/** Encoded input ceiling, checked before any decode allocation. */
export const MAX_INPUT_BYTES = 32 * 1024 * 1024;

/** Output grid ceilings (terminal cells, not pixels). */
export const MAX_COLUMNS = 400;
export const MAX_ROWS = 200;

/** Ramp must be 2..64 printable ASCII bytes, darkest first. */
export const MIN_RAMP_BYTES = 2;
export const MAX_RAMP_BYTES = 64;
export const RAMP_RANGE = /^[\x20-\x7e]{2,64}$/;

/** Decoded-image ceilings. */
export const MAX_DIMENSION = 8192;
export const MAX_PIXELS = 16 * 1024 * 1024;

/** Subprocess backend budget. */
export const PROCESS_TIMEOUT_MS = 15_000;
export const PROCESS_MAX_OUTPUT = 256 * 1024;

/** Environment variables for explicit backend selection. */
export const NATIVE_ENV = 'HIKARI_ASCII_NATIVE';
export const BINARY_ENV = ['HIKARI_ASCII', 'WIZ_ASCII'] as const;

/** One error contract for every backend, so callers can match a stable prefix. */
export const FAILURE_PREFIX = 'ASCII conversion failed: ';

/** Wraps a backend failure exactly once (options errors stay as they are). */
export function failure(error: unknown): Error {
  const message = error instanceof Error ? error.message : String(error);
  return new Error(message.startsWith(FAILURE_PREFIX) ? message : FAILURE_PREFIX + message);
}

export const DECODE_ERROR =
  'invalid, unsupported or oversized image (built-in TypeScript decoder supports PNG, Netpbm P1-P6 and uncompressed BMP; build the native addon for JPEG and other formats)';
