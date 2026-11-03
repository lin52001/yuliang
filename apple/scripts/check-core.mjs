// Swift Testing works with both complete Xcode and Command Line Tools.
import { spawnSync } from 'node:child_process';
import { access, mkdir, mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

if (process.platform !== 'darwin') throw new Error('核心验证需要 macOS 与 Swift 6 工具链。');
const apple = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const scratch = await mkdtemp(path.join(tmpdir(), 'yuliang-core-check-'));
const cache = path.join(scratch, 'module-cache');
await mkdir(cache);
try {
  const swiftc = spawnSync('xcrun', ['--find', 'swiftc'], { encoding: 'utf8' });
  if (swiftc.error || swiftc.status !== 0) throw new Error('没有找到 Swift，请先安装 Xcode Command Line Tools。');
  const macro = path.join(path.dirname(path.dirname(swiftc.stdout.trim())), 'lib/swift/host/plugins/testing/libTestingMacros.dylib');
  const args = ['test', '--disable-sandbox', '--disable-xctest', '--scratch-path', path.join(scratch, 'build'),
    '--cache-path', path.join(scratch, 'cache'), '--config-path', path.join(scratch, 'config'),
    '--security-path', path.join(scratch, 'security')];
  try {
    await access(macro);
    args.push('-Xswiftc', '-load-plugin-library', '-Xswiftc', macro);
  } catch { /* A complete Xcode toolchain can resolve its built-in Testing plugin itself. */ }
  const result = spawnSync('swift', args, { cwd: apple, stdio: 'inherit',
    env: { ...process.env, CLANG_MODULE_CACHE_PATH: cache, SWIFTPM_MODULECACHE_OVERRIDE: cache } });
  if (result.error || result.status !== 0) throw new Error(`Swift 核心测试失败（${result.status ?? result.error.message}）。`);
} finally { await rm(scratch, { recursive: true, force: true }); }
