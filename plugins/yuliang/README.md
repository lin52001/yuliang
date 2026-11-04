# 余量插件 · 本地试验版

版本：0.1.0-beta.1，连接余量 App v0.17.0（build 23）及更新版本。当前目标是 macOS 桌面 Codex；不是官方插件目录已审核上架版本。

在 Codex 中查看 Codex / Claude 订阅额度、Token 服务端日统计和累计用量、更新时间，也能显示桌面卡片、换角色、触发专属动作和切换外观。人物界面仍是余量原生桌面卡片，本版不修改 Codex 账号栏。

## 安装与试用

1. 安装支持插件连接的余量 App，并先在 App 中完成需要的数据源连接。未连接的 Claude 来源会保持未知。
2. 安装 Node.js 20 或更新版本。插件本身没有额外 npm 依赖。
3. 按仓库根目录的插件安装说明添加本仓库插件市场，然后安装 `yuliang`；也可由支持本地导入的桌面客户端导入此目录。
4. 启用插件后，在 Codex 中输入：

   - 看看我的 AI 额度和 Token 用量。
   - 显示余量小组件，切到浅色紧凑版。
   - 换成持剑小猫，让它做专属动作。

如果当前对话还未加载新工具，重新打开一个对话后再试。安装位置、菜单和可用入口取决于客户端版本；不要把源码存在误认为插件已启用。

## 本地检查

从此插件目录运行：

```sh
node server/cli.mjs status
node server/cli.mjs show
node server/cli.mjs interact '{"action":"signature"}'
node server/cli.mjs display '{"layout":"compact","appearance":"light"}'
```

`refresh` 子命令接受 `{"provider":"selected"}`、`codex` 或 `claude`。刷新是异步操作，返回 `accepted` 后并不保证已读到新数据。插件复用 App 的每60秒采集，不重复运行另一套采集。

## 数据与隐私

插件通过当前用户私有的本机文件队列连接 App，不监听网络端口，也不创建云端或隧道。每次请求只返回额度、Token 摘要、时间和显示状态；请求及回应在完成或超时后清除。目录权限为700，文件为600，并检查所有权、符号链接、请求标识和大小。

插件不读取认证文件、浏览器 Cookie、邮箱、组织标识或聊天正文。你请求查询时，额度与 Token 摘要会作为工具结果进入当前 Codex 对话。安装包和 GitHub 源码不包含你的真实额度或认证数据。

Token 日统计使用服务端提供的日期，时区可能未注明；过往日期不冒称今天。额度未知时显示未知，角色互动不会改动真实额度。Claude 仍需官网登录和实际可读的额度信息，插件不会绕过订阅或登录限制。

## 开发依据

- [OpenAI 插件打包格式](https://developers.openai.com/plugins/build/plugins)
- [OpenAI 桌面本地插件说明](https://developers.openai.com/plugins/deploy/desktop-only)
- [MCP stdio 传输规范](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports)

代码沿用仓库 MIT 许可。此插件目录不包含角色图片，角色及品牌图形的许可见仓库 `ASSETS.md`。
