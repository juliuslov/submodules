import { inflateSync } from 'node:zlib';
import { DECODE_ERROR } from '../limits';
import { checkedDimensions, emptyImage, setPixel, toEightBit } from './pixels';
import type { RgbaImage } from '../types';

/** PNG decoder for the built-in TypeScript fallback.
 *
 * Implements the parts of the W3C PNG specification (second edition, 2003)
 * that stb_image also decodes: colour types 0/2/3/4/6, bit depths 1/2/4/8/16,
 * all five filter types, non-interlaced and Adam7-interlaced images, `tRNS`
 * transparency, and mandatory chunk CRCs. APNG and other ancillary animation
 * chunks are ignored as the specification requires.
 *
 * Decompression goes through `node:zlib` with `maxOutputLength` pinned to the
 * exact filtered size, so a decompression bomb is rejected instead of
 * allocated. Anything malformed raises the shared decode error. */

const SIGNATURE = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];
const CHANNELS: Record<number, number> = { 0: 1, 2: 3, 3: 1, 4: 2, 6: 4 };
/** Adam7 starting column/row and column/row step per pass. */
const START = [[0, 0], [4, 0], [0, 4], [2, 0], [0, 2], [1, 0], [0, 1]];
const STEP = [[8, 8], [8, 8], [4, 8], [4, 4], [2, 4], [2, 2], [1, 2]];

let table: Uint32Array | undefined;

function crc32(bytes: Uint8Array, start: number, end: number): number {
  if (!table) {
    table = new Uint32Array(256);
    for (let i = 0; i < 256; i += 1) {
      let value = i;
      for (let bit = 0; bit < 8; bit += 1) value = value & 1 ? 0xedb88320 ^ (value >>> 1) : value >>> 1;
      table[i] = value >>> 0;
    }
  }
  let crc = 0xffffffff;
  for (let at = start; at < end; at += 1) crc = table[(crc ^ bytes[at]) & 0xff] ^ (crc >>> 8);
  return (crc ^ 0xffffffff) >>> 0;
}

export function isPng(bytes: Uint8Array): boolean {
  return bytes.length >= SIGNATURE.length && SIGNATURE.every((byte, at) => bytes[at] === byte);
}

interface Header {
  width: number; height: number; depth: number; color: number; interlace: number;
}

function paeth(left: number, up: number, upLeft: number): number {
  const estimate = left + up - upLeft;
  const toLeft = Math.abs(estimate - left);
  const toUp = Math.abs(estimate - up);
  const toUpLeft = Math.abs(estimate - upLeft);
  if (toLeft <= toUp && toLeft <= toUpLeft) return left;
  return toUp <= toUpLeft ? up : upLeft;
}

/** Reverses the per-scanline filter, returning the filtered rows. */
function unfilter(inflated: Uint8Array, height: number, lineBytes: number, bpp: number): Uint8Array[] {
  const rows: Uint8Array[] = [];
  let previous = new Uint8Array(lineBytes);
  let at = 0;
  for (let row = 0; row < height; row += 1) {
    if (at + 1 + lineBytes > inflated.length) throw new Error(DECODE_ERROR);
    const filter = inflated[at];
    at += 1;
    const line = inflated.slice(at, at + lineBytes);
    at += lineBytes;
    for (let i = 0; i < lineBytes; i += 1) {
      const left = i >= bpp ? line[i - bpp] : 0;
      const up = previous[i];
      const upLeft = i >= bpp ? previous[i - bpp] : 0;
      if (filter === 0) continue;
      else if (filter === 1) line[i] = (line[i] + left) & 0xff;
      else if (filter === 2) line[i] = (line[i] + up) & 0xff;
      else if (filter === 3) line[i] = (line[i] + ((left + up) >> 1)) & 0xff;
      else if (filter === 4) line[i] = (line[i] + paeth(left, up, upLeft)) & 0xff;
      else throw new Error(DECODE_ERROR);
    }
    rows.push(line);
    previous = line;
  }
  return rows;
}

