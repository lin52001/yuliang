import { spawnSync } from 'node:child_process';
import { copyFile, mkdir, mkdtemp, readFile, readdir, rename, rm, stat } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const apple = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const root = path.dirname(apple);
const args = process.argv.slice(2);
if (args.length && (args.length !== 2 || args[0] !== '--output')) {
  throw new Error('用法：node apple/scripts/build-standalone.mjs [--output /绝对路径/余量.app]');
}
const output = path.resolve(args[1] ?? path.join(root, 'releases', '余量.app'));
if (path.extname(output) !== '.app') throw new Error('输出路径必须以 .app 结尾。');
const scratch = await mkdtemp(path.join(tmpdir(), 'yuliang-standalone-'));
await mkdir(path.dirname(output), { recursive: true });
const stagingDirectory = await mkdtemp(path.join(path.dirname(output), '.yuliang-build-'));
const stage = path.join(stagingDirectory, '余量.app');
const contents = path.join(stage, 'Contents');
const cache = path.join(scratch, 'module-cache');
const bundleID = 'com.yuliang.quota.standalone';

function run(command, parameters) {
  const result = spawnSync(command, parameters, {
    cwd: apple,
    stdio: 'inherit',
    env: { ...process.env, CLANG_MODULE_CACHE_PATH: cache },
  });
  if (result.error || result.status !== 0) throw new Error(`${command} 失败（${result.status ?? result.error.message}）。`);
}
async function exists(target) {
  try { await stat(target); return true; }
  catch (error) { if (error.code === 'ENOENT') return false; throw error; }
}

try {
  await Promise.all([mkdir(cache), mkdir(path.join(contents, 'MacOS'), { recursive: true }), mkdir(path.join(contents, 'Resources'), { recursive: true })]);
  if (await exists(output)) {
    const current = await readFile(path.join(output, 'Contents/Info.plist'), 'utf8');
    if (!current.includes(`<string>${bundleID}</string>`)) throw new Error('输出位置已有其他应用，拒绝覆盖。请使用 --output 指定新位置。');
  }
  const visualResources = ['original-buddies-v1.png', 'provider-codex.png'];
  for (const name of visualResources) {
    if (!(await exists(path.join(apple, 'Resources', name)))) {
      throw new Error(`缺少内置界面资源 apple/Resources/${name}，请使用完整源码归档。`);
    }
  }
  // The reference-derived atlas stays local until its redistribution rights
  // are verified. Public builds use the characters' explicit vector fallbacks.
  if (await exists(path.join(apple, 'Resources/new-buddies-v017.png'))) {
    visualResources.push('new-buddies-v017.png');
  }
  const architecture = process.arch === 'arm64' ? 'arm64' : 'x86_64';
  const base = ['swiftc', '-target', `${architecture}-apple-macosx14.0`, '-module-cache-path', cache];
  const core = (await readdir(path.join(apple, 'Sources/QuotaCore'))).filter(name => name.endsWith('.swift')).sort().map(name => `Sources/QuotaCore/${name}`);
  run('xcrun', [...base, '-parse-as-library', '-emit-module', '-emit-library', '-static', '-module-name', 'QuotaCore', ...core,
    '-emit-module-path', path.join(scratch, 'QuotaCore.swiftmodule'), '-o', path.join(scratch, 'libQuotaCore.a')]);
  const app = ['CodexTokenUsage.swift', 'CodexQuotaCollector.swift', 'QuotaWebCollector.swift', 'ClaudeConnectionView.swift', 'StandaloneQuotaStore.swift', 'StandalonePetStore.swift', 'StandalonePetView.swift', 'StandalonePluginBridge.swift', 'YuliangStandaloneApp.swift', 'StandaloneDesktopShell.swift'].map(name => `MacStandalone/${name}`);
  run('xcrun', [...base, '-parse-as-library', '-D', 'YULIANG_STANDALONE', '-I', scratch, '-L', scratch, '-lQuotaCore',
    'Shared/OriginalBuddy.swift', 'Shared/PetCareEffects.swift', 'Shared/QuotaCard.swift', ...app, '-o', path.join(contents, 'MacOS/YuliangStandalone')]);
  const resources = [
    copyFile(path.join(apple, 'MacStandalone/Info.plist'), path.join(contents, 'Info.plist')),
    ...visualResources.map(name => copyFile(path.join(apple, 'Resources', name), path.join(contents, 'Resources', name))),
    copyFile(path.join(root, 'extension/parser.js'), path.join(contents, 'Resources/parser.js')),
  ];
  for (const [source, name] of [['LICENSE', 'LICENSE.txt'], ['ASSETS.md', 'ASSETS.md']]) {
    const document = path.join(root, source);
    if (await exists(document)) resources.push(copyFile(document, path.join(contents, 'Resources', name)));
  }
  await Promise.all(resources);
  run('plutil', ['-lint', path.join(contents, 'Info.plist')]);
  run('codesign', ['--force', '--sign', '-', '--timestamp=none', '--identifier', bundleID, stage]);
  run('codesign', ['--verify', '--strict', '--verbose=2', stage]);
  const backup = `${output}.previous-${path.basename(scratch)}`;
  const hadOutput = await exists(output);
  if (hadOutput) await rename(output, backup);
  try {
    await rename(stage, output);
  } catch (error) {
    if (hadOutput) await rename(backup, output);
    throw error;
  }
  if (hadOutput) await rm(backup, { recursive: true });
  console.log(`Mac 独立应用已构建并完成本机 ad-hoc 签名校验：${output}`);
  console.log('这是原生桌面小窗，不是 WidgetKit 系统组件；没有进行 Apple 公证或发行签名。');
} finally {
  await Promise.all([rm(scratch, { recursive: true, force: true }), rm(stagingDirectory, { recursive: true, force: true })]);
}
