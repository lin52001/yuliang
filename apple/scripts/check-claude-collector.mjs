import { spawnSync } from 'node:child_process';
import { copyFile, mkdir, mkdtemp, readdir, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const apple = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const root = path.dirname(apple);
const oauthOnly = process.argv.includes('--oauth-only');
const upgradeOnly = process.argv.includes('--upgrade-only');
if (process.argv.length > 3 || (process.argv.length === 3 && !oauthOnly && !upgradeOnly)) {
  throw new Error('用法：node apple/scripts/check-claude-collector.mjs [--oauth-only|--upgrade-only]');
}
const scratch = await mkdtemp(path.join(tmpdir(), 'yuliang-claude-check-'));
const cache = path.join(scratch, 'module-cache');
await mkdir(cache);

function run(command, args) {
  const result = spawnSync(command, args, {
    cwd: apple, stdio: 'inherit', env: { ...process.env, CLANG_MODULE_CACHE_PATH: cache },
  });
  if (result.error || result.status !== 0) throw new Error(`${command} Claude 验证失败（${result.status ?? result.error.message}）。`);
}

try {
  const architecture = process.arch === 'arm64' ? 'arm64' : 'x86_64';
  const base = ['swiftc', '-target', `${architecture}-apple-macosx14.0`, '-module-cache-path', cache];
  const core = (await readdir(path.join(apple, 'Sources/QuotaCore')))
    .filter(name => name.endsWith('.swift')).sort().map(name => `Sources/QuotaCore/${name}`);
  run('xcrun', [...base, '-parse-as-library', '-emit-module', '-emit-library', '-static', '-module-name', 'QuotaCore', ...core,
    '-emit-module-path', path.join(scratch, 'QuotaCore.swiftmodule'), '-o', path.join(scratch, 'libQuotaCore.a')]);
  const linked = [...base, '-I', scratch, '-L', scratch, '-lQuotaCore'];
  run('xcrun', [...linked, '-typecheck', '-parse-as-library',
    'MacStandalone/QuotaWebCollector.swift', 'MacStandalone/ClaudeConnectionView.swift']);

  const bundle = path.join(scratch, 'ClaudeFixture.bundle');
  await mkdir(path.join(bundle, 'Contents/Resources'), { recursive: true });
  await copyFile(path.join(root, 'extension/parser.js'), path.join(bundle, 'Contents/Resources/parser.js'));
  await writeFile(path.join(bundle, 'Contents/Info.plist'), `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.yuliang.fixture.claude</string><key>CFBundlePackageType</key><string>BNDL</string></dict></plist>\n`);
  const executable = path.join(scratch, 'claude-collector-check');
  run('xcrun', [...linked, '-D', 'QUOTA_COLLECTOR_TESTING', '-parse-as-library',
    'MacStandalone/QuotaWebCollector.swift', 'scripts/test-standalone-collector.swift', '-o', executable]);
  run(executable, [path.join(apple, 'MacStandalone/Fixtures/usage.html'), bundle,
    ...(oauthOnly ? ['--oauth-only'] : upgradeOnly ? ['--upgrade-only'] : [])]);
  console.log(oauthOnly ? 'Claude 连接界面类型检查与 OAuth 弹窗目标验证通过。未登录真实账号。'
    : upgradeOnly ? 'Claude 连接界面类型检查与 3 组套餐页目标验证通过。未登录真实账号。'
    : 'Claude 连接界面类型检查与 15 组 WKWebView 隔离采集验证通过。未登录真实账号。');
} finally {
  await rm(scratch, { recursive: true, force: true });
}
