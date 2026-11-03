// Produce a release archive from a verified native app. Does not upload anything.
import { createHash } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { lstat, mkdir, mkdtemp, readFile, readdir, rename, rm, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

if (process.platform !== 'darwin') throw new Error('Mac 发行包需要 macOS 的 codesign、lipo 与 ditto。');
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
let app = path.join(root, 'releases', '余量.app');
let output = path.join(root, 'dist-release');
const args = process.argv.slice(2);
for (let index = 0; index < args.length; index += 2) {
  if (!['--app', '--output'].includes(args[index]) || !args[index + 1]) {
    throw new Error('用法：node apple/scripts/package-release.mjs [--app /路径/余量.app] [--output /输出目录]');
  }
  if (args[index] === '--app') app = path.resolve(args[index + 1]);
  else output = path.resolve(args[index + 1]);
}
function run(command, parameters, capture = false) {
  const result = spawnSync(command, parameters, { encoding: 'utf8', stdio: capture ? ['ignore', 'pipe', 'pipe'] : 'inherit' });
  if (result.error || result.status !== 0) throw new Error(`${command} 失败（${result.status ?? result.error.message}）。${capture ? ` ${result.stderr?.trim() ?? ''}` : ''}`);
  return result.stdout?.trim();
}
const attributes = await lstat(app);
if (attributes.isSymbolicLink() || !attributes.isDirectory() || path.extname(app) !== '.app') throw new Error('来源必须是实际的 .app 目录，不能是符号链接。');
const info = path.join(app, 'Contents/Info.plist');
const bundleID = run('plutil', ['-extract', 'CFBundleIdentifier', 'raw', '-o', '-', info], true);
if (bundleID !== 'com.yuliang.quota.standalone') throw new Error('拒绝打包其他应用。');
const version = run('plutil', ['-extract', 'CFBundleShortVersionString', 'raw', '-o', '-', info], true);
if (!/^\d+\.\d+\.\d+$/.test(version)) throw new Error('应用版本必须是三段数字版本号。');
const manifest = JSON.parse(await readFile(path.join(root, 'package.json'), 'utf8'));
if (manifest.version !== version) throw new Error('应用版本与 package.json 不一致，请先重新构建。');
const build = run('plutil', ['-extract', 'CFBundleVersion', 'raw', '-o', '-', info], true);
const expectedBuild = run('plutil', ['-extract', 'CFBundleVersion', 'raw', '-o', '-', path.join(root, 'apple/MacStandalone/Info.plist')], true);
if (!/^\d+(?:\.\d+){0,2}$/.test(build) || build !== expectedBuild) {
  throw new Error('应用构建号与当前源码不一致，请先重新构建。');
}
run('codesign', ['--verify', '--strict', '--verbose=2', app]);
async function inspectBundle(directory) {
  for (const item of await readdir(directory, { withFileTypes: true })) {
    const full = path.join(directory, item.name);
    if (item.isSymbolicLink()) throw new Error('发行应用包含未审核的符号链接，拒绝打包。');
    if (/(?:anime-satiety|satiety-atlas|kuromi|my-melody|^auth\.json$|^quota\.json$|^\.env(?:\.|$))/i.test(item.name)) {
      throw new Error(`发行应用含私人主题或本机数据：${path.relative(app, full)}。请从干净公开源码重新构建。`);
    }
    if (item.isDirectory()) await inspectBundle(full);
  }
}
await inspectBundle(app);
for (const name of ['original-buddies-v1.png', 'LICENSE.txt', 'ASSETS.md']) {
  const resource = path.join(app, 'Contents/Resources', name);
  const attributes = await lstat(resource);
  if (!attributes.isFile() || attributes.isSymbolicLink() || attributes.size === 0) {
    throw new Error(`发行应用缺少完整资源或许可说明：${name}。请从干净公开源码重新构建。`);
  }
}
const executable = run('plutil', ['-extract', 'CFBundleExecutable', 'raw', '-o', '-', info], true);
if (!/^[A-Za-z0-9_-]+$/.test(executable)) throw new Error('应用可执行文件名无效。');
const architectures = run('lipo', ['-archs', path.join(app, 'Contents/MacOS', executable)], true).split(/\s+/).sort();
let architecture;
if (architectures.length === 1 && ['arm64', 'x86_64'].includes(architectures[0])) architecture = architectures[0];
else if (architectures.length === 2 && architectures.join(',') === 'arm64,x86_64') architecture = 'universal';
else throw new Error(`不支持的 Mach-O 架构：${architectures.join(', ')}`);
const filename = `Yuliang-v${version}-macOS-${architecture}.zip`;
await mkdir(output, { recursive: true });
const staging = await mkdtemp(path.join(output, '.yuliang-release-'));
try {
  const stagedZip = path.join(staging, filename);
  run('ditto', ['-c', '-k', '--sequesterRsrc', '--keepParent', app, stagedZip]);
  const archive = path.join(output, filename);
  await rename(stagedZip, archive);
  const matching = (await readdir(output)).filter(name => new RegExp(`^Yuliang-v${version.replaceAll('.', '\\.')}[-]macOS-(arm64|x86_64|universal)\\.zip$`).test(name)).sort();
  const sums = await Promise.all(matching.map(async name => `${createHash('sha256').update(await readFile(path.join(output, name))).digest('hex')}  ${name}`));
  const stagedSums = path.join(staging, 'SHA256SUMS');
  await writeFile(stagedSums, sums.join('\n') + '\n');
  await rename(stagedSums, path.join(output, 'SHA256SUMS'));
  console.log(`发行包已生成：${archive}`);
  console.log(`校验清单：${path.join(output, 'SHA256SUMS')}`);
  console.log(`Mach-O 实际架构：${architecture}；仅包含应用程序，不包含额度存储或认证信息。`);
} finally { await rm(staging, { recursive: true, force: true }); }
