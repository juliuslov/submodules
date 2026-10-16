import { DECODE_ERROR } from '../limits';
import { checkedDimensions, emptyImage, setPixel } from './pixels';
import type { RgbaImage } from '../types';

/** Uncompressed Windows BMP decoder for the built-in TypeScript fallback.
 *
 * Follows the BITMAPINFOHEADER layout documented by Microsoft: 1/4/8-bit
 * palettised images, 24-bit BGR and 32-bit BGRA rows padded to four bytes,
 * bottom-up (positive height) and top-down (negative height) storage, plus the
 * BI_BITFIELDS masks used by 16/32-bit files. Run-length encoded (BI_RLE4/8)
 * and embedded-JPEG/PNG bitmaps are rejected instead of guessed at. */

export function isBmp(bytes: Uint8Array): boolean {
  return bytes.length > 14 && bytes[0] === 0x42 && bytes[1] === 0x4d;
}

const BIT_COUNTS = new Set([1, 4, 8, 24, 32]);

/** Reads one channel out of a masked 16/32-bit pixel, scaled to 0..255. */
function masked(value: number, mask: number): number {
  if (!mask) return 0;
  const bits = Math.round(Math.log2(mask + 1));
  const low = Math.round(Math.log2((mask & -mask) >>> 0));
  const raw = ((value & mask) >>> low) >>> 0;
  return bits >= 8 ? (raw >>> (bits - 8)) & 0xff : Math.round((raw * 255) / ((1 << bits) - 1));
}

export function decodeBmp(bytes: Uint8Array): RgbaImage {
  const header = Buffer.from(bytes.buffer, bytes.byteOffset, bytes.length);
  if (header.length < 26) throw new Error(DECODE_ERROR);
  const pixelOffset = header.readUInt32LE(10);
  const headerSize = header.readUInt32LE(14);
  if (headerSize < 40 || headerSize > 124 || 14 + headerSize > header.length) throw new Error(DECODE_ERROR);
  const width = header.readInt32LE(18);
  let height = header.readInt32LE(22);
  const planes = header.readUInt16LE(26);
  const bitCount = header.readUInt16LE(28);
  const compression = header.readUInt32LE(30);
  if (planes !== 1 || !BIT_COUNTS.has(bitCount)) throw new Error(DECODE_ERROR);
  if (compression !== 0 && !(compression === 3 && bitCount >= 16)) throw new Error(DECODE_ERROR);
  const topDown = height < 0;
  height = Math.abs(height);
  checkedDimensions(width, height);
  const stride = ((width * bitCount + 31) >> 5) << 2;
  if (pixelOffset < 14 + headerSize || pixelOffset + stride * height > header.length) throw new Error(DECODE_ERROR);

  let redMask = 0x00ff0000, greenMask = 0x0000ff00, blueMask = 0x000000ff, alphaMask = 0;
  if (bitCount === 32) alphaMask = 0xff000000;
  if (compression === 3) {
    const masks = headerSize >= 52 ? 14 + 40 : 14 + headerSize;
    if (masks + 12 > header.length) throw new Error(DECODE_ERROR);
    redMask = header.readUInt32LE(masks);
    greenMask = header.readUInt32LE(masks + 4);
    blueMask = header.readUInt32LE(masks + 8);
    alphaMask = bitCount === 32 && headerSize >= 56 ? header.readUInt32LE(masks + 12) : 0;
    if (!redMask || !greenMask || !blueMask) throw new Error(DECODE_ERROR);
  }
  /** stb_image treats a fully transparent 32-bit bitmap as opaque. */
  let opaque = false;
  if (bitCount === 32 && alphaMask) {
    opaque = true;
    for (let at = pixelOffset + 3; at < pixelOffset + stride * height && opaque; at += 4) if (header[at]) opaque = false;
  }

  const palette: number[] = [];
  if (bitCount <= 8) {
    const declared = header.readUInt32LE(46);
    const count = declared || (1 << bitCount);
    if (count > 256 || 14 + headerSize + count * 4 > header.length) throw new Error(DECODE_ERROR);
    for (let index = 0; index < count; index += 1) {
      const at = 14 + headerSize + index * 4;
      // The reserved byte carries alpha for palettised bitmaps written by
      // modern tools; zero means "unused", which readers treat as opaque.
      palette.push(header[at + 2], header[at + 1], header[at], header[at + 3] || 255);
    }
  }

  const image = emptyImage(width, height);
  for (let row = 0; row < height; row += 1) {
    const source = pixelOffset + (topDown ? row : height - 1 - row) * stride;
    for (let column = 0; column < width; column += 1) {
      if (bitCount <= 8) {
        const perByte = 8 / bitCount;
        const byte = header[source + Math.floor(column / perByte)];
        const index = (byte >> (8 - bitCount * ((column % perByte) + 1))) & ((1 << bitCount) - 1);
        if (index * 4 + 3 >= palette.length) throw new Error(DECODE_ERROR);
        setPixel(image, column, row, palette[index * 4], palette[index * 4 + 1], palette[index * 4 + 2], palette[index * 4 + 3]);
      } else if (bitCount === 24) {
        const at = source + column * 3;
        setPixel(image, column, row, header[at + 2], header[at + 1], header[at]);
      } else {
        const value = bitCount === 32 ? header.readUInt32LE(source + column * 4) : header.readUInt16LE(source + column * 2);
        setPixel(image, column, row, masked(value, redMask), masked(value, greenMask), masked(value, blueMask),
          opaque || !alphaMask ? 255 : masked(value, alphaMask) || 255);
      }
    }
  }
  return image;
}