function passGeometry(width: number, height: number, pass: number): { width: number; height: number; startX: number; startY: number; stepX: number; stepY: number } {
  const [startX, startY] = START[pass];
  const [stepX, stepY] = STEP[pass];
  return {
    startX, startY, stepX, stepY,
    width: Math.max(0, Math.ceil((width - startX) / stepX)),
    height: Math.max(0, Math.ceil((height - startY) / stepY)),
  };
}

/** Raw sample values of one filtered row (big-endian, packed bit depths). */
function samplesOf(line: Uint8Array, count: number, depth: number): number[] {
  const values = new Array<number>(count);
  if (depth === 16) {
    for (let i = 0; i < count; i += 1) values[i] = (line[i * 2] << 8) | line[i * 2 + 1];
  } else if (depth === 8) {
    for (let i = 0; i < count; i += 1) values[i] = line[i];
  } else {
    const perByte = 8 / depth;
    const mask = (1 << depth) - 1;
    for (let i = 0; i < count; i += 1) {
      const byte = line[Math.floor(i / perByte)];
      const shift = 8 - depth * ((i % perByte) + 1);
      values[i] = (byte >> shift) & mask;
    }
  }
  return values;
}

interface Transparency {
  palette?: Uint8Array;
  gray?: number;
  red?: number;
  green?: number;
  blue?: number;
}

