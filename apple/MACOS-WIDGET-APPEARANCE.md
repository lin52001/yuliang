# macOS 桌面小组件外观核查与余量适配建议

核查日期：2026-11-04。范围为 macOS Sonoma 14、Sequoia 15、Tahoe 26 与当前本机 macOS 27 Golden Gate。系统行为来源采用 Apple 官方支持、开发者文档与 WWDC；余量实现另据本轮 v0.16.0 代码核对。本机系统设置的只读观察与待验收建议分别记录，不将代码核对或设置观察等同完整实机验收。

## 系统行为与独立外观维度

不能用一组固定浅灰、黑色或降低整个窗口透明度来代表系统小组件。需要分别处理系统深浅外观、桌面是否处于前景，以及小组件自身的样式；macOS 27 的全局 Liquid Glass Clear/Tinted 选项还应与图标和小组件自身的 Clear/Tinted 样式区分。[A1–A7, A17–A18]

| 版本与设置 | 官方确认的行为 | 对余量的意义 |
| --- | --- | --- |
| Sonoma 14：「桌面与程序坞 → 小组件 → Widget style」 | Automatic 在单色与全彩之间自动切换；Monochrome 始终单色；Full-colour 始终全彩。Apple 的 Sonoma 发布说明明确描述：前景更彩色，使用其他内容时融入背景，并根据后方颜色调整染色。[A1, A4] | 自动淡化与浅色/深色是不同状态；退到背景不等于切到深色模式。 |
| Sequoia 15：同一设置的版本化指南 | 仍为 Automatic、Monochrome、Full-colour。[A2] | 保持 Sonoma 的淡化策略模型，不将 Tahoe 的新控制项强加到旧版本。 |
| Tahoe 26：「桌面与程序坞 → 小组件 → Dim widgets on desktop」 | Automatically 自动切换单色与全彩；Always 始终单色；Never 始终全彩。[A3] | 设置名称变化，不能把 Never 理解为关闭深色模式。 |
| Tahoe 26：「外观 → Icon & widget style」 | 另有 Default、Dark、Clear、Tinted；部分选项可选 Always/Auto 或 Light/Dark/Auto。它与系统整体 Appearance 及桌面淡化分别存在。[A5] | 即使系统处于 Dark，用户的小组件也可能使用其他样式。只读整体深色状态不足以完整同步系统组件。 |
| Golden Gate 27：「桌面与程序坞 → 小组件 → Dim widgets on desktop」 | 仍为 Automatically、Always、Never，分别自动在单色与全彩间切换、始终单色、始终全彩。指南版本菜单明确列出 macOS 27 Golden Gate。[A17] | 当前系统不能沿用「只核查到 Tahoe」的结论，但桌面淡化仍应与深浅外观独立。 |
| Golden Gate 27：「外观」 | Icon & widget style 仍有 Default、Dark、Clear、Tinted，另有 Liquid Glass 外观的 Clear/Tinted 控制；「Allow wallpaper tinting in windows」也单列。[A18] | 原生窗口材质、全局玻璃外观与系统小组件主题不是同一开关，独立面板不能仅凭深色状态推定其余设置。 |

Apple WWDC23 将桌面行为描述为：小组件以全彩出现在桌面，其他窗口得到焦点后退入背景。[A6] WWDC25 进一步确认 Tahoe 的桌面与通知中心支持玻璃及染色外观：WidgetKit 先以 `accented` 模式生成内容，再由系统替换背景并施加主题效果。[A7]

WidgetKit 公开定义的渲染模式分别是 `fullColor`、`vibrant`、`accented`。`vibrant` 会去饱和并根据背景着色；`accented` 将前景分组后施加颜色。因此「单色」也不是简单把每个像素改成同一个灰色。[A8] 对角色图片，Apple 建议通过适合模式的去饱和呈现保留细节；把不透明人物图直接当白色模板可能变成无细节的轮廓。[A9]

