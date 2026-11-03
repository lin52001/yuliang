// Reproducible native UI/model checks. All snapshots and storage are synthetic.
// The desktop-shell harness briefly opens only its own windows and status item.
import { spawn } from 'node:child_process';
import { copyFile, mkdir, mkdtemp, readdir, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

if (process.platform !== 'darwin') {
  throw new Error('Mac 原生界面验证需要 macOS、Command Line Tools 和已登录的图形会话。');
}
if (process.argv.length !== 2) throw new Error('用法：node apple/scripts/check-standalone-ui.mjs');

const apple = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const scratch = await mkdtemp(path.join(tmpdir(), 'yuliang-standalone-ui-'));
const cache = path.join(scratch, 'module-cache');
const frozen = path.join(scratch, 'sources');

async function run(command, args, completionMarker) {
  await new Promise((resolve, reject) => {
    const child = spawn(command, args, {
      cwd: frozen,
      stdio: ['inherit', 'pipe', 'inherit'],
      env: { ...process.env, CLANG_MODULE_CACHE_PATH: cache },
    });
    let output = '';
    child.stdout.setEncoding('utf8');
    child.stdout.on('data', chunk => {
      process.stdout.write(chunk);
      output = (output + chunk).slice(-100_000);
    });
    child.once('error', reject);
    child.once('close', (code, signal) => {
      if (code !== 0) return reject(new Error(`${path.basename(command)} 验证失败（${signal ?? code}）。`));
      if (completionMarker && !output.includes(completionMarker)) {
        return reject(new Error(`${path.basename(command)} 未报告完成标记，可能在图形会话不可用时提前退出；不能视为通过。`));
      }
      resolve();
    });
  });
}

try {
  await Promise.all([mkdir(cache), mkdir(frozen)]);
  const architecture = process.arch === 'arm64' ? 'arm64' : 'x86_64';
  const core = (await readdir(path.join(apple, 'Sources/QuotaCore')))
    .filter(name => name.endsWith('.swift')).sort().map(name => `Sources/QuotaCore/${name}`);
  const standalone = [
    'Shared/OriginalBuddy.swift',
    'Shared/QuotaCard.swift',
    'MacStandalone/CodexQuotaCollector.swift',
    'MacStandalone/StandaloneQuotaStore.swift',
    'MacStandalone/YuliangStandaloneApp.swift',
    'MacStandalone/StandaloneDesktopShell.swift',
  ];
  const harnesses = ['scripts/check-standalone-interactions.swift', 'scripts/check-desktop-shell.swift'];
  // Compile a single frozen source snapshot, so a concurrent edit cannot change
  // an input partway through the two native checks.
  const sources = [...core, ...standalone, ...harnesses];
  const directories = [...new Set(sources.map(name => path.dirname(path.join(frozen, name))))];
  await Promise.all(directories.map(directory => mkdir(directory, { recursive: true })));
  await Promise.all(sources.map(name => copyFile(path.join(apple, name), path.join(frozen, name))));

  const base = ['swiftc', '-target', `${architecture}-apple-macosx14.0`,
    '-module-cache-path', cache, '-parse-as-library'];
  await run('xcrun', [...base, '-emit-module', '-emit-library', '-static', '-module-name', 'QuotaCore', ...core,
    '-emit-module-path', path.join(scratch, 'QuotaCore.swiftmodule'), '-o', path.join(scratch, 'libQuotaCore.a')]);
  const linked = [...base, '-D', 'YULIANG_STANDALONE', '-D', 'QUOTA_SHELL_TESTING',
    '-I', scratch, '-L', scratch, '-lQuotaCore'];

  const interaction = path.join(scratch, 'check-standalone-interactions');
  await run('xcrun', [...linked, ...standalone, harnesses[0], '-o', interaction]);
  await run(interaction, [], 'Standalone互动隔离验证通过：11组。');

  const desktop = path.join(scratch, 'check-desktop-shell');
  await run('xcrun', [...linked, ...standalone, harnesses[1], '-o', desktop]);
  console.log('开始验证真实 AppKit 桌面卡片与菜单栏弹出卡；需要可用的图形会话，失败不会跳过。');
  try {
    await run(desktop, [], 'PASS desktop shell:');
  } catch (error) {
    throw new Error('桌面壳验证未通过。此项必须实际展示本进程的窗口和菜单栏弹出卡；请检查上方断言或图形会话访问权限。', { cause: error });
  }
  console.log('Mac 独立卡片的互动模型和原生窗口验证通过。测试未启动 Codex 采集、读取认证或修改用户额度存储。');
} finally {
  await rm(scratch, { recursive: true, force: true });
}
