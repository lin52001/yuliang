import { TOOLS, callTool } from './tools.mjs';
import { bridgePermissionError } from './bridge.mjs';

export const SERVER_VERSION = '0.1.0-beta.2';
export const MAX_MESSAGE_BYTES = 64 * 1024;
const PROTOCOLS = new Set(['2025-11-25', '2025-06-18', '2025-03-26', '2024-11-05']);
const plainObject = value => value !== null && typeof value === 'object' && !Array.isArray(value);
const rpcError = (id, code, message) => ({ jsonrpc: '2.0', id, error: { code, message } });
const validId = id => (typeof id === 'string' && id.length <= 128) || (Number.isSafeInteger(id) && id !== null);

export function createProtocol({ bridge } = {}) {
  let initialized = false;
  let ready = false;
  const safeBridge = bridge && (async (...args) => {
    try { return await bridge(...args); }
    catch (error) { throw bridgePermissionError(error) ?? error; }
  });
  return async function handle(message) {
    const id = validId(message?.id) ? message.id : null;
    if (!plainObject(message) || message.jsonrpc !== '2.0' || typeof message.method !== 'string'
        || (Object.hasOwn(message, 'id') && !validId(message.id))
        || (message.params !== undefined && !plainObject(message.params))) {
      return rpcError(id, -32600, 'Invalid JSON-RPC request.');
    }
    const notification = !Object.hasOwn(message, 'id');
    const params = message.params ?? {};
    if (notification) {
      if (message.method === 'notifications/initialized' && initialized) ready = true;
      return undefined;
    }
    if (message.method === 'initialize') {
      if (initialized) return rpcError(id, -32600, 'Server is already initialized.');
      if (typeof params.protocolVersion !== 'string' || !plainObject(params.capabilities)
          || !plainObject(params.clientInfo) || typeof params.clientInfo.name !== 'string'
          || typeof params.clientInfo.version !== 'string') {
        return rpcError(id, -32602, 'Invalid initialization parameters.');
      }
      initialized = true;
      return { jsonrpc: '2.0', id, result: {
        protocolVersion: PROTOCOLS.has(params.protocolVersion) ? params.protocolVersion : '2025-11-25',
        capabilities: { tools: { listChanged: false } },
        serverInfo: { name: 'yuliang', version: SERVER_VERSION },
        instructions: 'Local macOS companion bridge. Quota and Token usage are separate; preserve unknown values and observedAt. Refresh is asynchronous. Character interactions never change quota. No custom Codex sidebar is provided.'
      } };
    }
    if (message.method === 'ping') return { jsonrpc: '2.0', id, result: {} };
    if (!ready) return rpcError(id, -32002, 'Initialize the server before using tools.');
    if (message.method === 'tools/list') {
      if (params.cursor !== undefined) return rpcError(id, -32602, 'This tool list has no further pages.');
      return { jsonrpc: '2.0', id, result: { tools: TOOLS } };
    }
    if (message.method === 'tools/call') {
      if (typeof params.name !== 'string' || !TOOLS.some(tool => tool.name === params.name)) {
        return rpcError(id, -32602, 'Unknown tool.');
      }
      if (params.arguments !== undefined && !plainObject(params.arguments)) {
        return rpcError(id, -32602, 'Tool arguments must be an object.');
      }
      const result = await callTool(params.name, params.arguments ?? {}, safeBridge);
      return { jsonrpc: '2.0', id, result: { ...result, _meta: { 'io.yuliang/pluginVersion': SERVER_VERSION } } };
    }
    return rpcError(id, -32601, 'Method not found.');
  };
}

export async function serve({ input = process.stdin, output = process.stdout, bridge } = {}) {
  const handle = createProtocol({ bridge });
  const pending = new Set();
  let buffer = Buffer.alloc(0);
  let discarding = false;
  const send = message => { if (message !== undefined) output.write(`${JSON.stringify(message)}\n`); };
  function dispatch(line) {
    if (!line.length) return;
    let parsed;
    try { parsed = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(line)); }
    catch { send(rpcError(null, -32700, 'Invalid JSON.')); return; }
    if (pending.size >= 8) { send(rpcError(validId(parsed?.id) ? parsed.id : null, -32000, 'Too many pending requests.')); return; }
    const task = handle(parsed).then(send, () => send(rpcError(validId(parsed?.id) ? parsed.id : null, -32603, 'Internal error.')));
    pending.add(task);
    task.then(() => pending.delete(task), () => pending.delete(task));
  }
  for await (const raw of input) {
    let chunk = Buffer.isBuffer(raw) ? raw : Buffer.from(raw);
    while (chunk.length) {
      const newline = chunk.indexOf(10);
      const segment = newline < 0 ? chunk : chunk.subarray(0, newline);
      if (!discarding && buffer.length + segment.length > MAX_MESSAGE_BYTES) {
        send(rpcError(null, -32700, 'Message exceeds the 64 KiB limit.'));
        buffer = Buffer.alloc(0);
        discarding = true;
      }
      if (!discarding && segment.length) buffer = Buffer.concat([buffer, segment]);
      if (newline < 0) break;
      if (!discarding) dispatch(buffer);
      buffer = Buffer.alloc(0);
      discarding = false;
      chunk = chunk.subarray(newline + 1);
    }
  }
  // stdio requires a final newline; a truncated final message is rejected.
  if (buffer.length && !discarding) send(rpcError(null, -32700, 'Truncated JSON-RPC message.'));
  await Promise.allSettled(pending);
}
