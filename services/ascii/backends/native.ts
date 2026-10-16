import { existsSync, readdirSync } from 'node:fs';
import { createRequire } from 'node:module';
import { join } from 'node:path';
import { NATIVE_ENV } from '../limits';
import { ROOT } from '../../root';
import type { AsciiRender } from '../types';

/** Loader for the optional napi-rs native addon (`services/ascii/native`).
 *
 * The addon is what `napi build --platform --release --output-dir build`
 * produces, for example `build/hikari-ascii.linux-x64-gnu.node`. Resolution is
 * explicit and ordered: `HIKARI_ASCII_NATIVE`, then the exact target suffix,
 * then an unsuffixed name, then any `hikari-ascii.*.node` left in `build/`.
 * The first file that loads *and* exports `renderAscii` wins; anything else is
 * reported as a detail string so `:HikariDoctor` can explain a mix-up such as
 * an addon built for another architecture. */

export interface NativeAsciiAddon {
  renderAscii(path: string, options: Record<string, unknown>): AsciiRender;
  renderAsciiBytes?(data: Uint8Array, options: Record<string, unknown>): AsciiRender;
  nativeInfo?(): string;
}

export interface LoadedAddon {
  addon: NativeAsciiAddon;
  path: string;
}

const require = createRequire(import.meta.url);
const PREFIX = 'hikari-ascii';

/** napi-rs platform-arch-abi suffixes, most specific first.
 *
 * `build/<name>.<suffix>.node` follows the CLI's `--platform` naming
 * (`linux-x64-gnu`, `linux-arm64-musl`, `darwin-arm64`, `win32-x64-msvc`,
 * `android-arm64`, ...). Node reports Linux libc through the process report,
 * and reports `android` for Termux builds, so those two cases need no libc
 * guesswork. */
export function platformSuffixes(): string[] {
  const { platform, arch } = process;
  const suffixes = [`${platform}-${arch}`];
  if (platform === 'linux') {
    const glibc = (process.report?.getReport() as { header?: { glibcVersionRuntime?: string } } | undefined)?.header?.glibcVersionRuntime;
    const libc = glibc ? 'gnu' : 'musl';
    suffixes.unshift(`${platform}-${arch}-${libc}`);
    suffixes.push(`${platform}-${arch}-${libc === 'gnu' ? 'musl' : 'gnu'}`);
  }
  return suffixes;
}

export function nativeCandidates(): string[] {
  const configured = process.env[NATIVE_ENV];
  if (configured) return [configured];
  const candidates = platformSuffixes().map(suffix => join(ROOT, 'build', `${PREFIX}.${suffix}.node`));
  candidates.push(join(ROOT, 'build', `${PREFIX}.node`));
  try {
    for (const entry of readdirSync(join(ROOT, 'build')).sort()) {
      if (entry.startsWith(`${PREFIX}.`) && entry.endsWith('.node')) candidates.push(join(ROOT, 'build', entry));
    }
  } catch { /* build/ may not exist before the first build */ }
  return candidates;
}

let cached: LoadedAddon | null | undefined;
let detail = '';

/** Loads the addon once per process; `null` means "use the fallback". */
export function loadNativeAscii(): LoadedAddon | null {
  if (cached !== undefined) return cached;
  cached = null;
  for (const candidate of nativeCandidates()) {
    if (!existsSync(candidate)) continue;
    try {
      const addon = require(candidate) as NativeAsciiAddon;
      if (typeof addon?.renderAscii !== 'function') throw new Error('missing renderAscii export');
      cached = { addon, path: candidate };
      detail = candidate;
      break;
    } catch (error) {
      detail = `${candidate} could not be loaded: ${error instanceof Error ? error.message : String(error)}`;
    }
  }
  return cached;
}

export function nativeStatus(): { available: boolean; detail: string; version?: string } {
  const loaded = loadNativeAscii();
  if (!loaded) return { available: false, detail: detail || `no addon found; build it with make ascii (${NATIVE_ENV} overrides the path)` };
  let version: string | undefined;
  try {
    version = loaded.addon.nativeInfo?.();
  } catch { /* an older addon may not report a version */ }
  return { available: true, detail: loaded.path, ...(version ? { version } : {}) };
}

export function renderWithNative(addon: NativeAsciiAddon, path: string, options: Record<string, unknown>): AsciiRender {
  const result = addon.renderAscii(path, options);
  if (!result || typeof result.text !== 'string' || !Number.isInteger(result.columns) || !Number.isInteger(result.rows)) {
    throw new Error('native addon returned an invalid render result');
  }
  return result;
}
