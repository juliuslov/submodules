import { probe } from './runner.mjs';
export function prerequisites(env = process.env) {
  const requirements = [
    ['Git', 'git'], ['npm', 'npm'], ['Make', 'make'],
    ['C compiler', env.CC || 'cc'], ['Archiver', env.AR || 'ar'],
    ['Python >= 3.8', env.HIKARI_PYTHON || env.WIZ_PYTHON || 'python3'],
    ['Rust >= 1.70', env.RUSTC || 'rustc'],
  ];
  const results = requirements.map(([name, executable]) => {
    const version = probe(executable);
    let ok = Boolean(version);
    const numbers = version?.match(/\b(\d+)\.(\d+)/);
    if (name.startsWith('Python')) ok &&= Boolean(numbers && (Number(numbers[1]) > 3 || Number(numbers[1]) === 3 && Number(numbers[2]) >= 8));
    if (name.startsWith('Rust')) ok &&= Boolean(numbers && (Number(numbers[1]) > 1 || Number(numbers[1]) === 1 && Number(numbers[2]) >= 70));
    return { name, executable, ok, version: version?.split('\n')[0] };
  });
  results.unshift({ name: 'Node >= 22', executable: process.execPath, ok: Number(process.versions.node.split('.')[0]) >= 22, version: process.version });
  return results;
}
export function supported(platform = process.platform) { return platform === 'linux' || platform === 'darwin'; }
