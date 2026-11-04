# 紧凑进度条与角色陪伴参考

核对日期：2026-11-04。核对方式：项目官方 GitHub 源码、许可证文件及作者文档。以下记录设计参考；没有复制第三方实现、下载角色素材或新增依赖。

## 1. NyanProgressBar：角色就是进度端点

- 项目：<https://github.com/batya239/NyanProgressBar>
- 实现：[`src/NyanProgressBarUi.java`](https://github.com/batya239/NyanProgressBar/blob/34d16dcdc125a4395b76ce9bd31f1fdf57bc1a6d/src/NyanProgressBarUi.java)，主要看 `paintDeterminate` 与 `paintIndeterminate`。
- 已核对行为：有确定进度时，猫的位置与填充长度来自同一进度；无确定进度时，角色另用往返动画。
- 余量可借鉴：把角色与连续轨道做成一个整体，在真实额度变化时一起移动。余量的未知状态仍应保持未知，不能套用往返动画冒充额度变化。
- 授权：仓库未找到 `LICENSE`，GitHub 仓库元数据的 `license` 为 `null`。仅作交互概念参考，不复用其代码、猫图或彩虹素材；不能因源码可见就视为有开源再分发授权。

## 2. VS Code Pets：闲置时也有生命感

- 项目：<https://github.com/tonybaloney/vscode-pets>
- 作者使用文档：<https://tonybaloney.github.io/vscode-pets/pets/>
- 实现：[`src/panel/states.ts`](https://github.com/tonybaloney/vscode-pets/blob/15f13bc96cb8bade1aff2d49e363cd332b18536b/src/panel/states.ts)、[`src/panel/basepettype.ts`](https://github.com/tonybaloney/vscode-pets/blob/15f13bc96cb8bade1aff2d49e363cd332b18536b/src/panel/basepettype.ts)、[`src/panel/pets/cat.ts`](https://github.com/tonybaloney/vscode-pets/blob/15f13bc96cb8bade1aff2d49e363cd332b18536b/src/panel/pets/cat.ts)。
- 已核对行为：角色用状态与驻留时间切换动作；可对鼠标回应、短时显示气泡、追球；角色可有不同动作路径。
- 余量可借鉴：把主动陪伴与点击反馈分开；用低频自主动作、可打断的短反馈和角色性格差异增加生命感。小组件内保留人物的额度锚点，不引入满屏追逐。
- 授权：项目代码 [`LICENSE`](https://github.com/tonybaloney/vscode-pets/blob/15f13bc96cb8bade1aff2d49e363cd332b18536b/LICENSE) 为 MIT，版权署名 Anthony Shaw。README 对猫、狗等美术另列作者来源，因此不能把代码 MIT 自动理解为全部角色素材均可随意复用。本轮没有使用其代码或素材。

## 3. CodexBar：真实读数仍然是一等信息

- 项目：<https://github.com/steipete/CodexBar>
- 实现：[`Sources/CodexBar/Menu/UsageProgressBar.swift`](https://github.com/steipete/CodexBar/blob/897bff31731bb4b21b105f6e8bf4c32a8a8bf095/Sources/CodexBar/Menu/UsageProgressBar.swift)、[`docs/ui.md`](https://github.com/steipete/CodexBar/blob/897bff31731bb4b21b105f6e8bf4c32a8a8bf095/docs/ui.md)。
- 已核对行为：小进度条把填充、标记和辅助功能读数分开定义；界面区分来源额度、Token/花费以及陈旧和缺失数据，刷新时保持行几何稳定。
- 余量可借鉴：百分比始终清晰；刻度只表达尺度，装饰不能形成第二条假进度；刷新、失败与关怀文案共用已预留位置，不把窗口撑大。
- 授权：项目 [`LICENSE`](https://github.com/steipete/CodexBar/blob/897bff31731bb4b21b105f6e8bf4c32a8a8bf095/LICENSE) 为 MIT，版权署名 Peter Steinberger。本轮没有使用其实现、图标、采集器或登录方式；只借鉴界面组织原则。

## 对 344 × 160 pt 紧凑版的设计建议

下列为余量自己的设计取舍，并非上述项目已实现的功能：

1. 保留既有外框、数字和角色尺寸。沿用 `QuotaRailGeometry` 的同一可见百分比计算填充和角色锚点，最小和最大值不超边界。
2. 把现有 12 pt 纯色条变为细腻的玻璃糖纸轨道：主题色深浅过渡、一道内高光、少量尺度刻线。深色模式使用语义底色与更清楚的边缘，不依赖白色发光糊成一片。
3. 趣味性集中在角色附近。点按轨道可激起一小圈星屑、让角色探头或挥手；鼠标靠近只给局部轻反馈。不要把整条做成滑块，不把点击位置存成额度。
4. 自主动作短而稀疏。打哈欠、伸懒腰、探头和撒娇可低频轮换；手动互动或真实额度反馈优先。休眠、隐藏、静默或减少动态效果时暂停，不补播错过的事件。
5. 关怀使用已有底部单行位置，短句例如「我在这里陪你」「肩膀放松一下呀」。按本地可见会话时长提醒休息，不声称知道用户情绪、任务进度或聊天内容。
6. 装饰动画不能暗示真实用量持续减少。额度只有收到新的有效来源快照后才改变；未知、陈旧和错误状态仍保留清晰文字。按下互动不改变额度和 Token 统计。

## 验收重点

- 0%、低于 1%、25%、50%、99%、100% 以及未知/陈旧状态均不裁切；文字在明暗外观下可读。
- 角色与填充在额度过渡中使用同一个插值；点击、闲置和关怀动作不改变锚点。
- 快速连续点击、切换角色/来源、打开设置与休眠恢复不排队补播，也不重复启动计时器。
- 减少动态效果与静默关闭自主动作；固定尺寸、窗口拖动及菜单选择寿命不回退。
