import { existsSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { join } from 'node:path';
import { ROOT } from '../epub/src/archive';
import { calibreBinary } from './calibre';
import { mobiBinary, pythonBinary } from './runtime';

/** Registry of every engine the MOBI service can use.
 *
 * Each entry names the component, where it lives, which capability it provides
 * and whether it is usable right now. The point is that "vendor integrations"
 * are explicit and replaceable: an engine can be swapped (or removed) by
 * editing this table, and `doctor`/`formats` report exactly what is present.
 *
 * Every engine is either **in-repository source** (`vendor/…`, built by
 * `make`) or an **explicitly opt-in external executable**. Nothing is fetched
 * at build or run time. */

export type VendorKind = 'native' | 'python' | 'typescript' | 'external';

export interface VendorEngine {
  /** Stable id used by option values, diagnostics and tests. */
  id: 'writer' | 'libmobi' | 'kindleunpack' | 'text-sources' | 'calibre';
  kind: VendorKind;
  /** Repository-relative source path, or the executable name for externals. */
  location: string;
  license: string;
  /** Operations this engine can perform. */
  capabilities: string[];
  /** `source` engines are always built in; `built` ones need `make`/Rust. */
  requirement: 'in-tree' | 'built' | 'external';
}

export interface VendorStatus extends VendorEngine {
  available: boolean;
  detail: string;
  version?: string;
}

export const ENGINES: VendorEngine[] = [
  {
    id: 'text-sources',
    kind: 'typescript',
    location: 'services/mobi/source',
    license: 'UNLICENSED (original code)',
    capabilities: ['txt', 'markdown', 'html', 'xhtml', 'fb2', 'rtf', 'epub-input'],
    requirement: 'in-tree',
  },
  {
    id: 'writer',
    kind: 'typescript',
    location: 'services/mobi/writer',
    license: 'UNLICENSED (original code)',
    capabilities: ['mobi6-output', 'epub-output', 'exth-metadata', 'cover-records', 'palmdoc-text-records'],
    requirement: 'in-tree',
  },
  {
    id: 'libmobi',
    kind: 'native',
    location: 'vendor/libmobi',
    license: 'LGPL-3.0+',
    capabilities: ['mobi-inspect', 'mobi-decode', 'kf8-reconstruction', 'huffcdic', 'epub-source-generation', 'metadata-editing'],
    requirement: 'built',
  },
  {
    id: 'kindleunpack',
    kind: 'python',
    location: 'vendor/kindleunpack/lib',
    license: 'GPL-3.0',
    capabilities: ['independent-mobi-decode', 'kf8-text-extraction', 'cover-extraction'],
    requirement: 'built',
  },
  {
    id: 'calibre',
    kind: 'external',
    location: calibreBinary(),
    license: 'GPL-3.0 (external program, not bundled)',
    capabilities: ['azw3-output', 'kf8-output', 'mobi-input', 'epub-input'],
    requirement: 'external',
  },
];

/** Repository-relative display path: diagnostics must not leak absolute ones. */
function display(target: string): string {
  const prefix = ROOT.endsWith('/') ? ROOT : `${ROOT}/`;
  return target.startsWith(prefix) ? target.slice(prefix.length) : target;
}

function probe(command: string, args: string[]): string | null {
  try {
    return execFileSync(command, args, { encoding: 'utf8', timeout: 10000, maxBuffer: 65536 }).trim();
  } catch { return null; }
}

function status(engine: VendorEngine): VendorStatus {
  if (engine.id === 'kindleunpack') {
    const path = join(ROOT, 'vendor/kindleunpack/lib/mobi_header.py');
    const python = probe(pythonBinary(), ['-c', 'import sys; print(sys.version.split()[0])']);
    return {
      ...engine,
      available: existsSync(path) && Boolean(python),
      detail: existsSync(path) ? (python ? `python ${python} + in-repo vendor/kindleunpack` : 'Python >= 3.8 is required') : 'vendor/kindleunpack/lib is missing from this checkout',
      ...(python ? { version: python } : {}),
    };
  }
  if (engine.id === 'libmobi') {
    const library = ['build/libmobi.so', 'build/libmobi.dylib'].map(name => join(ROOT, name)).find(existsSync);
    const capabilities = probe(mobiBinary(), ['--capabilities']);
    return {
      ...engine,
      available: Boolean(capabilities),
      detail: capabilities ? `in-repo vendor/libmobi ${library ? `(${display(library)})` : '(library path not found)'}` : 'run `make mobi`; HIKARI_MOBI may point at a built wiz-mobi',
      ...(capabilities ? { version: 'libmobi git-9062742' } : {}),
    };
  }
  if (engine.id === 'calibre') {
    const version = probe(calibreBinary(), ['--version']);
    return {
      ...engine,
      available: Boolean(version),
      detail: version ? `external ${display(calibreBinary())}` : `optional: install Calibre ${calibreBinary()} or set HIKARI_CALIBRE; never downloaded automatically`,
      ...(version ? { version } : {}),
    };
  }
  return { ...engine, available: true, detail: 'built into dist/ (TypeScript)' };
}

/** Current status of every engine, newest availability probe first. */
export function vendorStatus(): VendorStatus[] {
  return ENGINES.map(status);
}

/** Convenience lookup for diagnostics and error messages. */
export function engineStatus(id: VendorEngine['id']): VendorStatus {
  const found = vendorStatus().find(engine => engine.id === id);
  if (!found) throw new Error(`unknown MOBI engine: ${id}`);
  return found;
}

/** Machines readable by `:HikariDoctor` / `formats`. */
export function vendorSummary(): object {
  const vendors = vendorStatus();
  return {
    vendoredInRepository: true,
    engines: vendors.map(({ id, kind, location, license, available, requirement, capabilities, version, detail }) => ({
      id, kind, location, license, available, requirement, capabilities, ...(version ? { version } : {}), detail,
    })),
    // Inputs handled by the built-in converters, no external tool required.
    builtInInputs: ['EPUB', 'TXT', 'Markdown', 'HTML/XHTML', 'FB2', 'RTF', 'MOBI6/7 (uncompressed or PalmDOC)', 'KF8/AZW3 with libmobi'],
  };
}
