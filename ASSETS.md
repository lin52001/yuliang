# 素材、来源与许可范围

本仓库采用分开许可：**项目代码与五个原创矢量伙伴为 MIT；四位拟人主题美术为署名、非商业素材，其中蓝鲸少女按 CC BY-NC-SA 4.0 提供并保留双署名。** 根目录 MIT License 不覆盖四位拟人主题图片，也不授予第三方原设定、商标或品牌权利。

## 原创矢量伙伴：MIT

团子猫（`mochiCat`）、奶油兔（`butterBunny`）、薄荷狐（`mintFox`）、芝麻熊（`sesameBear`）与云朵精灵（`cloudSprite`）是为余量编写的原创 SwiftUI 矢量形象，源码位于 `apple/Shared/OriginalBuddy.swift`。这些伙伴及程序绘制的表情、饱腹变化与饼干不依赖第三方角色图集。v0.17.0 可选目录仅保留云朵精灵；团子猫、奶油兔、薄荷狐与芝麻熊仅保留旧偏好解码和历史源码，不再显示于角色选择。

上述原创绘图代码与项目其他代码一并按根目录 [MIT License](LICENSE) 分发。本节所称“原创矢量伙伴”不包括下节四个拟人主题的原设定与重绘美术。

## 四位拟人主题：保留原设定条款

