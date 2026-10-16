import { spawnSync } from 'node:child_process';
export function run(command, args, options = {}) {
  const result = spawnSync(command, args, { stdio: 'inherit', ...options });
  if (result.error) throw new Error(`cannot run ${command}: ${result.error.message}`);
  if (result.status !== 0) throw new Error(`${command} failed (${result.signal || result.status})`);
}
export function probe(command, args = ['--version']) {
  const result = spawnSync(command, args, { encoding: 'utf8', timeout: 10000, maxBuffer: 65536 });
  return !result.error && result.status === 0 ? (result.stdout || result.stderr).trim() : null;
}
