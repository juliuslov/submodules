/** Public ASCII service types shared by every backend. */

export type AsciiBackground = 'white' | 'black';

/** Caller-supplied options. Every field is optional; defaults match the
 * historical `:HikariAscii` behaviour (80 columns, white background). */
export interface AsciiOptions {
  width?: number;
  height?: number;
  invert?: boolean;
  ramp?: string;
  background?: AsciiBackground;
}

/** Decoded result. `columns`/`rows` describe the exact emitted grid. */
export interface AsciiRender {
  text: string;
  columns: number;
  rows: number;
}

/** Validated options: absent height means "derive it from the aspect ratio". */
export interface AsciiGridOptions {
  width: number;
  height?: number;
  invert: boolean;
  ramp: string;
  /** 255 = white paper, 0 = black paper. */
  background: 0 | 255;
}

export type AsciiBackend = 'process' | 'native' | 'typescript';

export interface AsciiBackendStatus {
  backend: AsciiBackend;
  available: boolean;
  detail: string;
}

/** 8-bit RGBA pixels, top-left origin, 4 bytes per pixel. */
export interface RgbaImage {
  width: number;
  height: number;
  rgba: Uint8Array;
}
