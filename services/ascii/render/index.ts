import { DECODE_ERROR } from '../limits';
import type { AsciiGridOptions, AsciiRender, RgbaImage } from '../types';
import { decodeBmp, isBmp } from './bmp';
import { decodePng, isPng } from './png';
import { decodePnm, isPnm } from './pnm';
import { renderImage } from './ramp';

/** Decodes one encoded image buffer, choosing the decoder by magic bytes
 * rather than by file extension. Unsupported or malformed data raises the
 * shared decode error so both backends fail identically. */
export function decodeImage(bytes: Uint8Array): RgbaImage {
  if (!bytes.length) throw new Error(DECODE_ERROR);
  if (isPng(bytes)) return decodePng(bytes);
  if (isPnm(bytes)) return decodePnm(bytes);
  if (isBmp(bytes)) return decodeBmp(bytes);
  throw new Error(DECODE_ERROR);
}

export function renderBytes(bytes: Uint8Array, options: AsciiGridOptions): AsciiRender {
  return renderImage(decodeImage(bytes), options);
}

export { renderImage } from './ramp';
export { gridFor } from './sample';
export type { RgbaImage } from '../types';
