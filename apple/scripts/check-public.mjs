// Parse native distribution scripts without running a collector or opening windows.
import { spawnSync } from 'node:child_process';
import { readdir, readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
async function walk(directory) {
  for (const item of await readdir(directory, { withFileTypes: true })) {
    const full = path.join(directory, item.name);
    if (item.isDirectory()) await walk(full);
    else if (item.isFile() && item.name.endsWith('.mjs')) {
      const result = spawnSync(process.execPath, ['--check', full], { stdio: 'inherit' });
      if (result.error || result.status !== 0) throw new Error(`脚本语法验证失败：${path.relative(root, full)}`);
    }
  }
}
await walk(path.join(root, 'apple/scripts'));
const info = await readFile(path.join(root, 'apple/MacStandalone/Info.plist'), 'utf8');
const manifest = JSON.parse(await readFile(path.join(root, 'package.json'), 'utf8'));
const escapedVersion = manifest.version.replaceAll('.', '\\.');
if (!new RegExp(`<key>CFBundleShortVersionString</key>\\s*<string>${escapedVersion}</string>`).test(info)) {
  throw new Error('package.json 与原生 Info.plist 的版本不一致。');
}
console.log('原生发行脚本语法与版本验证通过。');
