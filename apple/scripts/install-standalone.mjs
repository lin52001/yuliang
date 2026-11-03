import { spawnSync } from 'node:child_process';
import { lstat, mkdir, mkdtemp, realpath, rename, rm } from 'node:fs/promises';
import { homedir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const source = path.join(root, 'releases', '余量.app');
const args = process.argv.slice(2);
if (args.length && (args.length !== 2 || args[0] !== '--destination')) {
  throw new Error('用法：node apple/scripts/install-standalone.mjs [--destination /绝对路径/余量.app]');
}
const destination = path.resolve(args[1] ?? path.join(homedir(), 'Applications', '余量.app'));
const bundleID = 'com.yuliang.quota.standalone';
if (path.extname(destination) !== '.app') throw new Error('安装路径必须以 .app 结尾。');
if (destination === source) throw new Error('安装路径与构建来源相同，请选择其他位置。');

function run(command, parameters, capture = false) {
  const result = spawnSync(command, parameters, {
    cwd: root,
    encoding: 'utf8',
    stdio: capture ? ['ignore', 'pipe', 'pipe'] : 'inherit',
  });
  if (result.error || result.status !== 0) {
    const detail = capture ? ` ${result.stderr?.trim() ?? ''}` : '';
    throw new Error(`${command} 安装检查失败（${result.status ?? result.error.message}）。${detail}`);
  }
  return result.stdout?.trim();
}
async function appExists(target) {
  try {
    const attributes = await lstat(target);
    if (attributes.isSymbolicLink() || !attributes.isDirectory()) {
      throw new Error('应用位置是符号链接或普通文件，拒绝覆盖。');
    }
    return true;
  } catch (error) {
    if (error.code === 'ENOENT') return false;
    throw error;
  }
}
function checkBundleID(target) {
  const actual = run('plutil', ['-extract', 'CFBundleIdentifier', 'raw', '-o', '-', path.join(target, 'Contents/Info.plist')], true);
  if (actual !== bundleID) throw new Error('应用标识不属于余量独立版，拒绝安装或覆盖。');
}
function verify(target) {
  checkBundleID(target);
  run('codesign', ['--verify', '--strict', '--verbose=2', target]);
}

if (!(await appExists(source))) throw new Error('尚未找到已构建的 releases/余量.app，请先运行构建脚本。');
verify(source);
if (await appExists(destination)) {
  if (await realpath(destination) === await realpath(source)) throw new Error('安装路径与构建来源相同，请选择其他位置。');
  checkBundleID(destination);
}
await mkdir(path.dirname(destination), { recursive: true });
const stagingDirectory = await mkdtemp(path.join(path.dirname(destination), '.yuliang-install-'));
const stagedApp = path.join(stagingDirectory, '余量.app');
const backup = path.join(stagingDirectory, 'previous.app');
let preserveRecoveryDirectory = false;

try {
  run('ditto', ['--rsrc', '--extattr', source, stagedApp]);
  verify(stagedApp);
  // Recheck immediately before committing in case the destination changed
  // while copying. The rename and its rollback stay on the destination volume.
  const hadDestination = await appExists(destination);
  if (hadDestination) checkBundleID(destination);
  let oldMoved = false;
  let newMoved = false;
  try {
    if (hadDestination) {
      await rename(destination, backup);
      oldMoved = true;
    }
    await rename(stagedApp, destination);
    newMoved = true;
    verify(destination);
  } catch (error) {
    try {
      if (newMoved) await rename(destination, stagedApp);
      if (oldMoved) await rename(backup, destination);
    } catch (rollbackError) {
      preserveRecoveryDirectory = true;
      const recovery = oldMoved ? `原应用备份已保留在：${backup}` : `恢复目录已保留在：${stagingDirectory}`;
      throw new AggregateError([error, rollbackError], `安装失败且自动恢复未完成。${recovery}`);
    }
    throw error;
  }
  console.log(`余量已安装并完成签名完整性检查：${destination}`);
  console.log('安装脚本没有启动应用或结束任何进程。');
} finally {
  if (!preserveRecoveryDirectory) await rm(stagingDirectory, { recursive: true, force: true });
}
