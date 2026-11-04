/*
 * Conservative parser for user-visible allowance fields only.
 * This file makes no network requests and never reads browser storage or cookies.
 * The collector must pass only Claude's usage page or ChatGPT alert/dialog text.
 */
(function attachVisibleParser(global) {
  'use strict';

  const MAX_TEXT = 20_000;
  const DAY = 86_400_000;
  const NUMBER = String.raw`\d+(?:\.\d+)?`;
  const UNIT = String.raw`(?:days?|hours?|hrs?|hr|minutes?|mins?|min|[dhm])(?![a-z])|(?:小时|分钟|天|时|分)`;
  const DURATION_TOKEN = String.raw`(?:${NUMBER})\s*(?:${UNIT})`;
  const DURATION = String.raw`${DURATION_TOKEN}(?:(?:\s*(?:[,，、]|and)\s*|\s*)${DURATION_TOKEN})*`;
  const RELATIVE_EN = new RegExp(String.raw`\bresets?\s+(?:in|after)\s+(${DURATION})`, 'i');
  const RELATIVE_ZH_AFTER = new RegExp(String.raw`(${DURATION})\s*(?:后|之后)(?:将)?重置`, 'i');
  const RELATIVE_ZH_PREFIX = new RegExp(String.raw`(?:距离)?重置(?:时间)?\s*(?:还有|剩余|将在|将于|[:：])?\s*(${DURATION})(?:\s*(?:后|之后))?`, 'i');
  const ISO = String.raw`\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(?::\d{2}(?:\.\d{1,3})?)?(?:Z|[+-]\d{2}:\d{2})`;
  const ABSOLUTE_ISO = new RegExp(String.raw`(?:\bresets?\s+(?:(?:at|on)\s+)?|重置(?:时间)?\s*[:：]?\s*)(${ISO})(?![\dA-Za-z:+-])`, 'i');

  function input(text, options, provider) {
    if (typeof text !== 'string' || !text.trim() || text.length > MAX_TEXT) return null;
    const now = options && Object.prototype.hasOwnProperty.call(options, 'now') ? options.now : Date.now();
    if (typeof now !== 'number' || !Number.isFinite(now) || !Number.isFinite(new Date(now).getTime())) return null;
    let url;
    try { url = new URL(options && options.url); } catch { return null; }
    if (provider === 'claude') {
      if (url.origin !== 'https://claude.ai' || !/^\/settings\/usage\/?$/.test(url.pathname)) return null;
    } else if (url.origin !== 'https://chatgpt.com') return null;
    return {
      now,
      observedAt: new Date(now).toISOString(),
      text: text.normalize('NFKC').replace(/\r\n?/g, '\n').replace(/[\u00a0\u2007\u202f]/g, ' '),
    };
  }

  function durationMilliseconds(value) {
    const token = new RegExp(String.raw`(${NUMBER})\s*(${UNIT})`, 'gi');
    let total = 0;
    let count = 0;
    for (const match of value.matchAll(token)) {
      const amount = Number(match[1]);
      const unit = match[2].toLowerCase();
      const multiplier = /^(?:d|day|days|天)$/.test(unit) ? DAY
        : /^(?:h|hr|hrs|hour|hours|小时|时)$/.test(unit) ? 3_600_000 : 60_000;
      total += amount * multiplier;
      count++;
    }
    return count && Number.isFinite(total) && total >= 0 && total <= 366 * DAY ? total : null;
  }

  function validISO(value) {
    const time = Date.parse(value);
    if (!Number.isFinite(time)) return null;
    const [year, month, day, hour, minute, second = '0'] = value.match(/^\d{4}|\d{2}/g) || [];
    const monthNumber = Number(month);
    if (monthNumber < 1 || monthNumber > 12 || Number(day) < 1
      || Number(day) > new Date(Date.UTC(Number(year), monthNumber, 0)).getUTCDate()
      || Number(hour) > 23 || Number(minute) > 59 || Number(second) > 59) return null;
    return new Date(time).toISOString();
  }

  function resetInformation(text, now) {
    const absolute = text.match(ABSOLUTE_ISO);
    if (absolute) {
      return { resetAt: validISO(absolute[1]), resetLabel: absolute[0].trim().slice(0, 120), relative: false };
    }
    for (const expression of [RELATIVE_EN, RELATIVE_ZH_AFTER, RELATIVE_ZH_PREFIX]) {
      const match = text.match(expression);
      if (!match) continue;
      const duration = durationMilliseconds(match[1]);
      const deadline = duration === null ? null : new Date(now + duration);
      return {
        resetAt: deadline && Number.isFinite(deadline.getTime()) ? deadline.toISOString() : null,
        resetLabel: match[0].replace(/\s+/g, ' ').trim().slice(0, 120),
        relative: duration !== null,
      };
    }

    // Preserve only a recognized time fragment. A date without its year/zone is
    // deliberately not interpreted in the collector device's local timezone.
    const weekday = String.raw`(?:Mon(?:day)?|Tue(?:sday)?|Wed(?:nesday)?|Thu(?:rsday)?|Fri(?:day)?|Sat(?:urday)?|Sun(?:day)?|today|tomorrow)`;
    const clock = String.raw`\d{1,2}:\d{2}(?:[ \t]*[ap]\.?m\.?)?(?:[ \t]*(?:UTC|GMT)(?:[+-]\d{1,2}(?::\d{2})?)?)?`;
    const uncertain = [
      new RegExp(String.raw`\bresets?\s+(?:(?:at|on)\s+)?${weekday}(?:\s*,?\s*${clock})?`, 'i'),
      new RegExp(String.raw`\bresets?\s+(?:(?:at|on)\s+)?${clock}`, 'i'),
      /重置(?:时间)?\s*[:：]?\s*(?:(?:周|星期)[一二三四五六日天]|今天|明天)(?:\s*(?:上午|下午|晚上)?\s*\d{1,2}(?:[:：]\d{2}|点(?:\d{1,2}分)?))?/,
      /重置(?:时间)?\s*[:：]?\s*\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}(?::\d{2})?/,
    ];
    for (const expression of uncertain) {
      const match = text.match(expression);
      if (match) return { resetAt: null, resetLabel: match[0].replace(/\s+/g, ' ').trim().slice(0, 120), relative: false };
    }
    return { resetAt: null, resetLabel: '', relative: false };
  }

  function percentage(text) {
    const values = [];
    const label = String.raw`(?:used|remaining|left|已经使用|已使用|已用|剩余|可用)`;
    // Match a whole pair once, from left to right. Independent prefix and
    // postfix passes can incorrectly pair the "used" in "30% used" with
    // the following "70% remaining" and turn agreeing fields into conflicts.
    const pairs = new RegExp(String.raw`(?<![\w.,+-])(${NUMBER})[ \t]*%[ \t]*(${label})(?![a-z])|(?<![a-z])(${label})(?![a-z])[ \t]*[:：]?[ \t]*(${NUMBER})[ \t]*%`, 'gi');
    let invalid = false;
    function addValue(numericText, labelText) {
      const numeric = Number(numericText);
      if (!Number.isFinite(numeric) || numeric < 0 || numeric > 100) { invalid = true; return; }
      values.push(/^(?:remaining|left|剩余|可用)$/i.test(labelText) ? 100 - numeric : numeric);
    }
    for (const match of text.matchAll(pairs)) {
      addValue(match[1] || match[4], match[2] || match[3]);
    }
    // Some DOM layouts put the number and its label on separate lines. Only
    // join such lines when both are isolated fields, never through prose.
    const lines = text.split('\n').map(line => line.trim()).filter(Boolean);
    const isolatedLabel = new RegExp(String.raw`^${label}$`, 'i');
    const isolatedPercent = new RegExp(String.raw`^(${NUMBER})[ \t]*%$`);
    for (let index = 0; index < lines.length; index++) {
      const match = lines[index].match(isolatedPercent);
      if (!match) continue;
      const adjacent = [lines[index - 1], lines[index + 1]].filter(line => line && isolatedLabel.test(line));
      for (const adjacentLabel of adjacent) addValue(match[1], adjacentLabel);
    }
    // An explicit but malformed negative/oversized percentage must not be
    // silently replaced by a guessed value or a reset-only observation.
    if (/(?:-\s*\d+(?:\.\d+)?\s*%\s*(?:used|remaining|left|已使用|已用|剩余|可用)|(?:\bused\b|\bremaining\b|已使用|已用|剩余|可用)\s*[:：]?\s*-\s*\d+(?:\.\d+)?\s*%)/i.test(text)) invalid = true;
    const unique = new Set(values.map(value => Math.round(value * 1000) / 1000));
    return { value: unique.size === 1 ? [...unique][0] : null, invalid: invalid || unique.size > 1 };
  }

  function heading(line, weeklyContext) {
    const session = line.match(/^(?:Current session(?:\s+usage)?|当前会话(?:用量)?|本次会话(?:用量)?)(?=$|[\s:：\d])/i);
    if (session) return { scope: 'session', weekly: false, rest: line.slice(session[0].length) };
    const weekly = line.match(/^(?:Weekly (?:limits?|usage)|每周(?:限制|用量|额度))(?=$|[\s:：\d])/i);
    if (weekly) return { scope: 'weekly', weekly: true, rest: line.slice(weekly[0].length) };
    const all = line.match(/^(?:All models|所有模型|全部模型)(?=$|[\s:：\d])/i);
    if (all) return { scope: weeklyContext ? 'weekly' : null, weekly: weeklyContext, rest: line.slice(all[0].length) };
    const sonnet = line.match(/^(?:Sonnet only|Only Sonnet|仅限\s*Sonnet|仅\s*Sonnet|Sonnet\s*专用)(?=$|[\s:：\d])/i);
    if (sonnet) return { scope: weeklyContext ? 'sonnet-weekly' : null, weekly: weeklyContext, rest: line.slice(sonnet[0].length) };
    // A new model-specific weekly allowance must not leak its percentage into
    // All models. Preserve weekly context so supported rows after it can still
    // be read; unknown model fields themselves stay outside this wire schema.
    if (/^(?:(?:Opus|Haiku|Sonnet|Fable)\b.*(?:only|usage|limits?)|Only\s+(?:Opus|Haiku|Fable)\b|[a-z][a-z0-9 .-]{0,40}\s+only$|(?:仅限|仅)\s*(?:Opus|Haiku|Fable)\b|仅限.*模型)/i.test(line)) {
      return { scope: null, weekly: weeklyContext, rest: '' };
    }
    if (/^(?:(?:Extra|Additional|Daily|Monthly)\s+(?:usage|limits?|credits?)|额外(?:用量|使用|额度)|每日(?:额度|限制)|每月(?:额度|限制)|API\s)/i.test(line)) {
      return { scope: null, weekly: false, rest: '' };
    }
    return null;
  }

  function parseClaudeUsage(text, options = {}) {
    const prepared = input(text, options, 'claude');
    if (!prepared) return null;
    const sections = [];
    let current = null;
    let weeklyContext = false;
    for (const rawLine of prepared.text.split('\n')) {
      const line = rawLine.trim();
      if (!line) continue;
      const next = heading(line, weeklyContext);
      if (next) {
        if (current) sections.push(current);
        weeklyContext = next.weekly;
        current = next.scope ? { id: next.scope, text: next.rest } : null;
      } else if (current) current.text += `\n${line}`;
    }
    if (current) sections.push(current);

    const windows = new Map();
    const conflicts = new Set();
    const labels = { session: '当前会话', weekly: '每周全部模型', 'sonnet-weekly': '每周 Sonnet' };
    for (const section of sections) {
      const parsedPercent = percentage(section.text);
      if (parsedPercent.invalid) { conflicts.add(section.id); windows.delete(section.id); continue; }
      const reset = resetInformation(section.text, prepared.now);
      if (parsedPercent.value === null && !reset.resetLabel) continue;
      const window = {
        id: section.id,
        label: labels[section.id],
        usedPercent: parsedPercent.value,
        resetAt: reset.resetAt,
        resetLabel: reset.resetLabel,
        note: reset.relative
          ? '从 Claude 用量页可见字段记录。相对重置文案可能经过取整，换算时间仅供参考。'
          : '从 Claude 用量页可见字段记录；未明确提供的数值或重置时刻保持未知。',
      };
      const previous = windows.get(window.id);
      if (previous && (previous.usedPercent !== window.usedPercent || previous.resetAt !== window.resetAt || previous.resetLabel !== window.resetLabel)) {
        conflicts.add(window.id);
        windows.delete(window.id);
      } else if (!conflicts.has(window.id)) windows.set(window.id, window);
    }
    if (!windows.size) return null;
    return {
      providerId: 'claude',
      pageKind: 'usage',
      observedAt: prepared.observedAt,
      source: 'browser',
      windows: [...windows.values()],
      parserVersion: 1,
    };
  }

  function parseChatGPTNotice(text, options = {}) {
    const prepared = input(text, options, 'chatgpt');
    if (!prepared) return null;
    const english = /^(?:(?:(?:your|the)\s+)?(?:usage|message|rate)\s+limit\s+(?:has\s+been\s+)?reached\b|(?:you(?:'|’)ve|you have|you)\s+(?:have\s+)?(?:reached|hit)\s+(?:the\s+|your\s+|a\s+)?(?:[\w.-]+\s+){0,5}(?:usage\s+|message\s+|rate\s+)?limit\b)/i;
    const chinese = /^(?:(?:你|您)?(?:已经?达到(?:了)?|已达|已用尽|已经用尽)(?:[^\n。！？?]{0,30})(?:上限|限制)|(?:你|您)?(?:已用尽|已经用尽)(?:[^\n。！？?]{0,30})(?:额度|用量|消息次数)|(?:额度|用量|消息|使用次数)(?:[^\n。！？?]{0,12})(?:已用尽|已耗尽))/;
    const recognized = prepared.text.split('\n').some(rawLine => {
      const line = rawLine.trim();
      const match = line.match(english) || line.match(chinese);
      if (!match) return false;
      // The statement itself must be asserted, rather than quoted in help,
      // negated, asked as a question, or used as a conditional description.
      const tail = line.slice(match[0].length);
      return !/^\s*(?:[?？]|时|后|的(?:用户|人|意思|含义)|是什么意思|示例|\b(?:means?|would|might)\b)/i.test(tail);
    });
    if (!recognized) return null;
    // Never infer 100% from a limit banner: it may concern a single model or
    // feature and does not establish the account's overall remaining quota.
    const reset = resetInformation(prepared.text, prepared.now);
    return {
      providerId: 'chatgpt',
      pageKind: 'limit-notice',
      observedAt: prepared.observedAt,
      source: 'browser',
      windows: [{
        id: 'notice',
        label: '网页限制提示',
        usedPercent: null,
        resetAt: reset.resetAt,
        resetLabel: reset.resetLabel,
        note: reset.relative
          ? '页面显示额度限制；适用模型或功能需在官方页面核对。相对重置文案可能经过取整。'
          : '页面显示额度限制；适用模型或功能需在官方页面核对，未提供统一剩余百分比。',
      }],
      parserVersion: 1,
    };
  }

  global.YuliangVisibleParser = Object.freeze({ parseClaudeUsage, parseChatGPTNotice });
})(globalThis);