## 桌面焦点、台前调度与可见性

Apple 的版本化指南分别提供「On Desktop」与「In Stage Manager」可见性开关；关闭后者时，桌面项目会隐藏，可点击桌面临时显示。点击壁纸显示桌面还受「Click wallpaper to reveal desktop」设置影响，可配置为 Only in Stage Manager。当前 macOS 27 指南仍保留这些控制项。[A1–A3, A17]

据此，余量应把下列状态分别建模，而不是用单个 `isKeyWindow` 包办：

- 是否允许显示桌面卡片，以及卡片实际上是否可见。
- 当前渲染采用全彩或淡化外观。
- 鼠标、右键菜单、设置面板或角色互动是否正在使用中。
- 当前是普通桌面、其他 Space、全屏应用或台前调度情境。

这些是余量的实现建议。系统小组件的可见性设置面向系统宿主，不应宣称会自动控制独立 `NSPanel`。同样，Finder 在最前方也可能只是打开了 Finder 文件窗口，不能把 `com.apple.finder` 等同于桌面获得焦点。

可将 `NSWorkspace.frontmostApplication`、`didActivateApplicationNotification` 与 `activeSpaceDidChangeNotification` 作为公开的活动变化信号，加上本应用的悬停、菜单和可见状态推导近似策略。[A14] 这仍是余量自己的近似判断；本次官方资料核查未发现向普通独立面板提供 WidgetKit 宿主完整「桌面淡化状态」或全部样式选择的公开同步接口。

## NSVisualEffectView 能做到什么

| 公开能力 | 适合用途与边界 |
| --- | --- |
| `NSVisualEffectView.Material` | 使用语义材质；`.popover` 的官方用途是弹出窗口背景，`.underWindowBackground` 是窗口背景下方区域。二者都是可对照的候选材质，没有任何一个在文档中被定义为「桌面小组件材质」。不使用已废弃的 `.light`、`.dark` 等固定外观枚举。[A10] |
| `.behindWindow` / `.withinWindow` | 前者融合并模糊窗口后方的桌面或其他窗口；后者只处理当前窗口内视图后方内容。若目标是桌面融合，优先对照 `.behindWindow` 的结果，而不是仅叠加一层半透明白色。[A11] |
| `.followsWindowActiveState` | 只依据承载窗口的 active/inactive 状态选择效果；`.active` 与 `.inactive` 可固定效果状态。这不等于系统桌面小组件的前景/背景判定，尤其不能假设不激活的面板会像普通窗口获得焦点。[A12] |
| 辅助功能与语义颜色 | 开启减少透明度时应使用不透明背景；监听其变化。正文使用 `labelColor`、辅助文字使用 `secondaryLabelColor` 等系统语义颜色，避免硬编码某版系统的 RGB。[A13, A15] |

建议在固定尺寸卡片中使用一个系统语义材质底层，再让 SwiftUI 内容透明地叠在上方。不要同时盖上大面积不透明底色，使真实材质完全失效；也不要对整张卡片降低 `alpha` 或加模糊，导致百分比和文字再次无法辨认。材质选择必须在实际壁纸和系统设置下比较，不能把任何一个材质枚举名称当作相同像素的保证。

`NSPanel` 的材质只提供窗口材料能力，不会把该窗口注册为系统桌面小组件。WidgetKit 的 `widgetRenderingMode`、可移除 `containerBackground` 及宿主主题合成属于 WidgetKit 的呈现路径。[A7–A9] 本次核查没有找到公开的逐像素合成配方。独立版应承诺跟随系统外观、适应壁纸与近似淡化，不能承诺完全复刻系统宿主未公开的渲染细节、Tahoe/Golden Gate 的全部 Clear/Tinted 选择或台前调度行为。

## 本轮 v0.16.0 的实际实现

代码核对范围为 `apple/MacStandalone/YuliangStandaloneApp.swift` 及本轮前台应用状态集成。以下是余量自身行为，不是系统组件完整状态的镜像：

