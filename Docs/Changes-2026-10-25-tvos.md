# 2026-10-25：Apple TV（tvOS 26）第一阶段移植

目标：新增 `Couchport-tvOS` Target，按代码审读可编译（本机没有 Apple 工具链，**尚未实际编译**）。遥控游玩、Pro 内购、主机配对和串流都走和 iPhone/iPad 相同的代码；采集卡和沉浸式影院在 Apple TV 上不存在。

## 工程

- `project.yml`
  - `options.deploymentTarget` 增加 `tvOS: "26.0"`。
  - 新 Target `Couchport-tvOS`：模板 `CouchportApp`，`platform: tvOS`，`TARGETED_DEVICE_FAMILY = 3`，`ASSETCATALOG_COMPILER_APPICON_NAME = "App Icon & Top Shelf Image"`，`INFOPLIST_FILE = Config/Info-tvOS.plist`。Bundle ID 仍是 `com.glooby.UVCTheater`（通用购买，同一个 Pro）。
  - `WebKit.framework` 从模板移到 visionOS 和 iOS 两个 Target 各自的 `dependencies`（XcodeGen 会把模板和 Target 的数组拼接）。tvOS 没有 WebKit。
  - 模板加了 `CODE_SIGN_ENTITLEMENTS: Config/Couchport.entitlements`（iCloud 键值存储，见下文“主机同步”）。**这会影响三个平台的签名**：Xcode 自动签名会给 App ID 打开 iCloud 能力。等 Apple 批下组播权限后，把 `com.apple.developer.networking.multicast` 加进这个文件（文件里已留注释）。
  - 没有用 `excludes`：不能在 tvOS 上编译的文件已经整体放在 `#if os(iOS)` 里（`TouchController`、`PictureInPicture`、`PhonePlayerStage`、`FloatingControls` 里的悬浮按钮部分），`PSNAccountLogin` 的网页登录放在 `#if canImport(WebKit) && !os(tvOS)` 里，影院相关是 `#if os(visionOS)`。
- `Config/Info-tvOS.plist`：由 `Info.plist` 复制，去掉了方向、状态栏、`UILaunchScreen`（tvOS 不支持）、相机权限说明（tvOS 不用采集卡）；加了 `GCSupportsControllerUserInteraction = YES`（允许用手柄操作界面）和 `UIUserInterfaceStyle = Dark`；单场景。
- `Media.xcassets/App Icon & Top Shelf Image.brandassets`：用现有 AppIcon 图层（背景渐变 + 圆环/沙发/手柄标志）以 PIL 生成的**占位图**：
  - App Icon（小）：400×240 @1x、800×480 @2x，两层（Back 不透明背景、Front 透明标志）。
  - App Icon - App Store：1280×768 @1x，两层。
  - Top Shelf Image：1920×720 @1x、3840×1440 @2x。
  - Top Shelf Image Wide：2320×720 @1x、4640×1440 @2x。
- `Tools/build_libchiaki_visionos.sh`：沿用 ios-cmake 的 `PLATFORM` 变量，新增 `TVOS`（arm64 真机）和 `SIMULATORARM64_TVOS`（arm64 模拟器）切片，并加入 xcframework。说明：ios-cmake 的 `SIMULATOR_TVOS` 只有 x86_64，在 Apple 芯片 Mac 上跑不了模拟器，所以默认用 arm64 版本，和 iOS 的 `SIMULATORARM64` 一致；Intel Mac 可以设 `VP_TVOS_SIM_PLATFORM=SIMULATOR_TVOS`。`VP_SKIP_TVOS=1` 可以跳过 tvOS。

## 平台层（`Platform.swift`）

- `Platform.isTV`；`supportsTheater`、`supportsCapture` 在 tvOS 上都是 `false`；新增 `requiresGameController`（tvOS 为 `true`）。
- `heroHeadline`：“Your PS5, streamed to Apple TV”。`networkTip`：建议 PS5 和 Apple TV 都走有线，或 Apple TV 用 5/6 GHz Wi‑Fi。
- `adaptiveGlass`：tvOS 用 `.thinMaterial`（比 iOS 的 ultraThin 更实，远距离更易读）。`visionMinFrame`：tvOS 不设（tvOS 的 sheet 是全屏）。`immersivePlayerChrome`：tvOS 只 `ignoresSafeArea()`。`streamOwnsGamepad`：tvOS 上什么都不做，改由 `TVGameSurface` 负责（见下文）。
- `LayoutClass`：tvOS 永远是宽布局；页边距 64、分区间距 56。
- 新的跨平台辅助（其它平台行为不变）：
  - `formBackgroundHidden()` = `.scrollContentBackground(.hidden)`（tvOS 没有这个修饰符，Form 本来就透明）。原来所有 `.scrollContentBackground(.hidden)` 都换成了它。
  - `selectableText()` = `.textSelection(.enabled)`（tvOS 没有）。
  - `roundedFieldStyle()` = `.textFieldStyle(.roundedBorder)`（tvOS 没有）。
  - `plainOrCardButtonStyle()`：tvOS 用 `.card`，否则 `.plain`。
  - `borderlessOrBorderedButtonStyle()`：tvOS 用 `.bordered`，否则 `.borderless`。
  - `formRowButtonStyle()`：Form 行里的按钮，tvOS 用默认行样式（有焦点底板），否则 `.plain`。
  - `AdaptiveSlider`：有 `Slider` 的平台就是原来的 `Slider`；tvOS 上是“− 数值 +”两个可聚焦按钮，按步长调节。

