import { compositedLuminance } from './luminance';
import type { AsciiGridOptions, RgbaImage } from '../types';

/** Output grid geometry for one image.
 *
 * When no height is requested the rows are derived from the source aspect
 * ratio with a 0.5 cell correction, because terminal cells are roughly twice
 * as tall as they are wide. Overlong results are clamped to the supported row
 * ceiling by shrinking the column count instead of squashing the image. */
export function gridFor(image: RgbaImage, options: AsciiGridOptions): { width: number; height: number } {
  if (options.height !== undefined) return { width: options.width, height: options.height };
  let width = options.width;
  const natural = (width * image.height) / image.width * 0.5;
  if (natural > 200) width = Math.max(1, Math.floor((200 * 2 * image.width) / image.height));
  const height = Math.round((width * image.height) / image.width * 0.5);
  return { width, height: Math.min(200, Math.max(1, height)) };
}

/** Area-weighted mean brightness of one output cell.
 *
 * Every source pixel is weighted by the fraction of its area that overlaps the
 * cell, which is what makes downscaling look like an average rather than a
 * nearest-neighbour sample. Neighbouring cells can therefore share pixels. */
export function cellBrightness(image: RgbaImage, options: AsciiGridOptions, x0: number, x1: number, y0: number, y1: number): number {
  let weighted = 0;
  let area = 0;
  for (let y = Math.floor(y0); y < Math.min(Math.ceil(y1), image.height); y += 1) {
    const vertical = Math.min(y1, y + 1) - Math.max(y0, y);
    if (vertical <= 0) continue;
    for (let x = Math.floor(x0); x < Math.min(Math.ceil(x1), image.width); x += 1) {
      const weight = (Math.min(x1, x + 1) - Math.max(x0, x)) * vertical;
      if (weight <= 0) continue;
      const at = (y * image.width + x) * 4;
      weighted += compositedLuminance(image.rgba[at], image.rgba[at + 1], image.rgba[at + 2], image.rgba[at + 3], options.background) * weight;
      area += weight;
    }
  }
  if (area <= 0) return options.background;
  return weighted / area;
}
