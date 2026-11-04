import { BridgeError, requestBridge } from './bridge.mjs';

const enumString = values => ({ type: 'string', enum: values });
const emptySchema = { type: 'object', properties: {}, additionalProperties: false };
export const INTERACTIONS = ['signature', 'random', 'eating', 'pat', 'wave', 'nap', 'celebrate', 'jump', 'dance', 'spin', 'stretch', 'nuzzle', 'peek', 'sip'];
export const CHARACTERS = ['dragonGirl', 'claudeGirl', 'deepseekGirl', 'geminiGirl', 'cloudSprite', 'nailong', 'swordCat'];
const definitions = [
  { name: 'yuliang_status', title: '余量状态', action: 'get_status', readOnly: true,
    description: '读取本机余量已有的 Codex、Claude 额度、Token 日统计与累计、更新时间、可选角色和显示设置。只读已有采样，不触发额外采集；未知保持未知。', inputSchema: emptySchema },
  { name: 'yuliang_refresh', title: '刷新余量', action: 'refresh',
    description: '请求现有余量 App 刷新所选来源；这是异步请求，accepted 不代表已取得新读数。不会新建采集器。',
    inputSchema: { type: 'object', properties: { provider: enumString(['selected', 'codex', 'claude']) }, additionalProperties: false } },
  { name: 'yuliang_show_widget', title: '显示余量小组件', action: 'show_widget',
    description: '显示本机余量的原生桌面卡片。此试验版不会在 Codex 账号栏插入人物。', inputSchema: emptySchema },
  { name: 'yuliang_interact', title: '和小伙伴互动', action: 'play_action',
    description: '让当前人物做专属动作、随机回应、摸头、跳跃或喂饼干等。仅改变动画和鼓励文字，不改变真实额度或 Token。',
    inputSchema: { type: 'object', properties: { action: enumString(INTERACTIONS) }, required: ['action'], additionalProperties: false } },
  { name: 'yuliang_select_character', title: '切换小伙伴', action: 'select_character',
    description: '选择本机已安装且可用的角色。先查询 yuliang_status 的 characters 列表；素材缺失时以 App 的实际可选项为准。',
    inputSchema: { type: 'object', properties: { character: enumString(CHARACTERS) }, required: ['character'], additionalProperties: false } },
  { name: 'yuliang_set_display', title: '调整余量外观', action: 'set_display',
    description: '按用户要求切换标准、紧凑、Duo 模式，以及浅色、深色、系统外观和中英日语言。仅提交明确要求的字段。',
    inputSchema: { type: 'object', properties: { layout: enumString(['standard', 'compact', 'duo']), appearance: enumString(['light', 'dark', 'system']), language: enumString(['system', 'zh-Hans', 'en', 'ja']) }, minProperties: 1, additionalProperties: false } }
];

export const TOOLS = definitions.map(({ action, readOnly, ...tool }) => ({ ...tool,
  annotations: { readOnlyHint: readOnly === true, destructiveHint: false,
    idempotentHint: readOnly === true || ['show_widget', 'select_character', 'set_display'].includes(action), openWorldHint: false }
}));

export function validateToolArguments(name, args) {
  const definition = definitions.find(item => item.name === name);
  if (!definition) throw new BridgeError('unknown_tool', '未知的余量工具。');
  if (!args || typeof args !== 'object' || Array.isArray(args)) throw new BridgeError('invalid_arguments', '工具参数必须是对象。');
  const schema = definition.inputSchema;
  if (Object.keys(args).some(key => !Object.hasOwn(schema.properties, key))) throw new BridgeError('invalid_arguments', '包含不支持的参数。');
  for (const key of schema.required ?? []) {
    if (!Object.hasOwn(args, key)) throw new BridgeError('invalid_arguments', `缺少参数：${key}。`);
  }
  if (schema.minProperties && Object.keys(args).length < schema.minProperties) throw new BridgeError('invalid_arguments', '请至少指定一项显示设置。');
  for (const [key, value] of Object.entries(args)) {
    if (typeof value !== 'string' || !schema.properties[key].enum.includes(value)) throw new BridgeError('invalid_arguments', `参数 ${key} 的值不受支持。`);
  }
  return { action: definition.action, arguments: name === 'yuliang_refresh' ? { provider: 'selected', ...args } : args };
}

export async function callTool(name, args = {}, bridge = requestBridge) {
  try {
    const operation = validateToolArguments(name, args);
    const result = await bridge(operation.action, operation.arguments);
    return { content: [{ type: 'text', text: JSON.stringify(result) }], structuredContent: result, isError: false };
  } catch (error) {
    const safe = error instanceof BridgeError ? error : new BridgeError('internal_error', '余量操作未完成，请重试。');
    const result = { error: { code: safe.code, message: safe.message } };
    return { content: [{ type: 'text', text: JSON.stringify(result) }], structuredContent: result, isError: true };
  }
}
