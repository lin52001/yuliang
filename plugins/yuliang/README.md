# 余量插件 · 本地试验版

版本：0.1.0-beta.2，配套余量 App v0.17.1（build 24），最低兼容 v0.17.0（build 23）。当前目标是 macOS 桌面 Codex；不是官方插件目录已审核上架版本。

在 Codex 中查看 Codex / Claude 订阅额度、Token 服务端日统计和累计用量、更新时间，也能显示桌面卡片、换角色、触发专属动作和切换外观。人物界面仍是余量原生桌面卡片，本版不修改 Codex 账号栏。

v0.17.1 App 提供更精致的装饰进度条，并在 Duo 的原有外框内放大圆环与人物。可用插件切换这些布局；仅更新插件不会改变旧 App 的界面。详情见 [v0.17.1 更新说明](https://github.com/lin52001/yuliang/blob/main/RELEASE-v0.17.1.md)。

## 安装与试用

1. 确认本机余量为 v0.17.0 build 23 或更新版本；已有兼容 App 无需重复安装。先在 App 中完成需要的数据源连接。未连接的 Claude 来源会保持未知。
2. 安装 Node.js 20 或更新版本。插件本身没有额外 npm 依赖。
3. 按仓库根目录的插件安装说明添加本仓库插件市场，然后安装 `yuliang`；也可由支持本地导入的桌面客户端导入此目录。
4. 启用插件后，在 Codex 中输入：

   - 看看我的 AI 额度和 Token 用量。
   - 显示余量小组件，切到浅色紧凑版。
   - 换成持剑小猫，让它做专属动作。

如果当前对话还未加载新工具，重新打开一个对话后再试。安装位置、菜单和可用入口取决于客户端版本；不要把源码存在误认为插件已启用。

## 连接修复

beta.2 先等待运行中的余量回应，必要时再尝试启动已安装 App；启动请求失败后仍等待同一条请求，不会重复执行互动或刷新。修复了系统启动异常被统一报为 `app_unavailable` 的问题，并区分自动启动失败与本机连接无回应。自动启动失败不代表 App 缺失。

如果 v0.17.0 build 23 或更新的余量已经运行，只需更新插件，再重启 Codex 并开启新聊天，无需为了连接修复重装 App。需要新版视觉时再更新至 v0.17.1 build 24；之后的每次插件更新不要求重复安装兼容 App。遇到自动启动问题时可先手动打开现有余量并保持运行。插件不会下载或安装后台软件。

通过 GitHub 远程市场安装时，先更新市场快照，再安装插件，避免继续加载旧版：

```sh
codex plugin marketplace upgrade yuliang-local --json
codex plugin add yuliang@yuliang-local --json
```

本机路径市场无需远程 `marketplace upgrade`；本机源码更新后安装即可。两种方式都需重启 Codex，并在新聊天中加载新版工具。

## 本地检查

日常优先使用 `yuliang_status`、`yuliang_refresh`、`yuliang_show_widget`、`yuliang_interact`、`yuliang_select_character` 和 `yuliang_set_display` 六个 MCP 工具。仅在工具不可用或需要本机诊断时，从此插件目录运行备用 CLI：

```sh
node server/cli.mjs status
node server/cli.mjs show
node server/cli.mjs interact '{"action":"signature"}'
node server/cli.mjs display '{"layout":"compact","appearance":"light"}'
```

`refresh` 子命令接受 `{"provider":"selected"}`、`codex` 或 `claude`。刷新是异步操作，返回 `accepted` 后并不保证已读到新数据。插件复用 App 的每60秒采集，不重复运行另一套采集。

若 MCP 正常，而受限 Shell 中的备用 CLI 返回 `bridge_permission_denied`，表示该执行环境无法访问本机连接目录，不代表 App 缺失或目录损坏。早期插件可能将此情形显示为 `bridge_unavailable`。优先继续用 MCP；确需 CLI 时，只为该次余量 CLI 命令申请本机执行权限。保持连接目录 700、文件 600，不放宽目录或整个 Codex 的权限，也不读取或复制认证文件。更新插件后重启 Codex，并在新聊天中加载新版工具和技能。

## 数据与隐私

插件通过当前用户私有的本机文件队列连接 App，不监听网络端口，也不创建云端或隧道。每次请求只返回额度、Token 摘要、时间和显示状态；请求及回应在完成或超时后清除。目录权限为700，文件为600，并检查所有权、符号链接、请求标识和大小。

插件不读取认证文件、浏览器 Cookie、邮箱、组织标识或聊天正文。你请求查询时，额度与 Token 摘要会作为工具结果进入当前 Codex 对话。安装包和 GitHub 源码不包含你的真实额度或认证数据。

Token 日统计使用服务端提供的日期，时区可能未注明；过往日期不冒称今天。额度未知时显示未知，角色互动不会改动真实额度。Claude 仍需官网登录和实际可读的额度信息，插件不会绕过订阅或登录限制。

## 开发依据

- [OpenAI 插件打包格式](https://developers.openai.com/plugins/build/plugins)
- [OpenAI 桌面本地插件说明](https://developers.openai.com/plugins/deploy/desktop-only)
- [MCP stdio 传输规范](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports)

v0.17.1 公开 App 与源码提供全部七位角色的形象和动作，包括奶龙与持剑小猫。此插件目录及插件 ZIP 不包含角色图片，使用本机 App 资源；旧兼容 App 的形象不会随插件更新。代码沿用仓库 MIT 许可，角色、原设定及品牌图形另按仓库 `ASSETS.md` 所述条件处理，不代表官方授权或联名。
