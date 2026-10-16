import { probe } from './runner.mjs';

/** Minimal Node version: `require(esm)` (used by the dist CommonJS shims) is
 * enabled by default from 22.12.0. */
export const MINIMUM_NODE = [22, 12];

/** Required toolchain entries; `optional` entries never block a build. */
export function prerequisites(env = process.env) {
  const requirements = [
    ['Git', 'git', false], ['npm', 'npm', false], ['Make', 'make', false],
    ['C compiler', env.CC || 'cc', false], ['Archiver', env.AR || 'ar', false],
    ['Python >= 3.8', env.HIKARI_PYTHON || env.WIZ_PYTHON || 'python3', false],
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

export function supported(platform = process.platform) { return platform === 'linux' || platform === 'darwin'; }
