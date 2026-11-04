import { createHash } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { copyFile, lstat, mkdir, mkdtemp, readFile, readdir, rm, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const pluginRoot = path.join(root, 'plugins/yuliang');
const manifest = JSON.parse(await readFile(path.join(pluginRoot, 'plugin.json'), 'utf8'));
if (manifest.name !== 'yuliang' || !/^\d+\.\d+\.\d+(?:-[a-z0-9.]+)?$/.test(manifest.version)) {
  throw new Error('余量插件标识或版本无效。');
}
const packageName = `Yuliang-Plugin-v${manifest.version}`;
const destination = path.join(root, 'dist-release');
const archive = path.join(destination, `${packageName}.zip`);
const temporary = await mkdtemp(path.join(os.tmpdir(), 'yuliang-plugin-package-'));
const staging = path.join(temporary, packageName);
const forbiddenName = /^(?:node_modules|\.git|\.env(?:\..*)?|auth\.json|quota\.json|requests|responses|\.DS_Store)$/i;

async function copyTree(source, target) {
  const info = await lstat(source);
  if (info.isSymbolicLink()) throw new Error('插件发行包不允许符号链接。');
  if (info.isDirectory()) {
    await mkdir(target, { recursive: true });
    for (const item of await readdir(source, { withFileTypes: true })) {
      if (forbiddenName.test(item.name)) throw new Error(`插件目录包含非发行文件：${item.name}`);
      await copyTree(path.join(source, item.name), path.join(target, item.name));
    }
  } else if (info.isFile()) {
    await mkdir(path.dirname(target), { recursive: true });
    await copyFile(source, target);
  } else throw new Error('插件目录包含不支持的文件。');
}

try {
  await copyTree(pluginRoot, path.join(staging, 'plugins/yuliang'));
  await copyTree(path.join(root, '.agents/plugins/marketplace.json'), path.join(staging, '.agents/plugins/marketplace.json'));
  await copyTree(path.join(root, 'docs/YULIANG-PLUGIN.md'), path.join(staging, 'docs/YULIANG-PLUGIN.md'));
  await copyTree(path.join(root, 'LICENSE'), path.join(staging, 'LICENSE'));
  await copyTree(path.join(root, 'ASSETS.md'), path.join(staging, 'ASSETS.md'));
  await writeFile(path.join(staging, 'README.md'), `# 余量 Codex 本地插件\n\n版本：${manifest.version}。需要 macOS 14+、Node.js 20+ 和已安装的余量 0.17.0 build 23+。\n\n此包只提供插件。已有兼容 App 无需重复下载；尚未安装后台时，请先查看 [项目安装说明](https://github.com/lin52001/yuliang)。\n\n解压后在本目录执行：\n\n\`\`\`sh\ncodex plugin marketplace add .\ncodex plugin add yuliang@yuliang-local --json\n\`\`\`\n\n重启 Codex 后，在新聊天中使用余量。详情见 [插件指南](docs/YULIANG-PLUGIN.md)。\n`);
  await mkdir(destination, { recursive: true });
  const result = spawnSync('/usr/bin/ditto', ['-c', '-k', '--keepParent', staging, archive], { encoding: 'utf8' });
  if (result.error || result.status !== 0) throw new Error(result.stderr || '插件打包失败。');
  const digest = createHash('sha256').update(await readFile(archive)).digest('hex');
  await writeFile(path.join(destination, `${packageName}.sha256`), `${digest}  ${packageName}.zip\n`);
  console.log(`插件发行包：${archive}`);
  console.log(`SHA256：${digest}`);
  console.log('仅含插件、技能和安装说明；不含角色图集、账号额度、认证文件或本机运行数据。');
} finally {
  await rm(temporary, { recursive: true, force: true });
}
