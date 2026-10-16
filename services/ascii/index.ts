import { configuredBinary, processStatus, renderWithProcess } from './backends/process';
import { loadNativeAscii, nativeStatus, renderWithNative } from './backends/native';
import { renderWithTypescript } from './backends/typescript';
import { failure } from './limits';
import { imagePath, normalizeOptions } from './options';
import type { AsciiBackend, AsciiBackendStatus, AsciiGridOptions, AsciiRender } from './types';

export type { AsciiBackend, AsciiBackendStatus, AsciiOptions, AsciiRender } from './types';
export { DEFAULT_RAMP } from './options';
export { FAILURE_PREFIX, failure } from './limits';
export { nativeCandidates, platformSuffixes } from './backends/native';

/** The addon option shape (background is a colour name on the JS boundary). */
export function addonOptions(options: AsciiGridOptions): Record<string, unknown> {
  return {
    width: options.width,
    ...(options.height === undefined ? {} : { height: options.height }),
    invert: options.invert,
    ramp: options.ramp,
    background: options.background === 0 ? 'black' : 'white',
  };
}

/** Converts an image to ASCII using the best available backend.
 *
 * Selection order is explicit and deterministic: a configured external binary,
 * then the napi-rs addon, then the built-in TypeScript renderer. A backend that
 * merely fails (bad image, invalid options) is never retried elsewhere, so
 * errors are reported once instead of being masked by a second attempt. */
export async function imageToAscii(path: unknown, options?: unknown): Promise<AsciiRender> {
  const file = imagePath(path);
  const grid = normalizeOptions(options);
  try {
    const binary = configuredBinary();
    if (binary) return await renderWithProcess(binary, file, grid);
    const native = loadNativeAscii();
    if (native) return renderWithNative(native.addon, file, addonOptions(grid));
    return renderWithTypescript(file, grid);
  } catch (error) {
    // One prefix for process, addon and built-in decoders alike.
    throw failure(error);
  }
}

/** Backend inventory for `:HikariDoctor` and the RPC `doctor` action. */
export function asciiBackends(): AsciiBackendStatus[] {
  const native = nativeStatus();
  const process = processStatus();
  return [
    { backend: 'process', ...process },
    { backend: 'native', available: native.available, detail: native.detail },
    { backend: 'typescript', available: true, detail: 'built-in PNG, Netpbm and BMP decoder; always available' },
  ];
}

/** Backend a call would use right now, without rendering anything. */
export function asciiBackend(): AsciiBackend {
  if (configuredBinary()) return 'process';
  return loadNativeAscii() ? 'native' : 'typescript';
}

/** Backwards-compatible helper: the configured external binary, if any. */
export function asciiBinary(): string | null {
  return configuredBinary();
}
