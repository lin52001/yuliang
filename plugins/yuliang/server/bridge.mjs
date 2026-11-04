import { execFile } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { constants } from 'node:fs';
import { chmod, lstat, mkdir, open, rename, unlink } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';
import { promisify } from 'node:util';

const executeFile = promisify(execFile);
const MAX_REQUEST_BYTES = 16 * 1024;
const MAX_RESPONSE_BYTES = 128 * 1024;
const MAX_WAIT_MS = 12_000;
const WARM_RESPONSE_WAIT_MS = 1_000;
const APP_BUNDLE_ID = 'com.yuliang.quota.standalone';
const OWNER_UID = process.getuid?.();

export class BridgeError extends Error {
  constructor(code, message) { super(message); this.name = 'BridgeError'; this.code = code; }
}

export function bridgePermissionError(error) {
  if (!['EACCES', 'EPERM', 'bridge_permission_denied'].includes(error?.code)) return undefined;
  return new BridgeError('bridge_permission_denied', '当前本机执行环境的权限受限，无法访问余量连接目录。请为本次余量本地命令请求必要的本机执行权限后重试；无需重新安装 App 或更改目录权限。');
}

export function defaultBridgeDirectory() {
  return path.join(os.homedir(), 'Library', 'Application Support', 'YuliangStandalone', 'PluginBridge');
}

function privateMode(stat) { return (stat.mode & 0o077) === 0; }
function owned(stat) { return OWNER_UID === undefined || stat.uid === OWNER_UID; }

async function verifyDirectoryChain(directory) {
  const parsed = path.parse(directory);
  let current = parsed.root;
  for (const component of directory.slice(parsed.root.length).split(path.sep).filter(Boolean)) {
    current = path.join(current, component);
    const stat = await lstat(current);
    if (stat.isSymbolicLink() || !stat.isDirectory()) {
      throw new BridgeError('unsafe_bridge_directory', '本机连接目录包含符号链接或非目录项，请检查余量安装。');
    }
  }
}

async function ensurePrivateDirectory(directory) {
  try { await mkdir(directory, { mode: 0o700 }); }
  catch (error) { if (error.code !== 'EEXIST') throw error; }
  await verifyDirectoryChain(directory);
  const stat = await lstat(directory);
  if (!owned(stat)) throw new BridgeError('unsafe_bridge_directory', '本机连接目录不属于当前用户。');
  if (!privateMode(stat)) await chmod(directory, 0o700);
}

async function prepareDirectories(directory) {
  // Only the dedicated App directory and its bridge are created or restricted.
  const appDirectory = path.dirname(directory);
  await verifyDirectoryChain(path.dirname(appDirectory));
  await ensurePrivateDirectory(appDirectory);
  await ensurePrivateDirectory(directory);
  const requests = path.join(directory, 'requests');
  const responses = path.join(directory, 'responses');
  await ensurePrivateDirectory(requests);
  await ensurePrivateDirectory(responses);
  return { requests, responses };
}

function launchFailure(error) {
  if (error?.code === 'EACCES' || error?.code === 'EPERM') return 'app_launch_denied';
  if (error?.code === 'ETIMEDOUT' || error?.killed || ['SIGTERM', 'SIGKILL'].includes(error?.signal)) return 'app_launch_timeout';
  return 'app_launch_failed';
}

function launcherError(code) {
  const messages = {
    app_launch_denied: '当前环境未允许自动启动余量。请手动打开余量后重试；这不代表 App 未安装。',
    app_launch_timeout: '自动启动余量超时，且本机连接尚未回应。请手动打开余量后重试。',
    app_launch_failed: '未能自动启动余量，且本机连接尚未回应。请手动打开余量后重试。'
  };
  return new BridgeError(Object.hasOwn(messages, code) ? code : 'app_launch_failed', messages[code] ?? messages.app_launch_failed);
}

function remainingTimeout(deadline, maximum) {
  const remaining = deadline - Date.now();
  if (remaining <= 0) throw launcherError('app_launch_timeout');
  return Math.max(1, Math.min(maximum, remaining));
}

