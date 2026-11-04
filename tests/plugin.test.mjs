import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import { PassThrough } from 'node:stream';
import { chmod, mkdtemp, mkdir, readFile, readdir, realpath, rm, stat, symlink, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';
import { promisify } from 'node:util';
import test from 'node:test';
import { BridgeError, inspectAppBundle, launchYuliang, requestBridge } from '../plugins/yuliang/server/bridge.mjs';
import { TOOLS, callTool, validateToolArguments } from '../plugins/yuliang/server/tools.mjs';
import { MAX_MESSAGE_BYTES, createProtocol, serve } from '../plugins/yuliang/server/protocol.mjs';

async function fixture(t) {
  const root = await mkdtemp(path.join(await realpath(os.tmpdir()), 'yuliang-plugin-test-'));
  await mkdir(path.join(root, 'Support'), { mode: 0o700 });
  t.after(() => rm(root, { recursive: true, force: true }));
  return { root, directory: path.join(root, 'Support', 'YuliangStandalone', 'PluginBridge') };
}

function fakeApp(t, directory, handler) {
  let active = false;
  let stopped = false;
  const seen = new Set();
  const run = async () => {
    while (!stopped) {
      let files = [];
      try { files = await readdir(path.join(directory, 'requests')); } catch (error) { if (error.code !== 'ENOENT') throw error; }
      for (const filename of files.filter(name => /^[a-f\d-]{36}\.json$/.test(name))) {
        if (seen.has(filename)) continue;
        seen.add(filename);
        const requestFile = path.join(directory, 'requests', filename);
        const request = JSON.parse(await readFile(requestFile, 'utf8'));
        await handler({ request, requestFile, responseFile: path.join(directory, 'responses', filename) });
      }
      await delay(3);
    }
  };
  let running;
  t.after(async () => { stopped = true; await running; });
  return async () => { if (!active) { active = true; running = run(); } };
}

async function respond(responseFile, request, result = {}, extra = {}) {
  await writeFile(responseFile, JSON.stringify({ schemaVersion: 1, id: request.id, ok: true,
    generatedAt: new Date().toISOString(), result, ...extra }), { mode: 0o600 });
}

async function protocolReady(bridge) {
  const handle = createProtocol({ bridge });
  const initialized = await handle({ jsonrpc: '2.0', id: 1, method: 'initialize', params: {
    protocolVersion: '2025-11-25', capabilities: {}, clientInfo: { name: 'test', version: '1' }
  } });
  await handle({ jsonrpc: '2.0', method: 'notifications/initialized' });
  return { handle, initialized };
}

test('plugin tool validation refuses unsupported settings and credentials before transport', async () => {
  let calls = 0;
  const bridge = async () => { calls++; return {}; };
  for (const [name, args] of [
    ['yuliang_status', { cookie: 'private' }], ['yuliang_refresh', { provider: 'chatgpt' }],
    ['yuliang_interact', { action: 'idle' }], ['yuliang_select_character', { character: 'dangoCat' }],
    ['yuliang_set_display', {}], ['yuliang_set_display', { appearance: 'system', command: 'open' }],
    ['yuliang_set_display', { language: 'zhHans' }]
  ]) {
    assert.equal((await callTool(name, args, bridge)).isError, true);
  }
  assert.equal(calls, 0);
  assert.throws(() => validateToolArguments('unknown', {}), { code: 'unknown_tool' });
});

test('status reads existing snapshots and preserves exact large Token strings and unknowns', async () => {
  const calls = [];
  const snapshot = { quotas: [{ provider: 'claude', windows: [{ remainingPercent: null, observedAt: null }] }],
    tokenUsage: { serverDay: '2026-11-03', serverDayTokens: '9007199254740993', todayTokens: null } };
  const result = await callTool('yuliang_status', {}, async (action, args) => { calls.push({ action, args }); return snapshot; });
  assert.deepEqual(calls, [{ action: 'get_status', args: {} }]);
  assert.deepEqual(result.structuredContent, snapshot);
  assert.equal(JSON.parse(result.content[0].text).tokenUsage.serverDayTokens, '9007199254740993');
  assert.equal(result.isError, false);
});

test('refresh acknowledgement stays asynchronous and safe tool hints reflect side effects', async () => {
  const result = await callTool('yuliang_refresh', {}, async (action, args) => {
    assert.equal(action, 'refresh'); assert.deepEqual(args, { provider: 'selected' });
    return { status: 'accepted', provider: 'codex', asynchronous: true };
  });
  assert.equal(result.structuredContent.asynchronous, true);
  assert.equal(TOOLS.find(tool => tool.name === 'yuliang_status').annotations.readOnlyHint, true);
  assert.equal(TOOLS.find(tool => tool.name === 'yuliang_interact').annotations.idempotentHint, false);
  assert.ok(TOOLS.every(tool => tool.annotations.openWorldHint === false && tool.annotations.destructiveHint === false));
});

test('filesystem bridge exchanges one private UUID request and cleans only its files', async t => {
  const { directory } = await fixture(t);
  let seenRequest;
  const launch = fakeApp(t, directory, async ({ request, requestFile, responseFile }) => {
    seenRequest = request;
    assert.match(request.id, /^[a-f\d]{8}-[a-f\d]{4}-4[a-f\d]{3}-[89ab][a-f\d]{3}-[a-f\d]{12}$/);
    assert.equal((await stat(requestFile)).mode & 0o777, 0o600);
    assert.equal((await stat(directory)).mode & 0o777, 0o700);
    await respond(responseFile, request, { tokenUsage: { lifetimeTokens: '9007199254740993' } });
  });
  const result = await requestBridge('get_status', {}, { directory, launch, timeoutMs: 2_000 });
  assert.equal(result.tokenUsage.lifetimeTokens, '9007199254740993');
  assert.equal(seenRequest.schemaVersion, 1);
  assert.equal(seenRequest.action, 'get_status');
  assert.deepEqual(await readdir(path.join(directory, 'requests')), []);
  assert.deepEqual(await readdir(path.join(directory, 'responses')), []);
});

test('already running App answers the queue without invoking the launcher', async t => {
  const { directory } = await fixture(t);
  const startApp = fakeApp(t, directory, async ({ request, responseFile }) => respond(responseFile, request, { ready: true }));
  await startApp();
  let launches = 0;
  const result = await requestBridge('get_status', {}, { directory, timeoutMs: 2_000,
    launch: async () => { launches++; throw new Error('Launching is forbidden here'); } });
  assert.deepEqual(result, { ready: true });
  assert.equal(launches, 0);
});

test('App response after 650ms stays within the warm window and never invokes launch', async t => {
  const { directory } = await fixture(t);
  const startApp = fakeApp(t, directory, async ({ request, responseFile }) => {
    await delay(650);
    await respond(responseFile, request, { ready: true });
  });
  await startApp();
  let launches = 0;
  const result = await requestBridge('get_status', {}, { directory, timeoutMs: 2_000,
    launch: async () => { launches++; throw new Error('Launcher should not run'); } });
  assert.deepEqual(result, { ready: true });
  assert.equal(launches, 0);
});

test('launcher failure does not discard a delayed response from an already starting App', async t => {
  const { directory } = await fixture(t);
  let requests = 0;
  const startApp = fakeApp(t, directory, async ({ request, responseFile }) => {
    requests++;
    await delay(1_250);
    await respond(responseFile, request, { ready: true });
  });
  await startApp();
  let launches = 0;
  const result = await requestBridge('get_status', {}, { directory, timeoutMs: 2_500,
    launch: async () => { launches++; throw Object.assign(new Error('private launch failure'), { code: 'EPERM' }); } });
  assert.deepEqual(result, { ready: true });
  assert.equal(launches, 1);
  assert.equal(requests, 1);
});

test('missing response after denied launch reports startup denial without asserting installation version', async t => {
  const { directory } = await fixture(t);
  let launches = 0;
  const startedAt = Date.now();
  await assert.rejects(requestBridge('get_status', {}, { directory, timeoutMs: 1_350,
    launch: async () => { launches++; throw Object.assign(new Error('private launch stderr'), { code: 'EACCES' }); }
  }), error => {
    assert.equal(error.code, 'app_launch_denied');
    assert.doesNotMatch(error.message, /build|23|private|stderr|请先安装/);
    return true;
  });
  assert.equal(launches, 1);
  assert.ok(Date.now() - startedAt >= 1_300, 'keep waiting after the launcher fails');
  assert.deepEqual(await readdir(path.join(directory, 'requests')), []);
});

test('successful launcher with no App response is a bridge timeout, not a launcher error', async t => {
  const { directory } = await fixture(t);
  let launches = 0;
  await assert.rejects(requestBridge('get_status', {}, { directory, timeoutMs: 1_250, launch: async () => { launches++; } }), { code: 'bridge_timeout' });
  assert.equal(launches, 1);
});

test('cold start processes a single queued interaction exactly once', async t => {
  const { directory } = await fixture(t);
  const requestIds = [];
  let launches = 0;
  const startApp = fakeApp(t, directory, async ({ request, responseFile }) => {
    requestIds.push(request.id);
    assert.equal(request.action, 'play_action');
    assert.deepEqual(request.arguments, { action: 'signature' });
    await respond(responseFile, request, { accepted: true });
  });
  const result = await requestBridge('play_action', { action: 'signature' }, { directory, timeoutMs: 2_000,
    launch: async () => { launches++; assert.equal((await readdir(path.join(directory, 'requests'))).length, 1); await startApp(); } });
  assert.deepEqual(result, { accepted: true });
  assert.equal(launches, 1);
  assert.equal(requestIds.length, 1);
});

test('Bundle ID launch fallback uses only fixed paths with a matching inspected identifier', async () => {
  const calls = [], inspected = [];
  await launchYuliang({ platform: 'darwin', homeDirectory: '/isolated/home',
    execute: async (command, args, options) => {
      calls.push({ command, args, timeout: options.timeout });
      if (args.includes('-b')) throw Object.assign(new Error('LaunchServices private detail'), { code: 1 });
      return { stdout: '' };
    },
    inspectBundle: async candidate => {
      inspected.push(candidate);
      return candidate === '/Applications/余量.app' ? 'org.unrelated.app' : 'com.yuliang.quota.standalone';
    }
  });
  assert.deepEqual(inspected, ['/Applications/余量.app', '/isolated/home/Applications/余量.app']);
  assert.deepEqual(calls.map(call => [call.command, call.args]), [
    ['/usr/bin/open', ['-g', '-b', 'com.yuliang.quota.standalone']],
    ['/usr/bin/open', ['-g', '/isolated/home/Applications/余量.app']]
  ]);
  assert.ok(calls.every(call => call.timeout > 0 && call.timeout <= 3_000));
});

test('mismatched fallback App identifiers are never launched', async () => {
  const opened = [];
  await assert.rejects(launchYuliang({ platform: 'darwin', homeDirectory: '/isolated/home',
    execute: async (_command, args) => { opened.push(args); throw Object.assign(new Error('private'), { code: 1 }); },
    inspectBundle: async () => 'org.unrelated.app'
  }), { code: 'app_launch_failed' });
  assert.deepEqual(opened, [['-g', '-b', 'com.yuliang.quota.standalone']]);
});

test('fallback inspection reads only Bundle ID metadata and refuses linked Info.plist', async t => {
  const { root } = await fixture(t);
  const appPath = path.join(root, '余量.app');
  await mkdir(path.join(appPath, 'Contents'), { recursive: true });
  const info = path.join(appPath, 'Contents', 'Info.plist');
  await writeFile(info, '<plist/>');
  const calls = [];
  const execute = async (command, args) => { calls.push({ command, args }); return { stdout: 'com.yuliang.quota.standalone\n' }; };
  assert.equal(await inspectAppBundle(appPath, { execute }), 'com.yuliang.quota.standalone');
  assert.deepEqual(calls, [{ command: '/usr/bin/plutil', args: ['-extract', 'CFBundleIdentifier', 'raw', '-o', '-', info] }]);
  await rm(info);
  const unrelated = path.join(root, 'unrelated-metadata');
  await writeFile(unrelated, 'do not inspect');
  await symlink(unrelated, info);
  assert.equal(await inspectAppBundle(appPath, { execute }), undefined);
  assert.equal(calls.length, 1);
});

test('bridge rejects symlinked directories without writing into their target', async t => {
  const { root, directory } = await fixture(t);
  const appDirectory = path.dirname(directory);
  const target = path.join(root, 'redirected');
  await mkdir(target, { mode: 0o700 });
  await symlink(target, appDirectory);
  await assert.rejects(requestBridge('get_status', {}, { directory, launch: async () => {}, timeoutMs: 100 }), { code: 'unsafe_bridge_directory' });
  assert.deepEqual(await readdir(target), []);
});

test('bridge rejects a symlink response and preserves the linked file', async t => {
  const { root, directory } = await fixture(t);
  const target = path.join(root, 'unrelated.txt');
  await writeFile(target, 'private unrelated data', { mode: 0o600 });
  const launch = fakeApp(t, directory, async ({ responseFile }) => symlink(target, responseFile));
  await assert.rejects(requestBridge('get_status', {}, { directory, launch, timeoutMs: 2_000 }), { code: 'unsafe_bridge_response' });
  assert.equal(await readFile(target, 'utf8'), 'private unrelated data');
});

test('bridge rejects a FIFO response without blocking before the file-type check', async t => {
  const { directory } = await fixture(t);
  const launch = fakeApp(t, directory, async ({ responseFile }) => promisify(execFile)('/usr/bin/mkfifo', ['-m', '600', responseFile]));
  const startedAt = Date.now();
  await assert.rejects(requestBridge('get_status', {}, { directory, launch, timeoutMs: 1_800 }), { code: 'unsafe_bridge_response' });
  assert.ok(Date.now() - startedAt < 1_800);
});

test('bridge refuses world-readable response data', async t => {
  const { directory } = await fixture(t);
  const launch = fakeApp(t, directory, async ({ request, responseFile }) => {
    await writeFile(responseFile, JSON.stringify({ schemaVersion: 1, id: request.id, ok: true, generatedAt: new Date().toISOString(), result: {} }), { mode: 0o644 });
  });
  await assert.rejects(requestBridge('get_status', {}, { directory, launch, timeoutMs: 2_000 }), { code: 'unsafe_bridge_response' });
});

test('bridge rejects mismatched request IDs rather than returning another result', async t => {
  const { directory } = await fixture(t);
  const launch = fakeApp(t, directory, async ({ request, responseFile }) => respond(responseFile, request, { secret: 'not returned' }, { id: 'different' }));
  await assert.rejects(requestBridge('get_status', {}, { directory, launch, timeoutMs: 2_000 }), { code: 'invalid_bridge_response' });
});

test('bridge rejects oversized response before JSON decoding', async t => {
  const { directory } = await fixture(t);
  const launch = fakeApp(t, directory, async ({ responseFile }) => writeFile(responseFile, 'x'.repeat(128 * 1024 + 1), { mode: 0o600 }));
  await assert.rejects(requestBridge('get_status', {}, { directory, launch, timeoutMs: 2_000 }), { code: 'unsafe_bridge_response' });
});

test('bridge timeout cleans its request without touching unrelated queue entries', async t => {
  const { directory } = await fixture(t);
  await assert.rejects(requestBridge('get_status', {}, { directory, launch: async () => {}, timeoutMs: 50 }), { code: 'bridge_timeout' });
  assert.deepEqual(await readdir(path.join(directory, 'requests')), []);
  assert.deepEqual(await readdir(path.join(directory, 'responses')), []);
});

test('filesystem access denial is classified without leaking the path or blaming App installation', async t => {
  const { directory } = await fixture(t);
  await mkdir(path.join(directory, 'requests'), { recursive: true, mode: 0o700 });
  await mkdir(path.join(directory, 'responses'), { mode: 0o700 });
  await chmod(path.join(directory, 'requests'), 0o500);
  let launches = 0;
  try {
    await assert.rejects(requestBridge('get_status', {}, { directory, timeoutMs: 100,
      launch: async () => { launches++; }
    }), error => {
      assert.equal(error.code, 'bridge_permission_denied');
      assert.match(error.message, /执行环境.*权限受限/);
      assert.doesNotMatch(error.message, /yuliang-plugin-test-|EACCES|EPERM|stderr|App 未安装|chmod|777/);
      return true;
    });
    assert.equal(launches, 0);
    assert.deepEqual(await readdir(path.join(directory, 'requests')), []);
  } finally { await chmod(path.join(directory, 'requests'), 0o700); }
});

test('native failure messages are replaced by fixed safe messages', async t => {
  const { directory } = await fixture(t);
  const launch = fakeApp(t, directory, async ({ request, responseFile }) => respond(responseFile, request, {}, {
    ok: false, error: { code: 'unavailable', message: '/private/account/cookie secret' }
  }));
  await assert.rejects(requestBridge('refresh', { provider: 'claude' }, { directory, launch, timeoutMs: 2_000 }), error => {
    assert.equal(error.code, 'unavailable');
    assert.doesNotMatch(error.message, /cookie|secret|private/);
    return true;
  });
});

test('launch failure produces a clear tool error without forwarding raw process details', async () => {
  const result = await callTool('yuliang_status', {}, async () => { throw new Error('private command environment'); });
  assert.equal(result.isError, true);
  assert.equal(result.structuredContent.error.code, 'internal_error');
  assert.doesNotMatch(result.content[0].text, /environment/);
});

test('MCP requires initialization, negotiates versions, and lists exactly the supported tools', async () => {
  const initial = createProtocol();
  assert.equal((await initial({ jsonrpc: '2.0', id: 0, method: 'tools/list' })).error.code, -32002);
  const { handle, initialized } = await protocolReady(async () => ({}));
  assert.equal(initialized.result.protocolVersion, '2025-11-25');
  const list = await handle({ jsonrpc: '2.0', id: 'list', method: 'tools/list' });
  assert.deepEqual(list.result.tools.map(tool => tool.name), TOOLS.map(tool => tool.name));
  assert.equal((await handle({ jsonrpc: '2.0', id: 3, method: 'tools/call', params: { name: 'unknown' } })).error.code, -32602);
});

test('MCP tool calls translate validated arguments and surface execution errors as tool results', async () => {
  const { handle } = await protocolReady(async (action, args) => {
    assert.equal(action, 'play_action'); assert.deepEqual(args, { action: 'signature' });
    throw new BridgeError('busy', '稍后再试');
  });
  const response = await handle({ jsonrpc: '2.0', id: 2, method: 'tools/call', params: { name: 'yuliang_interact', arguments: { action: 'signature' } } });
  assert.equal(response.result.isError, true);
  assert.equal(response.result.structuredContent.error.code, 'busy');
  assert.equal(response.result._meta['io.yuliang/pluginVersion'], '0.1.0-beta.2');
  assert.equal((await handle({ jsonrpc: '2.0', id: 3, method: 'tools/call', params: { name: 'yuliang_interact', arguments: [] } })).error.code, -32602);
});

test('MCP success and execution failure expose only a fixed plugin-version metadata field', async () => {
  const snapshot = { selectedProvider: 'codex', quotas: [], tokenUsage: { available: false } };
  const { handle } = await protocolReady(async action => {
    if (action === 'get_status') return snapshot;
    throw new BridgeError('app_launch_denied', '自动启动受限');
  });
  const success = await handle({ jsonrpc: '2.0', id: 10, method: 'tools/call', params: { name: 'yuliang_status' } });
  const failure = await handle({ jsonrpc: '2.0', id: 11, method: 'tools/call', params: { name: 'yuliang_refresh' } });
  assert.deepEqual(success.result.structuredContent, snapshot);
  assert.equal(failure.result.isError, true);
  for (const result of [success.result, failure.result]) assert.deepEqual(result._meta, { 'io.yuliang/pluginVersion': '0.1.0-beta.2' });
});

test('MCP maps filesystem permission codes to one fixed safe execution error', async () => {
  let fixedMessage;
  for (const code of ['EACCES', 'EPERM', 'bridge_permission_denied']) {
    const { handle } = await protocolReady(async () => {
      throw Object.assign(new Error('/private/account/cookie secret command stderr'), { code });
    });
    const response = await handle({ jsonrpc: '2.0', id: code, method: 'tools/call', params: { name: 'yuliang_status' } });
    assert.equal(response.result.isError, true);
    assert.equal(response.result.structuredContent.error.code, 'bridge_permission_denied');
    const message = response.result.structuredContent.error.message;
    assert.equal(message, fixedMessage ?? message);
    fixedMessage = message;
    assert.doesNotMatch(JSON.stringify(response), /private|cookie|secret|command|stderr/);
    assert.equal(JSON.parse(response.result.content[0].text).error.message, message);
    assert.deepEqual(response.result._meta, { 'io.yuliang/pluginVersion': '0.1.0-beta.2' });
  }
});

test('stdio recovers from malformed and oversized messages and emits only JSON-RPC lines', async () => {
  const input = new PassThrough();
  const output = new PassThrough();
  let collected = '';
  output.on('data', chunk => { collected += chunk.toString(); });
  const serving = serve({ input, output });
  input.write('{not json}\n');
  input.write('x'.repeat(MAX_MESSAGE_BYTES + 1));
  input.write('\n');
  const ping = JSON.stringify({ jsonrpc: '2.0', id: '中文', method: 'ping' }) + '\n';
  const bytes = Buffer.from(ping);
  input.write(bytes.subarray(0, bytes.length - 5));
  input.end(bytes.subarray(bytes.length - 5));
  await serving;
  const messages = collected.trim().split('\n').map(line => JSON.parse(line));
  assert.equal(messages.length, 3);
  assert.equal(messages[0].error.code, -32700);
  assert.equal(messages[1].error.code, -32700);
  assert.deepEqual(messages[2], { jsonrpc: '2.0', id: '中文', result: {} });
});

test('stdio rejects malformed UTF-8 rather than silently replacing invalid bytes', async () => {
  const input = new PassThrough(), output = new PassThrough();
  let collected = '';
  output.on('data', chunk => { collected += chunk.toString(); });
  const serving = serve({ input, output });
  input.write(Buffer.from('{"jsonrpc":"2.0","id":"'));
  input.write(Buffer.from([0xff]));
  input.end(Buffer.from('","method":"ping"}\n'));
  await serving;
  assert.equal(JSON.parse(collected).error.code, -32700);
});
