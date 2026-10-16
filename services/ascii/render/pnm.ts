import { DECODE_ERROR } from '../limits';
import { checkedDimensions, emptyImage, setPixel } from './pixels';
import type { RgbaImage } from '../types';

/** Netpbm decoder for the built-in TypeScript fallback.
 *
 * Covers the ASCII formats (P1 bitmap, P2 graymap, P3 pixmap) and the binary
 * ones (P4/P5/P6) as described by the netpbm manual: whitespace- or
 * comment-separated header fields, one mandatory whitespace byte before a
 * binary payload, color samples up to 65535 stored big-endian, and per the
 * specification a bitmap value of 1 meaning black and 0 meaning white. Rows of
 * a P4 bitmap are padded to a whole byte. */

export function isPnm(bytes: Uint8Array): boolean {
  return bytes.length > 1 && bytes[0] === 0x50 && bytes[1] >= 0x31 && bytes[1] <= 0x36;
}

const WHITESPACE = /\s/;

class Cursor {
  at = 0;

  constructor(readonly bytes: Uint8Array, start = 0) { this.at = start; }

  /** Skips whitespace and `#` comments, as the netpbm readers do. */
  skip(): void {
    for (;;) {
      while (this.at < this.bytes.length && WHITESPACE.test(String.fromCharCode(this.bytes[this.at]))) this.at += 1;
      if (this.bytes[this.at] !== 0x23) return;
      while (this.at < this.bytes.length && this.bytes[this.at] !== 0x0a) this.at += 1;
    }
  }

  token(): string {
    this.skip();
    const start = this.at;
    while (this.at < this.bytes.length && !WHITESPACE.test(String.fromCharCode(this.bytes[this.at]))) this.at += 1;
    if (start === this.at) throw new Error(DECODE_ERROR);
    return Buffer.from(this.bytes.subarray(start, this.at)).toString('latin1');
  }

  integer(maximum: number): number {
    const value = Number(this.token());
    if (!Number.isInteger(value) || value < 1 || value > maximum) throw new Error(DECODE_ERROR);
    return value;
  }

  /** Consumes the single whitespace byte that separates header from payload. */
  binary(): void {
    if (this.at >= this.bytes.length || !WHITESPACE.test(String.fromCharCode(this.bytes[this.at]))) throw new Error(DECODE_ERROR);
    this.at += 1;
  }
}

export function decodePnm(bytes: Uint8Array): RgbaImage {
  const magic = String.fromCharCode(bytes[0], bytes[1]);
  const cursor = new Cursor(bytes, 2);
  const width = cursor.integer(8192);
  const height = cursor.integer(8192);
  checkedDimensions(width, height);
  const ascii = magic === 'P1' || magic === 'P2' || magic === 'P3';
  const bitmap = magic === 'P1' || magic === 'P4';
  const channels = magic === 'P3' || magic === 'P6' ? 3 : 1;
  const maximum = bitmap ? 1 : cursor.integer(65535);
  const wide = !ascii && maximum > 255;
  const stride = bitmap ? Math.ceil(width / 8) : width * channels * (wide ? 2 : 1);
  if (!ascii) {
    cursor.binary();
    if (cursor.at + stride * height > bytes.length) throw new Error(DECODE_ERROR);
  }
  const image = emptyImage(width, height);
  /** Every sample is scaled to the 0..255 range the renderer expects. */
  const scaled = (value: number): number => Math.round((value * 255) / maximum);

  for (let row = 0; row < height; row += 1) {
    const values = new Array<number>(width * channels);
    if (ascii) {
      for (let i = 0; i < values.length; i += 1) values[i] = cursor.integer(bitmap ? 1 : maximum);
    } else {
      const base = cursor.at;
      for (let i = 0; i < values.length; i += 1) {
        if (bitmap) {
          const bit = width - 1 - i;
          values[i] = (bytes[base + (bit >> 3)] >> (bit % 8)) & 1;
        } else if (wide) values[i] = (bytes[base + i * 2] << 8) | bytes[base + i * 2 + 1];
        else values[i] = bytes[base + i];
      }
      cursor.at = base + stride;
    }
    for (let column = 0; column < width; column += 1) {
      const sample = column * channels;
      if (bitmap) {
        const value = values[sample] ? 0 : 255; // 1 is black, 0 is white.
        setPixel(image, column, row, value, value, value);
      } else if (channels === 1) {
        const gray = scaled(values[sample]);
        setPixel(image, column, row, gray, gray, gray);
      } else setPixel(image, column, row, scaled(values[sample]), scaled(values[sample + 1]), scaled(values[sample + 2]));
    }
  }
  return image;
}