export function decodePng(bytes: Uint8Array): RgbaImage {
  let header: Header | undefined;
  let palette: Uint8Array | undefined;
  const transparency: Transparency = {};
  const idat: Uint8Array[] = [];
  let sawEnd = false;
  let at = SIGNATURE.length;
  while (at + 8 <= bytes.length) {
    const length = (bytes[at] << 24 | bytes[at + 1] << 16 | bytes[at + 2] << 8 | bytes[at + 3]) >>> 0;
    if (length > bytes.length || at + 12 + length > bytes.length) throw new Error(DECODE_ERROR);
    const type = String.fromCharCode(bytes[at + 4], bytes[at + 5], bytes[at + 6], bytes[at + 7]);
    const body = bytes.subarray(at + 8, at + 8 + length);
    const expected = (bytes[at + 8 + length] << 24 | bytes[at + 9 + length] << 16 | bytes[at + 10 + length] << 8 | bytes[at + 11 + length]) >>> 0;
    if (crc32(bytes, at + 4, at + 8 + length) !== expected) throw new Error(DECODE_ERROR);
    if (type === 'IHDR') {
      if (header || length !== 13) throw new Error(DECODE_ERROR);
      const width = (body[0] << 24 | body[1] << 16 | body[2] << 8 | body[3]) >>> 0;
      const height = (body[4] << 24 | body[5] << 16 | body[6] << 8 | body[7]) >>> 0;
      checkedDimensions(width, height);
      const depth = body[8];
      const color = body[9];
      if (body[10] !== 0 || body[11] !== 0 || body[12] > 1) throw new Error(DECODE_ERROR);
      const channels = CHANNELS[color];
      if (!channels) throw new Error(DECODE_ERROR);
      const valid = depth === 8 || depth === 16 ||
        (depth === 1 && (color === 0 || color === 3)) ||
        (depth === 2 && (color === 0 || color === 3)) ||
        (depth === 4 && (color === 0 || color === 3));
      if (!valid) throw new Error(DECODE_ERROR);
      header = { width, height, depth, color, interlace: body[12] };
    } else if (type === 'PLTE') {
      if (!length || length % 3 !== 0 || length > 256 * 3) throw new Error(DECODE_ERROR);
      palette = Uint8Array.from(body);
    } else if (type === 'tRNS') {
      if (!header) throw new Error(DECODE_ERROR);
      if (header.color === 3) transparency.palette = Uint8Array.from(body);
      else if (header.color === 0 && length === 2) transparency.gray = (body[0] << 8) | body[1];
      else if (header.color === 2 && length === 6) {
        transparency.red = (body[0] << 8) | body[1];
        transparency.green = (body[2] << 8) | body[3];
        transparency.blue = (body[4] << 8) | body[5];
      } else throw new Error(DECODE_ERROR);
    } else if (type === 'IDAT') {
      if (!header) throw new Error(DECODE_ERROR);
      if (length) idat.push(Uint8Array.from(body));
    } else if (type === 'IEND') {
      sawEnd = true;
      break;
    } else if (type.charCodeAt(0) >= 65 && type.charCodeAt(0) <= 90) {
      throw new Error(DECODE_ERROR); // Unknown critical chunk.
    }
    at += 12 + length;
  }
  if (!header || !sawEnd || !idat.reduce((total, part) => total + part.length, 0)) throw new Error(DECODE_ERROR);
  if (header.color === 3 && (!palette || palette.length / 3 > 256)) throw new Error(DECODE_ERROR);

  const channels = CHANNELS[header.color];
  const full = { startX: 0, startY: 0, stepX: 1, stepY: 1, width: header.width, height: header.height };
  const geometry = header.interlace === 1
    ? Array.from({ length: 7 }, (_, pass) => passGeometry(header!.width, header!.height, pass))
    : [full];
  const passes = geometry.length;
  const lineBytes = geometry.map(part => Math.ceil((part.width * channels * header!.depth) / 8));
  const expected = geometry.reduce((total, part, pass) => total + (part.width && part.height ? part.height * (1 + lineBytes[pass]) : 0), 0);
  if (!expected) throw new Error(DECODE_ERROR);
  const compressed = Buffer.concat(idat.map(part => Buffer.from(part)));
  let inflated: Buffer;
  try {
    inflated = inflateSync(compressed, { maxOutputLength: expected });
  } catch {
    throw new Error(DECODE_ERROR);
  }
  if (inflated.length !== expected) throw new Error(DECODE_ERROR);

  const image = emptyImage(header.width, header.height);
  let cursor = 0;
  for (let pass = 0; pass < passes; pass += 1) {
    const part = geometry[pass];
    if (!part.width || !part.height) continue;
    const bytesPerPixel = Math.max(1, (channels * header.depth) / 8);
    const rows = unfilter(inflated.subarray(cursor, cursor + part.height * (1 + lineBytes[pass])), part.height, lineBytes[pass], bytesPerPixel);
    cursor += part.height * (1 + lineBytes[pass]);
    for (let row = 0; row < part.height; row += 1) {
      const values = samplesOf(rows[row], part.width * channels, header.depth);
      for (let column = 0; column < part.width; column += 1) {
        const sample = column * channels;
        let red = 0, green = 0, blue = 0, alpha = 255;
        if (header.color === 0) {
          const gray = toEightBit(values[sample], header.depth);
          red = green = blue = gray;
          if (transparency.gray !== undefined && values[sample] === transparency.gray) alpha = 0;
        } else if (header.color === 2) {
          red = toEightBit(values[sample], header.depth);
          green = toEightBit(values[sample + 1], header.depth);
          blue = toEightBit(values[sample + 2], header.depth);
          if (transparency.red !== undefined && values[sample] === transparency.red &&
              values[sample + 1] === transparency.green && values[sample + 2] === transparency.blue) alpha = 0;
        } else if (header.color === 3) {
          const index = values[sample];
          if (index * 3 + 2 >= palette!.length) throw new Error(DECODE_ERROR);
          red = palette![index * 3];
          green = palette![index * 3 + 1];
          blue = palette![index * 3 + 2];
          if (transparency.palette && index < transparency.palette.length) alpha = transparency.palette[index];
        } else if (header.color === 4) {
          const gray = toEightBit(values[sample], header.depth);
          red = green = blue = gray;
          alpha = toEightBit(values[sample + 1], header.depth);
        } else {
          red = toEightBit(values[sample], header.depth);
          green = toEightBit(values[sample + 1], header.depth);
          blue = toEightBit(values[sample + 2], header.depth);
          alpha = toEightBit(values[sample + 3], header.depth);
        }
        setPixel(image, part.startX + column * part.stepX, part.startY + row * part.stepY, red, green, blue, alpha);
      }
    }
  }
  return image;
}
