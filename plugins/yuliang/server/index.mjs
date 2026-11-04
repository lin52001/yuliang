#!/usr/bin/env node
import { serve } from './protocol.mjs';

serve().catch(() => {
  process.stderr.write('余量插件连接已停止，请重新启动插件。\n');
  process.exitCode = 1;
});
