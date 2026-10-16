import { readImageFile } from '../io';
import { renderBytes } from '../render';
import type { AsciiGridOptions, AsciiRender } from '../types';

/** Built-in backend: bounded file read, magic-byte decode, area-sampled render.
 *
 * It has no native toolchain requirement, which keeps image-to-ASCII working on
 * a fresh checkout, on platforms without a prebuilt addon, and inside Termux or
 * other environments where building Rust is impractical. Formats the small
 * built-in decoders do not implement (for example JPEG) report the shared
 * decode error instead of a vague failure. */
export function renderWithTypescript(path: string, options: AsciiGridOptions): AsciiRender {
  return renderBytes(readImageFile(path), options);
}
