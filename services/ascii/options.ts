import { MAX_COLUMNS, MAX_ROWS, RAMP_RANGE } from './limits';
import type { AsciiGridOptions, AsciiOptions } from './types';

/** Default ramp: darkest character first. */
export const DEFAULT_RAMP = '@%#*+=-:. ';

export function imagePath(value: unknown): string {
  if (typeof value !== 'string' || !value || value.includes('\0')) throw new Error('image path is required');
  return value;
}

/** Validates caller options and fills defaults.
 *
 * Unknown keys are ignored, matching the documented JSON protocol ("extra
 * fields are ignored"). Invalid values always throw instead of being coerced. */
export function normalizeOptions(options: unknown): AsciiGridOptions {
  if (options === undefined || options === null) options = {};
  if (typeof options !== 'object' || Array.isArray(options)) throw new Error('ASCII options must be an object');
  const input = options as AsciiOptions;
  const width = input.width === undefined ? 80 : input.width;
  if (!Number.isInteger(width) || (width as number) < 1 || (width as number) > MAX_COLUMNS) throw new Error('invalid ASCII width');
  const height = input.height;
  if (height !== undefined && (!Number.isInteger(height) || height < 1 || height > MAX_ROWS)) throw new Error('invalid ASCII height');
  if (input.invert !== undefined && typeof input.invert !== 'boolean') throw new Error('invert must be boolean');
  const ramp = input.ramp === undefined ? DEFAULT_RAMP : input.ramp;
  if (typeof ramp !== 'string' || !RAMP_RANGE.test(ramp)) throw new Error('invalid ASCII ramp');
  const background = input.background === undefined ? 'white' : input.background;
  if (background !== 'white' && background !== 'black') throw new Error('invalid ASCII background');
  return {
    width: width as number,
    ...(height === undefined ? {} : { height }),
    invert: input.invert === true,
    ramp,
    background: background === 'black' ? 0 : 255,
  };
}