export async function inspectAppBundle(appPath, { execute = executeFile, deadline = Date.now() + 1_000 } = {}) {
  // Only metadata is inspected. Production callers supply the two fixed App
  // locations below; no authentication or quota files are read here.
  await verifyDirectoryChain(path.join(appPath, 'Contents'));
  const infoPath = path.join(appPath, 'Contents', 'Info.plist');
  const info = await lstat(infoPath);
  if (!info.isFile() || info.isSymbolicLink() || info.size > 1024 * 1024) return undefined;
  const { stdout } = await execute('/usr/bin/plutil', ['-extract', 'CFBundleIdentifier', 'raw', '-o', '-', infoPath],
    { timeout: remainingTimeout(deadline, 1_000), maxBuffer: 1_024 });
  return stdout.trim();
}

export async function launchYuliang(options = {}) {
  const platform = options.platform ?? process.platform;
  if (platform !== 'darwin') {
    throw new BridgeError('unsupported_platform', '此试验版需要 macOS 和已安装的余量 App。');
  }
  const execute = options.execute ?? executeFile;
  const inspectBundle = options.inspectBundle ?? inspectAppBundle;
  const homeDirectory = options.homeDirectory ?? os.homedir();
  const deadline = options.deadline ?? Date.now() + MAX_WAIT_MS;
  const failures = [];
  const openApp = args => execute('/usr/bin/open', ['-g', ...args],
    { timeout: remainingTimeout(deadline, 3_000), maxBuffer: 8 * 1024 });
  try {
    await openApp(['-b', APP_BUNDLE_ID]);
    return;
  } catch (error) { failures.push(error instanceof BridgeError ? error.code : launchFailure(error)); }
  // LaunchServices may not yet know a freshly installed Bundle ID. A fallback
  // is allowed only at these locations and only after matching Info.plist.
  const candidates = ['/Applications/余量.app', path.join(homeDirectory, 'Applications', '余量.app')];
  for (const candidate of candidates) {
    if (Date.now() >= deadline) break;
    let identifier;
    try { identifier = await inspectBundle(candidate, { execute, deadline }); }
    catch (error) {
      if (['EACCES', 'EPERM'].includes(error?.code)) failures.push('app_launch_denied');
      continue;
    }
    if (identifier !== APP_BUNDLE_ID) continue;
    try { await openApp([candidate]); return; }
    catch (error) { failures.push(error instanceof BridgeError ? error.code : launchFailure(error)); }
  }
  throw launcherError(failures.includes('app_launch_denied') ? 'app_launch_denied'
    : failures.includes('app_launch_timeout') || Date.now() >= deadline ? 'app_launch_timeout' : 'app_launch_failed');
}

