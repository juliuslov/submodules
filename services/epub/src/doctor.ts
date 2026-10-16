import { calibreBinary } from '../../mobi/calibre';
import { mobiBinary, pythonBinary, textSourceFormats, vendorStatus } from '../../mobi';
import { asciiBackend, asciiBackends } from '../../ascii';
import { execFileSync } from 'node:child_process';
import { existsSync } from 'node:fs';
import { join } from 'node:path';
import { archiveBinary, ROOT } from './archive';
export function doctor(): object {
  let archive: { available: boolean; version?: string; error?: string };
  try { archive = { available: true, version: execFileSync(archiveBinary(), ['--version'], { encoding: 'utf8', timeout: 5000 }).trim() }; }
  catch (err) { archive = { available: false, error: (err as Error).message }; }
  // Image-to-ASCII always reports available: the built-in TypeScript renderer
  // needs no native toolchain. The backend list explains which one runs.
  const asciiNative = asciiBackends().find(entry => entry.backend === 'native')!;
  const ascii = { available: true, backend: asciiBackend(),
    native: { available: asciiNative.available, detail: asciiNative.detail },
    backends: asciiBackends() };
  let mobiNative: { available: boolean; version?: string; error?: string };
  let python: { available: boolean; version?: string; error?: string };
  try { mobiNative = { available: true, version: execFileSync(mobiBinary(), ['--version'], { encoding: 'utf8', timeout: 5000, maxBuffer: 4096 }).trim() }; }
  catch { mobiNative = { available: false, error: 'run make mobi (in-repository vendor/libmobi); WIZ_MOBI may override the binary' }; }
  try { python = { available: true, version: execFileSync(pythonBinary(), ['-c', 'import sys; assert sys.version_info >= (3, 8); print(sys.version.split()[0])'], { encoding: 'utf8', timeout: 5000, maxBuffer: 4096 }).trim() }; }
  catch { python = { available: false, error: 'install Python >= 3.8 or set WIZ_PYTHON' }; }
  const kindleunpack = existsSync(join(ROOT, 'vendor/kindleunpack/lib/mobi_header.py'));
  const mobi = { available: mobiNative.available && python.available && kindleunpack,
    native: mobiNative, python, textOnly: true, exportFormat: 'MOBI6',
    buildInInputs: textSourceFormats().filter(source => source.supported).map(source => source.label) };
  let capabilities: object | undefined;
  try { capabilities = JSON.parse(execFileSync(mobiBinary(), ['--capabilities'], { encoding: 'utf8', timeout: 5000, maxBuffer: 4096 })); }
  catch { /* Missing or older binary: diagnostics remain usable. */ }
  const libmobi = { available: Boolean(capabilities), capabilities,
    tools: { mobitool: existsSync(join(ROOT, 'build/mobitool')), mobimeta: existsSync(join(ROOT, 'build/mobimeta')) } };
  let calibre: { available: boolean; version?: string; error?: string };
  try { calibre = { available: true, version: execFileSync(calibreBinary(), ['--version'], { encoding: 'utf8', timeout: 5000, maxBuffer: 4096 }).trim() }; }
  catch { calibre = { available: false, error: 'optional: install Calibre ebook-convert or set HIKARI_CALIBRE; never downloaded automatically' }; }
  const kosync = { available: true, configured: Boolean(process.env.KOSYNC_USERNAME && (Boolean(process.env.KOSYNC_PASSWORD) !== Boolean(process.env.KOSYNC_USERKEY))), onlineCheck: false };
  // In-repository vendored components: no Git submodule can be missing, only a
  // partial copy of a vendor directory. Kept as `submodules` so existing Lua
  // diagnostics keep working.
  const vendors = vendorStatus().map(({ id, kind, location, license, available, requirement, capabilities }) =>
    ({ id, kind, location, license, available, requirement, capabilities }));
  return { plugin: 'hikari', libmobi, calibre, mobi, vendors, ascii, kosync, node: process.version, archive, submodules: {
    libmobi: existsSync(join(ROOT, 'vendor/libmobi/src/mobi.h')),
    kindleunpack,
    stb: existsSync(join(ROOT, 'vendor/stb/stb_image.h')),
    miniz: existsSync(join(ROOT, 'vendor/miniz/miniz.h')),
    fflate: existsSync(join(ROOT, 'vendor/fflate/src/index.ts')),
    dkjson: existsSync(join(ROOT, 'vendor/dkjson/dkjson.lua')),
  } };
}
