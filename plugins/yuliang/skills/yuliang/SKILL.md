---
name: yuliang
description: 查看本机余量 App 的 Codex、Claude 订阅额度和 Token 用量，显示桌面小组件、切换角色或外观，并与人物互动。用于余量软件本身的操作，不用于 API 账单估算或读取聊天正文。
---

# 余量

优先使用本插件的 `yuliang_status`、`yuliang_refresh`、`yuliang_show_widget`、`yuliang_interact`、`yuliang_select_character`、`yuliang_set_display` 工具。只执行用户要求的操作；查状态不需要修改外观、换角色或连续刷新。

- 额度、Token 使用量、重置时间、采样时间分别解释。未知保持未知，不从重置倒计时推算额度已经恢复。
- `tokenUsage.serverDay` 是服务端标注的统计日期，时区可能未知；不要把旧日期的 `serverDayTokens` 称为今天用量。十进制 Token 字符串避免直接转成可能丢精度的数值。
- 刷新返回 `accepted` 只代表已提交；需要新读数时，稍后查询一次状态。App 已有 60 秒自动采集，不另起轮询或重复触发刷新。
- 换角色前读取 `characters`，使用其中可用的 `id`。`signature` 为当前角色专属动作，`random` 为随机互动。互动不改变真实额度。
- 显示设置仅传用户指定的字段。支持 `layout`: `standard` / `compact` / `duo`，`appearance`: `system` / `light` / `dark`，`language`: `system` / `zh-Hans` / `en` / `ja`。
- 人物界面位于原生桌面卡片。不要声称已经嵌入 Codex 账号栏、系统 WidgetKit 或 iPhone。

工具不可用时，可从此技能目录运行本地备用入口：`node ../../server/cli.mjs status`；其他子命令为 `refresh`、`show`、`interact`、`character`、`display`，第二个参数为 JSON 对象。先解析当前技能所在目录后执行，勿猜测安装绝对路径。遇到未安装 App、连接超时或未连接来源，说明具体状态并停止，不读取凭证或尝试绕过官网登录。

若备用命令返回 `bridge_permission_denied`、`EACCES` 或 `EPERM`，这是本次执行环境的权限限制，不代表 App 未安装。通过当前执行工具，仅为这条余量 CLI 命令请求访问本机连接目录所必需的本机执行权限，再重试；例如工具支持时使用 `sandbox_permissions: "require_escalated"` 并说明本次用途。遵守执行工具的权限审批结果；若工具不提供该权限，清楚说明限制并停止。不要改用其他命令绕过限制，不要更改连接目录的 `700` 权限、放宽全局权限或读取认证文件。

插件只连接本机余量 App 的受限接口，不读取认证文件、浏览器 Cookie、聊天正文，不上传到自建服务。返回给助手的额度摘要会按当前宿主的工具调用流程进入对话；需要分享或公开时，由用户另行指定。