async function readPrivateResponse(filename) {
  let handle;
  try {
    // Do not wait on a FIFO/device before fstat has established a regular file.
    handle = await open(filename, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
    const stat = await handle.stat();
    if (!stat.isFile() || !owned(stat) || !privateMode(stat) || stat.nlink !== 1 || stat.size > MAX_RESPONSE_BYTES) {
      throw new BridgeError('unsafe_bridge_response', '余量返回文件的权限、类型或大小不符合要求。');
    }
    const buffer = Buffer.alloc(MAX_RESPONSE_BYTES + 1);
    const { bytesRead } = await handle.read(buffer, 0, buffer.length, 0);
    if (bytesRead > MAX_RESPONSE_BYTES) throw new BridgeError('unsafe_bridge_response', '余量返回内容过大。');
    try { return JSON.parse(buffer.subarray(0, bytesRead).toString('utf8')); }
    catch { throw new BridgeError('invalid_bridge_response', '余量返回了无法识别的内容，请更新 App 与插件。'); }
  } catch (error) {
    if (error.code === 'ENOENT') return undefined;
    if (error.code === 'ELOOP') throw new BridgeError('unsafe_bridge_response', '拒绝读取符号链接响应。');
    throw error;
  } finally { await handle?.close(); }
}

function validateResponse(response, id) {
  if (!response || typeof response !== 'object' || Array.isArray(response)
      || response.schemaVersion !== 1 || response.id !== id || typeof response.ok !== 'boolean'
      || !Number.isFinite(Date.parse(response.generatedAt))
      || Math.abs(Date.now() - Date.parse(response.generatedAt)) > 30_000) {
    throw new BridgeError('invalid_bridge_response', '余量返回版本、请求标识或时间不匹配。');
  }
  if (!response.ok) {
    const allowedCodes = new Set(['invalid_request', 'invalid_arguments', 'unsupported_action', 'unavailable_character',
      'unknown_character', 'busy', 'expired_request', 'refresh_unavailable', 'unavailable', 'request_too_large',
      'unsafe_file', 'duplicate_request', 'invalid_provider', 'invalid_action', 'bridge_disabled']);
    const code = allowedCodes.has(response.error?.code) ? response.error.code : 'app_request_failed';
    const messages = {
      busy: '余量当前正在处理另一项操作，请稍后再试。',
      unavailable_character: '此角色当前不可用，请先查询可选角色。',
      unknown_character: '此角色当前不可用，请先查询可选角色。',
      expired_request: '本次连接请求已过期，请重试。',
      refresh_unavailable: '当前来源尚未完成连接，请在余量中连接后重试。',
      unavailable: '当前来源尚未完成连接或暂时无法刷新，请在余量中检查连接状态。',
      bridge_disabled: '余量的插件连接尚未启用。'
    };
    throw new BridgeError(code, messages[code] ?? '余量未接受此次操作，请检查参数与 App 版本。');
  }
  if (!response.result || typeof response.result !== 'object' || Array.isArray(response.result)) {
    throw new BridgeError('invalid_bridge_response', '余量返回结果格式不受支持。');
  }
  return response.result;
}

export async function requestBridge(action, args = {}, options = {}) {
  if (!options.launch && process.platform !== 'darwin') {
    throw new BridgeError('unsupported_platform', '此试验版需要 macOS 和已安装的余量 App。');
  }
  const directory = path.resolve(options.directory ?? defaultBridgeDirectory());
  const timeoutMs = Math.min(MAX_WAIT_MS, Math.max(1, options.timeoutMs ?? MAX_WAIT_MS));
  const launch = options.launch ?? launchYuliang;
  const id = randomUUID();
  const payload = JSON.stringify({ schemaVersion: 1, id, createdAt: new Date().toISOString(), action, arguments: args });
  if (Buffer.byteLength(payload) > MAX_REQUEST_BYTES) throw new BridgeError('request_too_large', '本次操作参数过大。');
  let requestFile, responseFile, temporaryFile;
  try {
    const startedAt = Date.now();
    const deadline = startedAt + timeoutMs;
    const { requests, responses } = await prepareDirectories(directory);
    requestFile = path.join(requests, `${id}.json`);
    responseFile = path.join(responses, `${id}.json`);
    temporaryFile = path.join(requests, `.${id}.${randomUUID()}.tmp`);
    const handle = await open(temporaryFile, constants.O_CREAT | constants.O_EXCL | constants.O_WRONLY | constants.O_NOFOLLOW, 0o600);
    try { await handle.writeFile(payload, 'utf8'); }
    finally { await handle.close(); }
    await rename(temporaryFile, requestFile);
    const waitForResponse = async until => {
      do {
        const response = await readPrivateResponse(responseFile);
        if (response !== undefined) return validateResponse(response, id);
        const remaining = until - Date.now();
        if (remaining <= 0) break;
        await delay(Math.min(100, remaining));
      } while (Date.now() <= until);
      return undefined;
    };
    // An already running App can process the same queue without invoking
    // LaunchServices. This is also the only UUID used for a cold start.
    const warmResult = await waitForResponse(Math.min(deadline, Date.now() + WARM_RESPONSE_WAIT_MS));
    if (warmResult !== undefined) return warmResult;
    let startupError;
    if (Date.now() < deadline) {
      try { await launch({ deadline }); }
      catch (error) { startupError = error instanceof BridgeError ? launcherError(error.code) : launcherError(launchFailure(error)); }
    }
    // A denied/slow launcher must not discard a response from an App that was
    // already starting. Wait for this request, without reposting the action.
    const result = await waitForResponse(deadline);
    if (result !== undefined) return result;
    if (startupError) throw startupError;
    throw new BridgeError('bridge_timeout', '本机余量尚未回应。请确认 App 支持插件连接并保持运行，然后重试。');
  } catch (error) {
    const permissionError = bridgePermissionError(error);
    if (permissionError) throw permissionError;
    if (error instanceof BridgeError) throw error;
    throw new BridgeError('bridge_unavailable', '无法连接本机余量，请检查 App 是否已安装以及本机连接目录是否可写。');
  } finally {
    // Remove only this randomly identified exchange, never scan user data.
    await Promise.allSettled([temporaryFile, requestFile, responseFile].filter(Boolean).map(filename => unlink(filename)));
  }
}