`apple/Resources/original-buddies-v1.png` 是为余量额度条制作的 **AI 辅助重绘改编图集**，依照 [llm-pet](https://github.com/savanna0425/llm-pet) 介绍的拟人设定制作。它不是直接复制上游宠物原图或 `spritesheet.webp`，但保留原设定的署名与使用条件，不因重绘或更换动作就改为 MIT。

图集采用 6 列 × 4 行结构，每一行对应一个主题，每位拥有六个动作/饱腹帧：

| 图集行（从上到下） | ID | 显示名称 | 主题及原设定署名 | 使用条件 |
| --- | --- | --- | --- | --- |
| 1 | `dragonGirl` | 星糖龙娘 | ChatGPT 白发龙角少女；ZipZipPipe | 署名，非商业使用；保留上游使用条件 |
| 2 | `claudeGirl` | 橘光学姐 | Claude 橙发温柔学姐；ZipZipPipe | 署名，非商业使用；保留上游使用条件 |
| 3 | `deepseekGirl` | 蓝鲸少女 | DeepSeek 蓝发鲸系少女；ZipZipPipe、上善 | CC BY-NC-SA 4.0：双署名、非商业、相同方式共享 |
| 4 | `geminiGirl` | 星喵少女 | Gemini 紫蓝星星猫娘；ZipZipPipe | 署名，非商业使用；保留上游使用条件 |

本次改动由余量贡献者制作：使用 AI 辅助重绘，适配六个额度/互动状态并组织为本机图集。应用展示时从随包资源读取，不访问在线图片服务器。图集不使用第三方公司 Logo，也不作为官方角色设定宣传。

### 图集制作记录

- 制作日期：2026-11-03。
- 工具：OpenAI imagegen，AI 辅助插画生成。
- 输出：`apple/Resources/original-buddies-v1.png`，1536 × 1024 像素，RGBA，透明背景；6 列 × 4 行。
- 四行角色依次为白发龙娘、橙发学姐、蓝鲸少女、紫蓝星喵，与上表主题顺序一致。
- 六列动作依次为好奇、稍满足、抱肚饱足、闭眼打盹、害羞招手、鼓腮咀嚼。图集不绘制饼干，饼干由软件单独渲染。

设计提示摘要：制作可供程序切帧的二维动漫 Q 版角色图集，严格采用 6 列 × 4 行、真实透明背景。人物为约两头身的全身女性奇幻角色，采用深梅紫描边与柔和粉彩赛璐璐上色，同一行保持身份、衣着和比例一致，嘴部与脚部基线对齐，服装得体，不绘制界面、文字或 Logo。

English production brief: “Production 2D anime chibi sprite atlas; exact 6 columns by 4 rows; true transparent background; 2-head-tall full-body female fantasy characters; deep plum outlines and pastel cel shading; aligned mouth/feet; no UI/text/logos; consistent identity per row; modest clothes. Six states per row: curious, slightly satisfied, full while holding belly, eyes-closed nap, shy wave, and puffed-cheek chewing. No biscuit artwork; the app renders it separately.”

这份记录说明余量的图集制作与适配过程，不覆盖或解除原设定的署名、非商业和相同方式共享条件。

星糖龙娘、橘光学姐、蓝鲸少女与星喵少女是余量内的显示名称，不替代原设定作者署名。原图的 AI 重绘、裁切、动作适配、改名及制作预览都不解除相关原设定条件。四位主题的新增美术表达也不按根目录 MIT 重新许可；改编和再分享须保留本节对应的署名、非商业与共享方式。

## 来源与上游 NOTICE

主要来源是 Sav 同学的 [savanna0425/llm-pet](https://github.com/savanna0425/llm-pet)。核对日期：2026-11-03。该仓库提供多个模型的标准版与 Q 版；余量本轮只适配上述四个拟人方向，没有捆绑上游全部宠物包。

已核对其 [README](https://github.com/savanna0425/llm-pet/blob/main/README.md) 与 [NOTICE.md](https://github.com/savanna0425/llm-pet/blob/main/NOTICE.md)：

- 拟人原设定作者为 B 站 UP 主 **[ZipZipPipe](https://space.bilibili.com/4168597)**。上游引述其[作品说明](https://www.pixiv.net/artworks/148186519)，要求标注作者、不可商用，并要求分享、修改或使用时保留这些条件。
- **DeepSeek** 形象还基于创作者 **上善** 的鲸鱼设定。上游 [相关视频说明](https://www.bilibili.com/list/4168597?bvid=BV1ggYj6jEMG&oid=117250778471231) 与 NOTICE 指向 **[CC BY-NC-SA 4.0](https://creativecommons.org/licenses/by-nc-sa/4.0/deed.zh-hans)**，需同时注明 ZipZipPipe 与上善；许可完整条款见 [CC BY-NC-SA 4.0 Legal Code](https://creativecommons.org/licenses/by-nc-sa/4.0/legalcode.zh-hans)。
- 上游没有覆盖全部素材的统一开源软件许可证，与模型公司没有官方关联。余量不把“GitHub 可下载”或“代码开源”解释为所有美术可商用。

余量没有下载、捆绑或重新分发该仓库的宠物原图、精灵图集与预览 GIF；本节仍明确承认新图沿用了其介绍的角色设定。项目代码许可不会替代这项改编所需保留的条件。

### 再分享时保留的署名

可以随四主题图集或相关预览附上以下信息，并保留本文件和原始条款链接：

> 拟人原设定：ZipZipPipe。DeepSeek 鲸鱼原设定另来自上善。来源：savanna0425/llm-pet 的 README 与 NOTICE。余量贡献者以 AI 辅助重绘，并适配额度卡片动作。四位主题限非商业使用并保留作者署名；蓝鲸少女（DeepSeek）按 CC BY-NC-SA 4.0 共享，署名 ZipZipPipe 与上善，改编沿用相同许可。以上形象与相关模型公司没有官方关联。

署名链接：

- ZipZipPipe：[B 站个人页](https://space.bilibili.com/4168597)、[作品说明](https://www.pixiv.net/artworks/148186519)。
- 上善鲸鱼设定的来源与条件：[上游 NOTICE](https://github.com/savanna0425/llm-pet/blob/main/NOTICE.md)、[上游相关视频说明](https://www.bilibili.com/list/4168597?bvid=BV1ggYj6jEMG&oid=117250778471231)。
- DeepSeek 改编许可：[CC BY-NC-SA 4.0](https://creativecommons.org/licenses/by-nc-sa/4.0/deed.zh-hans)。

图集作为合集分发时，应同时保留各行的署名与条款。单独裁出一行、拆出某个姿态或制成 PNG/GIF 预览，也应保留对应主题的条件。不得把整张图集或其中拟人美术标为 MIT、CC0 或无条件商用素材。商业使用或超出现有条款的分发需要另行取得相应权利人的明确许可。

## 主题与数据源

四位拟人主题不是模型公司的官方角色，不代表 OpenAI、Anthropic、DeepSeek、Google 或社区作者对余量的认可。选择角色只改变外观与互动，不改变额度来源：选择橘光学姐不会连接 Claude，选择蓝鲸少女不会连接 DeepSeek，选择星喵少女不会连接 Gemini。v0.17.0 可在设置中独立选择 Codex 或 Claude 数据源。Codex 复用官方 CLI 登录；Claude 需要在应用内完成官网登录，Google 等登录可使用独立官网子窗口，返回连接窗口后前往 Settings → Usage，再手动开启 60 秒读取，仅展示可见额度与重置信息。未提供的 Token 不推算；Claude 尚未完成真实账号端到端验收，官网可能限制内嵌浏览器登录。角色主题本身不构成服务连接或官方联名。

## v0.17 新增参考角色：不纳入 MIT 美术许可

公开源码、插件包及公开预览不捆绑下述新增参考图集。本节记录本机适配来源；缺少本机图集时，对应角色使用占位标识，动作代码仍可使用。

`apple/Resources/new-buddies-v017.png` 是用户指定形象的 AI 辅助同人图集，供本机新版体验。代码许可不覆盖原角色、原参考图片或品牌权利，AI 重绘也不代表取得原角色许可。原设定作者及再分发条件尚未核实，不能因本文件随软件提供而认定这些角色已获开源美术授权。

- 上排 `nailong` 奶龙，参考用户提供的 [奶龙海报笔记](https://xhslink.cn/o/1aUz2b8nz8D)。
- 下排 `swordCat` 剑士小猫，参考用户提供的 [小猫剑士笔记](https://xhslink.cn/o/44RipdT4D4O)。
- 实际查看参考日期：2026-11-04。笔记中的照片、海报和截图不作为随包角色图片。
- 工具：OpenAI 内置 imagegen；生成日期：2026-11-04。输出原样复制，无后期艺术修改。
- 输出：2172 × 724，RGBA，真实透明背景；6列 × 2行，每格362 × 362。
- 六列依次为平静、稍饱、满足、饱足困倦、打招呼或敬礼、咀嚼。饼干由软件单独绘制。
- 制作提示摘要：参照两张用户提供的角色图，制作严格6列2行、同一行身份和脚部基线一致的二维动漫Q版透明图集。上排黄色圆肚奶龙，下排持长剑、戴银色护甲的灰虎斑猫，清楚描边、柔和上色、每格保留完整头脚与道具，无背景、UI、文字或水印。
- 角色图片与其预览的原权利仍归对应权利人。公开再分发、商用或宣传联名需根据实际取得的许可处理；本机适配不是官方合作。

七种角色的轨道粒子、剑光弧线、泡泡、星轨、软弹和动作采样为项目代码，与角色美术分别管理。素材来源记录不改变额度采集或用户数据。

## Codex 品牌标识

`apple/Resources/provider-codex.png` 提取自本机已安装的官方 Codex 应用（bundle ID `com.openai.codex`）内 `Contents/Resources/app.icns`，2026-11-04 核对，仅用于额度来源识别。Mac 界面优先使用系统为已安装 Codex 应用返回的实际图标，随包蓝色终端图标仅作未安装时的替补；界面不再用通用六边形代替。OpenAI/Codex 的名称与标识不由本项目 MIT 许可授予，也不表示官方合作或认可。

## 未包含的历史素材

旧私人原型中的第三方角色试作 PNG、身份参考图及其预览不随公开版分发，也不列为 MIT 授权素材。历史角色 ID 仅用于读取既有本地偏好；没有对应个人本机素材时，不请求网络下载，也不把缺图伪装成获授权素材。

## 系统图标与字体

界面使用 Apple 系统字体与 SF Symbols 等系统资源。它们由操作系统提供，不以独立字体文件或图标包在本仓库中重新分发；其使用受 Apple 相应条款约束，不因本项目采用 MIT 而改变。

## 预览图片

仓库演示图片或动图必须使用合成额度，并标明其为演示。不要将真实账号额度、登录界面、私人路径或凭据提交为宣传素材。预览中的角色沿用对应原图的许可范围；含四主题的截图或 GIF 也需保留本文件规定的署名与使用条件。
