// Reproducible Process/Pipe verification using a synthetic local CLI only.
import { spawn } from 'node:child_process';
import { mkdir, mkdtemp, readdir, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

if (process.platform !== 'darwin') throw new Error('此验证需要 macOS 与 Xcode Command Line Tools。');
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const scratch = await mkdtemp(path.join(tmpdir(), 'yuliang-codex-collector-'));
const cache = path.join(scratch, 'module-cache');
await mkdir(cache);

async function run(command, args, extraEnv = {}) {
  await new Promise((resolve, reject) => {
    const child = spawn(command, args, {
      cwd: root, stdio: 'inherit',
      env: { ...process.env, CLANG_MODULE_CACHE_PATH: cache, ...extraEnv }
    });
    child.once('error', reject);
    child.once('exit', (code, signal) => code === 0 ? resolve() :
      reject(new Error(`${path.basename(command)} 验证失败（${signal ?? code}）。`)));
  });
}

try {
  const architecture = process.arch === 'arm64' ? 'arm64' : 'x86_64';
  const base = ['swiftc', '-target', `${architecture}-apple-macosx14.0`, '-module-cache-path', cache, '-parse-as-library'];
  const coreSources = (await readdir(path.join(root, 'Sources/QuotaCore')))
    .filter(name => name.endsWith('.swift')).sort().map(name => `Sources/QuotaCore/${name}`);
  await run('xcrun', [...base, '-emit-module', '-emit-library', '-module-name', 'QuotaCore', ...coreSources,
    '-emit-module-path', path.join(scratch, 'QuotaCore.swiftmodule'), '-o', path.join(scratch, 'libQuotaCore.dylib')]);
  const executable = path.join(scratch, 'test-codex-collector');
  await run('xcrun', [...base, '-D', 'QUOTA_COLLECTOR_TESTING', '-I', scratch, '-L', scratch, '-lQuotaCore',
    'MacStandalone/CodexQuotaCollector.swift', 'scripts/test-codex-collector.swift', '-o', executable]);
  await run(executable, [path.join(root, 'scripts/fixtures/fake-codex-app-server.mjs'), scratch, process.execPath],
    { DYLD_LIBRARY_PATH: scratch });
} finally {
  // Allow terminated fake CLI children to finish their local evidence log before cleanup.
  await new Promise(resolve => setTimeout(resolve, 200));
  await rm(scratch, { recursive: true, force: true });
}