## tvOS 不可用 API 的处理

- `Slider`：`SharedControls`（画质调节、影院屏幕）和 `RemoteSettingsSections`（音量、震动强度）改用 `AdaptiveSlider`。
- `.textSelection`、`.scrollContentBackground`、`.roundedBorder`：见上面的辅助函数。
- WebKit：`PSNLoginSheet`/`PSNWebView` 只在非 tvOS 编译；`PSNAccountService`（无 WebKit）仍然全平台。
- MetalFX：`MTLFXSpatialScaler` 要 tvOS 27.1，高于部署目标，所以 tvOS 上不编译，`metalFXSupported` 返回 false，放大走 Lanczos。
- `AudioMonitor`（采集卡音频）：`.defaultToSpeaker` 是 iOS 独有，tvOS 上去掉（tvOS 本来就不用采集卡）。
- `CaptureManager` 用的 AVCapture API 在 tvOS 17+ 都有，照常编译，只是不会被调用。
- 已有的 iOS 专属代码（CoreMotion 手机陀螺仪、`UIDevice` 方向、`UIImpactFeedbackGenerator`、拖动悬浮按钮、PiP、`statusBarHidden`）本来就在 `#if os(iOS)` 里。
- `.onTapGesture` 在 tvOS 播放器上不再使用；`.hoverEffect()` 在 tvOS 上不加（`.card` 样式自带焦点效果）。
- 关于页：tvOS 没有浏览器，“View Source Code”按钮改为直接显示源码地址；许可证全文按段落拆成可聚焦的行，才能在 tvOS 上滚动。

## PSN 登录与主机同步

Apple TV 不能打开索尼的登录网页，所以“添加主机”页在 tvOS 上提供两条路：

1. **iCloud 同步**（新增，此前 `ConsoleStore` 完全不同步：列表在 UserDefaults，密钥在“仅本设备”的钥匙串里）。现在：
   - 主机列表（名称、地址、MAC、添加时间，不含密钥）写入 iCloud 键值存储 `remotePlay.consoles.sync.v1`，有变化时其它设备会收到通知。
   - 配对密钥（registKey、morning）和 PSN 账号 ID 写入 **iCloud 钥匙串**（`kSecAttrSynchronizable`，端到端加密），从不放进键值存储。本机原有的密钥条目不变。
   - 合并规则（保守、只增不改）：
     - 只导入本机没有的主机（按 MAC 识别同一台主机），而且两把密钥都已经同步到了才导入；没到就等下一次同步再试。本机已有主机的名称、地址都不会被覆盖。
     - 发布时把本机主机并入云端列表，不会删掉其它设备发布的条目。
     - “忘记主机”会写一个墓碑（时间戳）：其它设备不再导入、也不再重新发布它，但已经有这台主机的设备会保留自己的副本。重新配对（更新的添加时间）会让它重新同步。墓碑最多保留 100 条。
     - PSN 账号 ID 只在本机还没有时才采用。
   - 触发时机：启动、iCloud 变更通知、App 回到前台（钥匙串可能比列表晚到）。
   - tvOS 的说明文字：在 iPhone、iPad 或 Apple Vision Pro 上配对过的主机和 PSN 账号会通过 iCloud 自动出现，需要在那台设备上用同一个 Apple 账户打开一次 Couchport。
2. **手动输入 PSN 账号 ID（base64）**：沿用已有的 `ConsoleStore.setAccountID(base64:)`，tvOS 上没有账号时直接显示输入框。有了账号 ID 后，可以直接在 Apple TV 上用 8 位 PIN 配对（配对流程本身不依赖 WebKit）。没有发明任何新的 PSN 接口。

## 播放器（tvOS）

- 全屏 `MetalVideoView`（画面按比例缩放），放在 `GCEventViewController` 里（`TVPlayer.swift` 的 `TVGameSurface` / `TVGameViewController`）。没有悬浮按钮、没有拖动。
- **手柄归主机**：串流中、且没有面板、sheet、对话框或提示时，`controllerUserInteractionEnabled = false`，手柄的所有输入只走 GameController（再发给主机），不会移动 tvOS 焦点，按 B/Menu 也不会退出 App。打开面板、sheet、“停止游玩？”、免费时长提示或主机密码框时，自动切回 `true`，可以用手柄或遥控器操作界面。
- **Siri Remote**：在“手柄归主机”状态下，遥控器的按键也只走 GameController，所以 `SiriRemoteCommands` 直接读遥控器的 `buttonMenu` 和 `buttonX`（播放/暂停）。其它状态走 UIKit 的按键事件和 SwiftUI 的 `.onExitCommand` / `.onPlayPauseCommand`。
  - Menu 或播放/暂停：打开控制面板（复用 iPhone 的方块面板 `PlayerControlsPanel`，tvOS 上每个方块是可聚焦的 `.card` 按钮，4 列，尺寸更大）。
  - 面板里按 Menu：关闭面板，回到游戏。
  - 用 Menu 关掉面板后 2 秒内再按 Menu：弹出“停止游玩？”（停止 / 继续游玩）。
  - 面板方块：PS 键、串流设置、画质增强、性能统计、静止模式、停止。没有 PiP、倒影、屏幕手柄。
