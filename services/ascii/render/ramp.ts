import { RAMP_RANGE } from '../limits';
import type { AsciiGridOptions, AsciiRender, RgbaImage } from '../types';
import { cellBrightness, gridFor } from './sample';

/** Maps a 0..255 brightness onto a ramp index; 0 is the darkest character. */
export function rampIndex(brightness: number, ramp: string, invert: boolean): number {
  const last = ramp.length - 1;
  const index = Math.min(last, Math.max(0, Math.round((brightness / 255) * last)));
  return invert ? last - index : index;
}

/** Renders a decoded image into a character grid.
 *
 * The result is plain ASCII: one newline after every row, no trailing padding
 * beyond the requested columns, and no terminal escape sequences. */
export function renderImage(image: RgbaImage, options: AsciiGridOptions): AsciiRender {
  if (!RAMP_RANGE.test(options.ramp)) throw new Error('invalid ASCII ramp');
  const { width, height } = gridFor(image, options);
  const rows: string[] = [];
  for (let row = 0; row < height; row += 1) {
    const y0 = (row * image.height) / height;
    const y1 = ((row + 1) * image.height) / height;
    let line = '';
    for (let column = 0; column < width; column += 1) {
      const x0 = (column * image.width) / width;
      const x1 = ((column + 1) * image.width) / width;
      line += options.ramp[rampIndex(cellBrightness(image, options, x0, x1, y0, y1), options.ramp, options.invert)];
    }
    rows.push(line);
  }
  return { text: `${rows.join('\n')}\n`, columns: width, rows: height };
}
