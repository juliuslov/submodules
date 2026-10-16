/** Types for the vendored fflate gitlink (`vendor/fflate`, pin dcb3714).
 *
 * The upstream sources are TypeScript, but they are not written for
 * `strict: true` (`buf` is used after a possibly-undefined check, `null` is
 * assigned to optional `Uint16Array` fields, ...), so pointing service code at
 * `vendor/fflate/src/index.ts` would flood `npm run typecheck` with third-party
 * errors. This declaration therefore covers only the small API surface hikari
 * uses, and `scripts/build.mjs` maps the bare `fflate` specifier to the pinned
 * upstream sources, so the runtime code always comes from the submodule and
 * never from an npm substitute.
 *
 * Keep this file in sync when a service starts using another fflate function. */
declare module 'fflate' {
  export interface ZipOptions {
    level?: 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9;
    mem?: number;
    dictionary?: Uint8Array;
    filename?: string;
    mtime?: Date | string | number;
    size?: number;
    crc?: number;
  }
  export interface UnzipOptions {
    filter?: (file: { name: string; size: number; originalSize: number }) => boolean;
  }
  /** Map of archive path to bytes, optionally with per-file options. */
  export interface Zippable {
    [path: string]: Uint8Array | [Uint8Array, ZipOptions] | Zippable;
  }
  export interface Unzipped {
    [path: string]: Uint8Array;
  }
  export function zipSync(data: Zippable, opts?: ZipOptions): Uint8Array;
  export function unzipSync(data: Uint8Array, opts?: UnzipOptions): Unzipped;
  export function strToU8(text: string): Uint8Array;
  export function strFromU8(data: Uint8Array, latin1?: boolean): string;
}