- **PS 键**：tvOS 把手柄的 Home（PS）键留给系统。所以有“PS Button”方块，另外 `GamepadBridge` 在 tvOS 上把 **同时按住 L3 + R3 约 0.5 秒** 当作 PS 键发送（按住期间不再向主机发送 L3/R3，松开任一键即结束）。面板里第一次会显示提示“Hold L3 + R3 for the PS button”，看过一次后不再显示。
- **没有屏幕手柄**：tvOS 必须用游戏手柄。Home 和播放器在没有手柄时显示“Connect a game controller”提示，附 DualSense / DualShock 4 的配对方法（`ControllerPresence` 监听手柄连接，Siri Remote 不算）。

## Home / 设置 / 购买页

- 按钮改成焦点友好：主机卡片的“…”菜单在 tvOS 上用 bordered；“添加主机”方块用 `.card`；Form 行里的按钮（Pro 提示行、放大选项、关于）用默认行样式；搜索到的主机列表行用 `.card`。页边距、内边距在 tvOS 上更大。
- 购买页：在 Apple TV 上运行时，“Apple TV”标签显示为可用（对勾）；页脚说明在 tvOS 上换成包含 Apple TV 的版本。其它平台的文案不变（Apple TV 仍显示“Coming later”）。

## 手柄反馈（`GamepadBridge`）

- DualSense 震动（`GCDeviceHaptics` + CoreHaptics）、自适应扳机（`GCDualSenseAdaptiveTrigger`）、灯条、手柄陀螺仪（`GCMotion`）在 tvOS 上照常工作，这些 API 在 tvOS 14.5+ 都有。
- 手机陀螺仪（CoreMotion）仍然只在 iOS 上编译。

## 本地化

新增 12 个字符串，7 种语言（简体中文、繁体中文、德、西、法、日、韩）全部翻译；审计 `0 missing of 283`。

## 检查

- `python3 /workspace/work/tools/swift_check.py Sources`：只剩已知误报 `CaptureManager.swift` 126–128 行。
- `python3 /workspace/work/tools/l10n_audit.py .`：`0 missing of 283`。

## 在 Mac 上要做的

```bash
cd PS5
git pull
./Tools/build_libchiaki_visionos.sh   # 重新构建，xcframework 才会有 tvOS 切片（TVOS + SIMULATORARM64_TVOS）
xcodegen generate
open PS5VisionCapture.xcodeproj       # 选择 Couchport-tvOS scheme，目标选 Apple TV 4K 或 tvOS 模拟器
```

- 不重新跑脚本的话，tvOS Target 会因为 xcframework 里没有 tvOS 库而报错。
- 第一次构建时，Xcode 的自动签名会给 App ID 打开 iCloud（键值存储）。如果签名报错，到 Signing & Capabilities 里确认 iCloud → Key-value storage 已勾选。
- App Store Connect：给 tvOS 版本标注“需要游戏控制器”。

## 已知限制和下一步

- **还没有实际编译过**，只按代码审读和 Apple 文档的可用性逐项核对过。第一次在 Xcode 里编译可能还有个别小错误。
- Pylux/chiaki 的 tvOS 构建没有实测过；它的 Apple 移动端 CMake 路径是通用的（visionOS、iOS 都能过），预计 tvOS 也能过，但需要在 Mac 上验证。
- App 图标和顶部栏图片是占位图（用现有图标图层拼的），正式上架前需要设计稿，图标最好做 3 层以上的视差。
- tvOS 没有启动画面（`UILaunchScreen` 不支持），启动时是黑屏；需要的话以后加 Launch Image。
- 只有手柄、手边没有 Siri Remote 时，串流中打不开控制面板（手柄按键全部归主机）。以后可以考虑给手柄加一个打开面板的组合键。
- L3 + R3 组合：按下的前 0.5 秒内 L3/R3 仍会发给主机；同时按 L3 + R3 有功能的游戏可能会受影响。
- iCloud 同步：忘记主机不会删除其它设备上已有的副本；主机改了 IP 不会同步到已经导入它的设备。同一组配对密钥可以在多台设备上使用，但同一时间只能有一个串流。键值存储的同步有延迟（通常几秒到几分钟）。
- 性能统计、画质增强、串流设置在 tvOS 上是全屏 sheet；手柄在 sheet 打开时用于操作界面。
- 源码地址在 Apple TV 上只能显示，不能打开。
