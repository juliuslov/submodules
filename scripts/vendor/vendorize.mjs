#!/usr/bin/env node
// Brings the pinned vendor gitlinks into the repository as ordinary files.
//
// The upstream revisions stay pinned as commit hashes recorded in
// `vendor/README.md` and `docs/RESEARCH.md`; only the Git plumbing changes
// (no more `.gitmodules`, no more `git submodule update`). Each vendor keeps
// the files its build actually needs, so the checkout stays reviewable.
import { rmSync, existsSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const vendor = join(root, 'vendor');

/** Paths dropped per vendor: VCS metadata, upstream CI, unused test corpora,
 * GUIs and documentation that no hikari build or test reads. Anything a hikari
 * build OR test reads is kept, including upstream sample books. */
const PRUNE = {
  miniz: ['.github', '.travis.yml', '.clang-format', 'examples', 'tests', 'meson.build', 'CMakePresets.json', 'Config.cmake.in', 'miniz.pc.in'],
  fflate: ['.github', 'demo', 'docs', 'test', 'scripts', 'package-lock.json', 'tsconfig.demo.json', 'tsconfig.esm.json', 'tsconfig.json', 'package.json', 'CHANGELOG.md', '.browserslistrc', '.npmignore', '.terserrc'],
  dkjson: ['.travis.yml', 'cmake', 'CMakeLists.txt', 'jsontest.lua', 'speedtest.lua', 'dkjson-2.5-2.rockspec', 'versions.txt'],
  stb: ['.github', '.travis.yml', 'data', 'deprecated', 'docs', 'tests', 'tools', 'stb_image_resize_test', 'stb_leakcheck.h'],
  libmobi: ['.github', '.travis.yml', 'msvc', 'mobi.xcodeproj', 'ChangeLog', 'NEWS', 'AUTHORS', 'autogen.sh', 'configure.ac', 'Makefile.am', 'CMakeLists.txt', 'libmobi.pc.in', 'src/CMakeLists.txt', 'src/Makefile.am', 'tools/CMakeLists.txt', 'tools/Makefile.am', 'tools/win32',
    // The repository stays DRM-free: the upstream removal tool is not included.
    'tools/mobidrm.c', 'tools/mobidrm.1.in',
    // Upstream's md5 corpus and shell/Makefile harness are dropped, but the
    // sample books themselves are kept: tests/libmobi.test.cjs verifies real
    // KF8, HUFF/CDIC, CP1252, multimedia, DRM and dictionary inputs against
    // them, and a self-contained repository must not need a fetch step to run
    // its own suite.
    'tests/md5', 'tests/Makefile.am', 'tests/test.sh.in'],
  kindleunpack: ['libgui', 'KindleUnpack.pyw', 'DumpMobiHeader_v023.py'],
};

function run(command, args) {
  execFileSync(command, args, { cwd: root, stdio: ['ignore', 'inherit', 'inherit'] });
}

const vendors = execFileSync('git', ['ls-files', '-s', 'vendor'], { cwd: root, encoding: 'utf8' })
  .trim().split('\n').filter(Boolean)
  .map(line => { const [meta, path] = line.split('\t'); return { path, mode: meta.split(' ')[0] }; })
  .filter(entry => entry.mode === '160000')
  .map(entry => ({ path: entry.path, name: entry.path.split('/').pop() }));

if (!vendors.length) {
  console.log('vendor: nothing to migrate; gitlinks are already gone.');
  process.exit(0);
}

const pins = {};
for (const entry of vendors) {
  const head = execFileSync('git', ['-C', entry.path, 'rev-parse', 'HEAD'], { cwd: root, encoding: 'utf8' }).trim();
  pins[entry.name] = head;
  // Unstage the gitlink but keep the working tree, then drop the submodule's
  // own git directory link so the files become ordinary tracked files.
  run('git', ['rm', '-q', '--cached', '-r', entry.path]);
  rmSync(join(root, entry.path, '.git'), { recursive: true, force: true });
  for (const doomed of PRUNE[entry.name] ?? []) {
    const target = join(root, entry.path, doomed);
    if (!existsSync(target)) continue;
    run('git', ['clean', '-q', '-fdx', '--', join(entry.path, doomed)]);
    rmSync(target, { recursive: true, force: true });
  }
  run('git', ['add', '-A', '--', entry.path]);
  console.log(`vendor/${entry.name}: in-repository at ${head}`);
}

run('git', ['rm', '-q', '--cached', '.gitmodules']);
rmSync(join(root, '.gitmodules'), { force: true });
console.log(`\nrecorded pins:\n${JSON.stringify(pins, null, 2)}`);
console.log('\nNext: update vendor/README.md, docs/RESEARCH.md and the installer, then run npm test.');
void vendor;
