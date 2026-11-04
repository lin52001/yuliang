#!/usr/bin/env node
import { callTool } from './tools.mjs';

const commands = {
  status: 'yuliang_status', refresh: 'yuliang_refresh', show: 'yuliang_show_widget',
  interact: 'yuliang_interact', character: 'yuliang_select_character', display: 'yuliang_set_display'
};
const [command, argumentText = '{}', ...extra] = process.argv.slice(2);
if (!commands[command] || extra.length || Buffer.byteLength(argumentText) > 16 * 1024) {
  process.stderr.write('用法：node server/cli.mjs status|refresh|show|interact|character|display [JSON参数]\n');
  process.exitCode = 2;
} else {
  let args;
  try { args = JSON.parse(argumentText); }
  catch {
    process.stderr.write('参数应为有效 JSON 对象。\n');
    process.exitCode = 2;
  }
  if (args !== undefined) {
    const result = await callTool(commands[command], args);
    process.stdout.write(`${JSON.stringify(result.structuredContent, null, 2)}\n`);
    if (result.isError) process.exitCode = 1;
  }
}
