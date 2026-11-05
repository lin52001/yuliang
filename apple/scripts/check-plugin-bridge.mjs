// Isolated native bridge verification. Never starts the installed app or collectors.
import { spawnSync } from 'node:child_process';
import { copyFile, mkdir, mkdtemp, readdir, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

if (process.platform !== 'darwin') throw new Error('原生桥接验证需要 macOS 与 Swift 工具链。');
const apple = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const scratch = await mkdtemp(path.join(tmpdir(), 'yuliang-plugin-bridge-'));
const cache = path.join(scratch, 'module-cache');
const frozen = path.join(scratch, 'sources');
function run(command, args, marker) {
  const result = spawnSync(command, args, { cwd: frozen, encoding: 'utf8',
    env: { ...process.env, CLANG_MODULE_CACHE_PATH: cache }, maxBuffer: 4_000_000 });
  if (result.stdout) process.stdout.write(result.stdout);
  if (result.stderr) process.stderr.write(result.stderr);
  if (result.error || result.status !== 0) throw new Error(`${command} 验证失败（${result.signal ?? result.status ?? result.error.message}）。`);
  if (marker && !result.stdout.includes(marker)) throw new Error('桥接验证缺少完成标记。');
}
try {
  await mkdir(cache);
  const architecture = process.arch === 'arm64' ? 'arm64' : 'x86_64';
  const base = ['swiftc', '-target', `${architecture}-apple-macosx14.0`, '-module-cache-path', cache, '-parse-as-library'];
  const core = (await readdir(path.join(apple, 'Sources/QuotaCore'))).filter(n => n.endsWith('.swift')).sort().map(n => `Sources/QuotaCore/${n}`);
  const standalone = ['CodexTokenUsage.swift', 'CodexQuotaCollector.swift', 'QuotaWebCollector.swift', 'ClaudeConnectionView.swift',
    'StandaloneQuotaStore.swift', 'StandalonePetStore.swift', 'StandalonePetView.swift', 'StandalonePluginBridge.swift', 'YuliangStandaloneApp.swift', 'StandaloneDesktopShell.swift'].map(n => `MacStandalone/${n}`);
  const sources = [...core, ...standalone, 'Shared/OriginalBuddy.swift', 'Shared/PetCareEffects.swift', 'Shared/QuotaCard.swift', 'scripts/check-plugin-bridge.swift'];
  await Promise.all([...new Set(sources.map(n => path.dirname(path.join(frozen, n))))].map(n => mkdir(n, { recursive: true })));
  await Promise.all(sources.map(n => copyFile(path.join(apple, n), path.join(frozen, n))));
  run('xcrun', [...base, '-emit-module', '-emit-library', '-static', '-module-name', 'QuotaCore', ...core,
    '-emit-module-path', path.join(scratch, 'QuotaCore.swiftmodule'), '-o', path.join(scratch, 'libQuotaCore.a')]);
  const executable = path.join(scratch, 'check-plugin-bridge');
  run('xcrun', [...base, '-D', 'YULIANG_STANDALONE', '-D', 'QUOTA_SHELL_TESTING', '-I', scratch, '-L', scratch, '-lQuotaCore',
    'Shared/OriginalBuddy.swift', 'Shared/PetCareEffects.swift', 'Shared/QuotaCard.swift', ...standalone, 'scripts/check-plugin-bridge.swift', '-o', executable]);
  run(executable, [], 'PASS plugin bridge:');
} finally { await rm(scratch, { recursive: true, force: true }); }