- 两种桌面卡片采用 `NSVisualEffectView.Material.underWindowBackground`，配合 `.behindWindow`，让原生材料融合后方内容。由计算出的桌面强调状态驱动 `.active`/`.inactive`，不依赖非激活 `NSPanel` 成为 key window。
- 深浅外观继续独立支持跟随系统、浅色、深色。外观页新增「自动 · 后台淡为单色」「始终全彩」「始终单色」。自动模式根据前台应用近似判断：Finder 或余量前台时全彩，其他应用前台时单色；Finder 文件窗口也会被归为全彩。这不是精确识别桌面焦点。
- 当前不能自动读取系统 Icon & widget style 的 Clear/Tinted 具体选择，也不将应用自己的色彩选项与系统设置双向同步。不能凭原生材质推定所有 Liquid Glass 和系统组件主题已经一并适配。
- 桌面标题右侧常驻锁定、收起和设置按钮已隐藏。卡片右键或 Control-click 打开稳定设置面板；人物区域保留动作面板。菜单栏弹出卡保留设置和显示桌面入口，供锁定、隐藏后的恢复使用。

本机只读核对记录：`sw_vers` 返回 macOS 27.0、build 26A428；系统设置为深色、「调暗桌面小组件：自动」、「图标与小组件样式：默认」、「基于墙纸颜色调整窗口背景色调：开启」。通知中心中的系统电池组件在观察时呈灰色。此记录不包含设备名称或用户截图，也不将通知中心的单次观察外推为所有桌面焦点状态。未为本次检查改动系统设置。

## 适合余量的具体方案

以下属于实现建议，不是 Apple API 直接提供的余量功能：

1. 默认继承有效系统外观，保留用户明确选择浅色、深色的覆盖选项；自绘颜色在有效外观改变时重新解析，不缓存一次解析的固定 RGB。[A15, A16]
2. 沿用已实现的「自动 · 后台淡为单色 / 始终全彩 / 始终单色」。自动采用公开信号的近似状态，菜单或互动期间保持文字清晰；不宣称该选项已与系统同名偏好双向同步。若无法可靠判断桌面焦点，优先保证信息可读并允许用户手动选择。
3. 淡化只减少角色与轨道装饰的饱和度、彩色面积及阴影强调，保留正文对比、轨道边界和数字。全彩与单色共用真实额度、人物位置与同一个状态模型，外观过渡不触发读取或饼干事件。
4. 已隐藏右上角常驻锁定、收起和设置按钮。保持卡片 Control-click/右键进入稳定设置面板，人物右键进入动作面板，不互相吞掉事件；锁定、收起、恢复和置顶继续在设置中管理。系统自身也用 Control-click 进入组件编辑、尺寸和移除操作，可作为此入口习惯的依据。[A1–A3, A17]
5. 保留菜单栏中的设置与解锁入口供键盘、触控及辅助功能使用；常驻图标隐藏后，不把唯一恢复入口埋在已隐藏或锁定的组件中。原生菜单打开时不由每秒状态发布重建并关闭；沿用现有稳定设置面板。
6. 保留对 Sonoma/Sequoia 的语义材质与深浅兼容；Tahoe/Golden Gate 的 Clear/Tinted 若要独立版模拟，必须明确为应用自身样式并逐项验收。若以后需要系统样式完全由 macOS 管理，应单独交付 WidgetKit 扩展；不要将独立浮窗命名为系统 WidgetKit 安装方式。

验收时在同一块屏幕、同一壁纸区域，将余量与系统电池或天气组件并排比较：系统浅色/深色/自动、桌面与其他窗口聚焦、各版本单色/全彩选项、Tahoe/Golden Gate 的 Default/Dark/Clear/Tinted、Liquid Glass 选择、台前调度开关与显示组件开关、浅色及深色壁纸、减少透明度和增强对比度。测试卡片右键、人物右键、锁定后解锁、设置连续操作、Space 切换与系统外观动态变化。此表是后续完整实机验收清单，不把上方本机设置核对当作全表已经通过。

