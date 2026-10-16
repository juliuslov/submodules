import { DECODE_ERROR, MAX_DIMENSION, MAX_PIXELS } from '../limits';
import type { RgbaImage } from '../types';

/** Validates decoded geometry before any pixel buffer is allocated.
 *
 * Mirrors the native preflight (`stbi_info` + explicit bounds) so a crafted
 * header cannot make either backend allocate an unbounded image. */
export function checkedDimensions(width: unknown, height: unknown): void {
  if (!Number.isInteger(width) || !Number.isInteger(height) ||
      (width as number) < 1 || (height as number) < 1 ||
      (width as number) > MAX_DIMENSION || (height as number) > MAX_DIMENSION ||
      (width as number) * (height as number) > MAX_PIXELS) {
    throw new Error(DECODE_ERROR);
  }
}

export function emptyImage(width: number, height: number): RgbaImage {
  checkedDimensions(width, height);
  return { width, height, rgba: new Uint8Array(width * height * 4) };
}

/** Writes one RGBA pixel, ignoring coordinates outside the canvas. */
export function setPixel(image: RgbaImage, x: number, y: number, r: number, g: number, b: number, a = 255): void {
  if (x < 0 || y < 0 || x >= image.width || y >= image.height) return;
  const at = (y * image.width + x) * 4;
  image.rgba[at] = r & 0xff;
  image.rgba[at + 1] = g & 0xff;
  image.rgba[at + 2] = b & 0xff;
  image.rgba[at + 3] = a & 0xff;
}

/** Scales a raw sample of `depth` bits to 8 bits the way libpng/stb do. */
export function toEightBit(value: number, depth: number): number {
  if (depth === 8) return value & 0xff;
  if (depth === 16) return (value >> 8) & 0xff;
  const maximum = (1 << depth) - 1;
  return Math.round((value * 255) / maximum);
}
