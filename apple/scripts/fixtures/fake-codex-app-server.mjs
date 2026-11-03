// Isolated test double for CodexQuotaCollector. Never reads auth or contacts a service.
// Arguments: <temporary control.json> <temporary JSONL event log>
import fs from 'node:fs';
import readline from 'node:readline';

const [controlPath, eventsPath] = process.argv.slice(2);
if (!controlPath || !eventsPath) process.exit(2);
const event = (name, details = {}) => fs.appendFileSync(eventsPath,
  JSON.stringify({ event: name, pid: process.pid, at: Date.now(), ...details }) + '\n');
const control = () => JSON.parse(fs.readFileSync(controlPath, 'utf8'));
const send = (id, result) => process.stdout.write(JSON.stringify({ id, result }) + '\n');
const fail = (id, code, message) => process.stdout.write(JSON.stringify({ id, error: { code, message } }) + '\n');
process.stdout.on('error', () => process.exit(0));
let initialized = false;
let readInFlight = false;
let terminationIgnored = false;
event('launch');

const rl = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });
rl.on('line', line => {
  const request = JSON.parse(line);
  event('rpc', { method: request.method, id: request.id ?? null });
  const state = control();
  if (request.method === 'initialize') {
    if (state.mode === 'initializeError') {
      fail(request.id, -32000, 'Synthetic initialize failure');
      return;
    }
    send(request.id, { userAgent: 'synthetic-codex-app-server-fixture' });
    return;
  }
  if (request.method === 'initialized') { initialized = true; return; }
  if (request.method === 'account/usage/read') {
    if (!initialized || readInFlight) {
      event('protocolViolation', { reason: !initialized ? 'usage-before-initialized' : 'concurrent-usage' });
      fail(request.id, -32000, 'Synthetic protocol violation');
      return;
    }
    readInFlight = true;
    event('tokenReadStarted', { mode: state.mode });
    const deliverUsage = () => {
      readInFlight = false;
      event('tokenReadDelivered', { mode: state.mode });
      if (state.mode === 'usageUnsupported') { fail(request.id, -32601, 'Synthetic method not found'); return; }
      if (state.mode === 'usageUnauth') { fail(request.id, 401, 'Authentication required'); return; }
      if (state.mode === 'usageRateLimited') { fail(request.id, 429, 'Too many requests'); return; }
      if (state.mode === 'usageError') { fail(request.id, -32000, 'Synthetic usage failure'); return; }
      const summary = { lifetimeTokens: state.lifetimeTokens ?? 1234567, peakDailyTokens: 45678,
        currentStreakDays: 8, longestStreakDays: 14, longestRunningTurnSec: 540 };
      let dailyUsageBuckets = [
        { startDate: '2026-11-02', tokens: 12345 },
        { startDate: '2026-11-01', tokens: 9876 },
      ];
      if (state.mode === 'usageNull') { for (const key of Object.keys(summary)) summary[key] = null; dailyUsageBuckets = null; }
      if (state.mode === 'usageZero') { summary.lifetimeTokens = 0; dailyUsageBuckets = [{ startDate: '2026-11-03', tokens: 0 }]; }
      if (state.mode === 'usageInvalidCount') summary.lifetimeTokens = -1;
      if (state.mode === 'usageInvalidDate') dailyUsageBuckets[0].startDate = '2026-02-30';
      const result = { summary, dailyUsageBuckets,
        // These unknown fields must never be retained by the account-usage parser.
        threadUsage: { threadId: 'synthetic-private-thread', groups: [{ model: 'ignored', inputTokens: 999999 }] },
        email: 'synthetic-not-retained@example.invalid' };
      if (state.mode === 'usageMissingSummary') delete result.summary;
      if (state.mode === 'usageMissingBuckets') delete result.dailyUsageBuckets;
      send(request.id, result);
    };
    if (state.mode === 'usageSlow') setTimeout(deliverUsage, 20000); else deliverUsage();
    return;
  }
  if (request.method !== 'account/rateLimits/read') {
    if (request.id != null) fail(request.id, -32601, 'Synthetic method not found');
    return;
  }
  if (!initialized || readInFlight) {
    event('protocolViolation', { reason: !initialized ? 'read-before-initialized' : 'concurrent-read' });
    fail(request.id, -32000, 'Synthetic protocol violation');
    return;
  }
  readInFlight = true;
  event('readStarted', { mode: state.mode });
  const deliver = () => {
    event('readDelivered', { mode: state.mode });
    readInFlight = false;
    if (state.mode === 'unauth') { fail(request.id, 401, 'Unauthenticated: please login'); return; }
    if (state.mode === 'error') { fail(request.id, -32000, 'Synthetic read failed'); return; }
    if (state.mode === 'rateLimited') { fail(request.id, 429, 'Too many requests; retry later'); return; }
    if (state.mode === 'malformed') { send(request.id, { unexpected: true }); return; }
    const now = Math.floor(Date.now() / 1000);
    const window = (used, duration, reset) => ({ usedPercent: used, windowDurationMins: duration, resetsAt: now + reset });
    const bucket = {
      limitId: 'codex', limitName: 'Synthetic Codex',
      primary: window(state.used ?? 35, 300, 7_200),
      secondary: window(state.weekly ?? 60, 10_080, 86_400),
      credits: null, planType: 'plus'
    };
    if (state.mode === 'null') { bucket.primary = null; bucket.secondary = null; }
    if (state.mode === 'missingPrimary') delete bucket.primary;
    if (state.mode === 'missingSecondary') delete bucket.secondary;
    if (state.mode === 'nullPrimary') bucket.primary = null;
    if (state.mode === 'nullSecondary') bucket.secondary = null;
    if (state.mode === 'invalidPercent') bucket.primary.usedPercent = 101;
    const other = { ...bucket, limitId: 'other-model', primary: window(91, 300, 3_600) };
    if (state.mode === 'otherOnly') {
      send(request.id, { rateLimits: other, rateLimitsByLimitId: { 'other-model': other } });
      return;
    }
    if (state.mode === 'codexNull') {
      send(request.id, { rateLimits: other, rateLimitsByLimitId: { codex: null, 'other-model': other } });
      return;
    }
    if (state.mode === 'mapOtherLegacyCodex') {
      send(request.id, { rateLimits: bucket, rateLimitsByLimitId: { 'other-model': other } });
      return;
    }
    if (state.mode === 'codexIdOther') {
      send(request.id, { rateLimits: bucket, rateLimitsByLimitId: { codex: other } });
      return;
    }
    if (state.mode === 'legacy') { const legacy = { ...bucket }; delete legacy.limitId; send(request.id, { rateLimits: legacy }); return; }
    send(request.id, {
      rateLimits: { ...other, primary: window(77, 300, 3_600) },
      rateLimitsByLimitId: { 'other-model': other, codex: bucket }
    });
    if (state.mode === 'lateAfterPause') setTimeout(() => process.exit(0), 50);
  };
  if (state.delay > 0) setTimeout(deliver, state.delay); else deliver();
});
rl.on('close', () => {
  event('inputClosed');
  if (control().mode === 'lateAfterPause' && readInFlight) return;
  process.exit(0);
});
process.on('SIGTERM', () => {
  if (control().mode === 'lateAfterPause' && !terminationIgnored) {
    terminationIgnored = true;
    event('terminationIgnored');
    return;
  }
  event('terminated');
  process.exit(0);
});
process.on('exit', () => event('exit'));