## Apple 官方出处

以下链接均于 2026-11-04 核查。版本化支持页按 URL 固定到目标系统，避免默认页面随新版系统改变；没有明确发布日期的 API 文档只记核查日期。

| 编号 | 官方资料与日期 | URL |
| --- | --- | --- |
| A1 | Mac User Guide，Sonoma 14 版本 | <https://support.apple.com/en-gb/guide/mac-help/mchl52be5da5/14.0/mac/14.0> |
| A2 | Mac User Guide，Sequoia 15 版本 | <https://support.apple.com/en-gb/guide/mac-help/mchl52be5da5/15.0/mac/15.0> |
| A3 | Mac User Guide，Tahoe 26 版本 | <https://support.apple.com/en-gb/guide/mac-help/mchl52be5da5/26/mac/26> |
| A4 | macOS Sonoma New Features，文档标示 December 2023；另参 2023-09-26 正式发布说明 | <https://images.apple.com/macos/sonoma/pdf/macOS_All_New_Features.PDF>；<https://www.apple.com/newsroom/2023/09/macos-sonoma-is-available-today/> |
| A5 | Change Appearance settings on Mac，Tahoe 26 版本 | <https://support.apple.com/en-gb/guide/mac-help/mchlp1225/26/mac/26> |
| A6 | Platforms State of the Union，WWDC23（2023），桌面焦点行为 | <https://developer.apple.com/videos/play/wwdc2023/102/> |
| A7 | What's new in widgets，WWDC25（2025），约 1:03 起新外观章节 | <https://developer.apple.com/videos/play/wwdc2025/278/> |
| A8 | Preparing widgets for additional platforms, contexts, and appearances | <https://developer.apple.com/documentation/widgetkit/preparing-widgets-for-additional-contexts-and-appearances> |
| A9 | Optimizing your widget for accented rendering mode and Liquid Glass | <https://developer.apple.com/documentation/widgetkit/optimizing-your-widget-for-accented-rendering-mode-and-liquid-glass> |
| A10 | NSVisualEffectView.Material | <https://developer.apple.com/documentation/appkit/nsvisualeffectview/material-swift.enum> |
| A11 | NSVisualEffectView.BlendingMode | <https://developer.apple.com/documentation/appkit/nsvisualeffectview/blendingmode-swift.enum> |
| A12 | NSVisualEffectView.State | <https://developer.apple.com/documentation/appkit/nsvisualeffectview/state-swift.enum> |
| A13 | accessibilityDisplayShouldReduceTransparency | <https://developer.apple.com/documentation/appkit/nsworkspace/accessibilitydisplayshouldreducetransparency> |
| A14 | NSWorkspace 活动应用、激活通知与 Space 变化通知 | <https://developer.apple.com/documentation/appkit/nsworkspace/frontmostapplication>；<https://developer.apple.com/documentation/appkit/nsworkspace/didactivateapplicationnotification>；<https://developer.apple.com/documentation/appkit/nsworkspace/activespacedidchangenotification> |
| A15 | Human Interface Guidelines：Color，页面变更记录含 2025-12-16 | <https://developer.apple.com/design/human-interface-guidelines/color> |
| A16 | NSView.viewDidChangeEffectiveAppearance | <https://developer.apple.com/documentation/appkit/nsview/viewdidchangeeffectiveappearance()> |
| A17 | Mac User Guide，macOS 27 Golden Gate 版本 | <https://support.apple.com/en-gb/guide/mac-help/mchl52be5da5/27/mac/27> |
| A18 | Change Appearance settings on Mac，macOS 27 Golden Gate 版本 | <https://support.apple.com/en-in/guide/mac-help/mchlp1225/27/mac/27> |
