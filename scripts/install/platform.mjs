import { readFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { probe } from './runner.mjs';

/** Minimal Node version: `require(esm)` (used by the dist CommonJS shims) is
 * enabled by default from 22.12.0. */
export const MINIMUM_NODE = [22, 12];

const here = dirname(fileURLToPath(import.meta.url));

/** Termux sets PREFIX to its app-private prefix and exports TERMUX_VERSION; on a
 * Termux build of Node, `process.platform` is `android`. Together these are the
 * reliable detection signals — the Android kernel alone looks like Linux. */
export function termux(environment = process.env) {
  if (environment.TERMUX_VERSION) return true;
  const prefix = environment.PREFIX || environment.TERMUX_PREFIX || '';
  return /com\.termux/i.test(prefix);
}

export function platformName(environment = process.env, platform = process.platform) {
  if (termux(environment)) return 'termux';
  if (platform === 'android') return 'android';
  if (platform === 'linux' || platform === 'darwin' || platform === 'win32') return platform;
  return 'unknown';
}

/** POSIX Linux/macOS build as before, plus Termux/Android. Windows stays out of
 * scope: the natives, the sockets and the shell scripts all assume POSIX. */
export function supported(platform = process.platform, environment = process.env) {
  return platform === 'linux' || platform === 'darwin' || platform === 'android' || termux(environment);
}

/** Toolchain names, honouring the explicit CC/AR/Python overrides first. Termux
 * ships clang (which provides `cc` only in some releases) and llvm-ar rather
 * than GNU binutils, so the defaults follow the platform instead of assuming
 * Debian naming. */
export function toolchain(environment = process.env) {
  const isTermux = termux(environment) || environment.HIKARI_TERMUX === '1';
  return {
    cc: environment.CC || (isTermux ? 'clang' : 'cc'),
    ar: environment.AR || (isTermux ? 'llvm-ar' : 'ar'),
    python: environment.HIKARI_PYTHON || environment.WIZ_PYTHON || 'python3',
    termux: isTermux,
  };
}

/** Required toolchain entries; `optional` entries never block a build. */
export function prerequisites(env = process.env) {
  const tools = toolchain(env);
  const requirements = [
    ['Git', 'git', false], ['npm', 'npm', false], ['Make', 'make', false],
    ['C compiler', tools.cc, false], ['Archiver', tools.ar, false],
    ['Python >= 3.8', tools.python, false],
    // The ASCII addon is optional: services/ascii/render/ is a complete
    // TypeScript renderer, so a missing Rust toolchain never breaks hikari.
    ['Rust >= 1.88 (optional, napi-rs ASCII addon)', env.RUSTC || env.CARGO || 'cargo', true],
  ];
  const results = requirements.map(([name, executable, optional]) => {
    const version = probe(executable);
    let ok = Boolean(version);
    const numbers = version?.match(/\b(\d+)\.(\d+)/);
    if (name.startsWith('Python')) ok &&= Boolean(numbers && (Number(numbers[1]) > 3 || Number(numbers[1]) === 3 && Number(numbers[2]) >= 8));
    if (name.startsWith('Rust')) ok &&= Boolean(numbers && (Number(numbers[1]) > 1 || Number(numbers[1]) === 1 && Number(numbers[2]) >= 88));
    return { name, executable, ok, optional, version: version?.split('\n')[0] };
  });
  const [major, minor] = process.versions.node.split('.').map(Number);
  const nodeOk = major > MINIMUM_NODE[0] || (major === MINIMUM_NODE[0] && minor >= MINIMUM_NODE[1]);
  results.unshift({ name: `Node >= ${MINIMUM_NODE.join('.')}`, executable: process.execPath, ok: nodeOk, optional: false, version: process.version });
  return results;
}

/** Termux packages hikari/WeiWei need, read from the single list the pure-shell
 * bootstrap (scripts/install/termux.sh) also uses. Each entry is
 * `{ package, binary, optional }`. Missing or malformed lines are skipped so a
 * broken checkout never turns into a crash inside the installer. */
export function termuxPackages(source = join(here, 'termux-packages.txt')) {
  let text;
  try {
    text = readFileSync(source, 'utf8');
  } catch {
    return [];
  }
  const packages = [];
  for (const line of text.split('\n')) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith('#')) continue;
    const [name, binary, requirement] = trimmed.split(/\s+/);
    if (!name || !/^[a-z0-9][a-z0-9.+-]*$/i.test(name)) continue;
    packages.push({ package: name, binary: binary || name, optional: requirement === 'optional' });
  }
  return packages;
}

/** `pkg install -y …` line for the packages whose binaries are missing, so the
 * Termux error paths say exactly what to run. */
export function termuxInstallHint(env = process.env, list = termuxPackages()) {
  const missing = list.filter(entry => !entry.optional && !probe(entry.binary));
  if (!missing.length) return null;
  return `pkg install -y ${missing.map(entry => entry.package).join(' ')}`;
}

const BUILD_PACKAGES = {
  git: 'git', npm: 'nodejs-lts', node: 'nodejs-lts', make: 'make',
  clang: 'clang', cc: 'clang', 'llvm-ar': 'clang', ar: 'binutils',
  python3: 'python', python: 'python', cargo: 'rust', rustc: 'rust',
};

/** `pkg install -y …` for the *build* prerequisites that failed, mapped by
 * executable name. Used by the installer error path on Termux, where every
 * missing tool is one package away. */
export function termuxBuildHint(failed) {
  const packages = [];
  for (const tool of failed) {
    const base = String(tool.executable || '').split('/').pop();
    const name = BUILD_PACKAGES[base] || BUILD_PACKAGES[String(tool.name || '').toLowerCase()];
    if (name && !packages.includes(name)) packages.push(name);
  }
  if (!packages.length) return null;
  return `pkg install -y ${packages.join(' ')}`;
}

/** Absolute path of the package list, for diagnostics and tests. */
export function termuxPackagesPath() { return resolve(here, 'termux-packages.txt'); }
