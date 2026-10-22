# 2026-10-22：iOS/iPadOS 适配（含 iPhone Duo）、关于页、开源

## iOS / iPadOS
- `project.yml`：新增 `Couchport-iOS` Target（iPhone + iPad，iOS 26+），和 visionOS Target 共用同一套源码、Bundle ID 和内购。
- `Platform.swift`：所有平台差异都集中在这里，包括玻璃效果、标题字体、最小窗口尺寸、手柄事件路由、全屏播放外观，以及 `LayoutClass`（按实际宽度区分窄屏和宽屏，阈值 600 pt）。
- `PS5VisionCaptureApp.swift`：沉浸式空间仅在 visionOS 上编译；iOS 上只有一个窗口。
- `ImmersiveTheaterView.swift`、`TheaterScene.swift`：整个文件放在 `#if os(visionOS)` 里。
- `ContentView.swift`：iOS 上没有 ornament，控制栏改为浮在视频上方，在安全区内；窄屏只显示图标，并隐藏码率等文字；放不下时可以横向滚动；隐藏“影院”按钮；播放时隐藏状态栏和系统叠加层。
- `HomeView.swift`：窄屏的 hero 改为上图下文，chips 自动换行（`FlowLayout`），主机网格最小宽度改为 260；文案按平台变化（“streamed to iPhone/iPad”）。
- iOS / iPadOS 完全不含采集卡和开发者头带：Home 不显示该区块，启动时不申请相机权限；购买页在所有平台都列出“Developer Strap Capture Card (Vision Pro only)”（Pro 是全平台通用的一次购买）；购买说明里写明一次购买即可在 iPhone、iPad 和 Vision Pro 上解锁。
- `Info.plist`：支持全部方向，`UIRequiresFullScreen = NO`（支持分屏）；版本号改由 `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` 提供；新增 `CouchportSourceURL`。
- `Tools/build_libchiaki_visionos.sh`：新增 iOS 真机（OS64）和 iOS 模拟器（SIMULATORARM64）两个切片；可以用 `VP_SKIP_IOS=1` 只构建 visionOS。

## 关于页（`AboutView.swift`）
- 从 Home 右上角 ⓘ 或底部链接进入。
- 内容：版权、AGPL 声明、无担保声明、AGPL 全文、版本号、源码仓库和本版本对应的 tag、第三方组件和许可证、许可证全文列表、Pro 说明、商标声明。
- 新增 22 个字符串，7 种语言全部翻译，本地化审计 `0 missing of 250`。

## 开源
- `LICENSE`（AGPL-3.0）、`NOTICE.md`、`Docs/Licensing.md`（每次发版的合规检查清单）；`.gitignore` 排除了生成的 `.xcodeproj` 和 `Frameworks/`。

## 未验证（这里没有 Apple 工具链）
- 只做了 Swift 语法树检查，没有真正编译过。iOS Target 第一次编译时可能会有小报错（例如 API 可用性），把报错贴给我即可。
- iPhone Duo 的特殊姿态（像书一样半折、像笔记本一样放在桌上）没有做专门的布局，目前按宽度自适应。
- 局域网自动发现在 iOS 上同样需要 multicast entitlement；没有的话，用“手动输入 IP”配对。

## 屏幕手柄（`RemotePlay/TouchController.swift`）
- 完整 DualSense 布局：L1/L2/R1/R2、十字键（单一触控区，可滑动、可斜向）、△○✕□（只用通用几何图形）、双摇杆（双击摇杆即 L3/R3）、触摸板条（拖动为滑动，轻点为按下）、Create、Options、PS。
- 多指同时操作；按下时可选振动反馈；不透明度可调。
- `GamepadBridge.setVirtual`：屏幕手柄与实体手柄的输入合并发送，两者可以同时使用；实体手柄连上或断开时，`hasPhysicalController` 会自动更新。
- 设置项：Stream Settings › On-Screen Controller（自动 / 始终显示 / 关闭；自动 = 没有实体手柄时才显示），播放时的“More”菜单里也能直接切换。

## iPhone Duo 各种状态（`PhonePlayerStage.swift`）
布局由 `PlayerArrangement.resolve(size:fold:touch:)` 决定，依据只有两个：窗口实际尺寸，以及 iOS 27.1 的 `reservedRegions(kind: .division)` 报告的折痕位置。

| 状态 | 布局 |
|---|---|
| 合上，外屏竖着用（466×678 pt） | 视频在上，手柄面板在下 |
| 合上，外屏横着用 | 全屏视频，半透明手柄浮在上面 |
| 展开，内屏横着用（默认姿势，951×669 pt） | 全屏视频，半透明手柄浮在上面 |
| 展开，内屏竖着用（669×951 pt） | 视频在上，手柄面板在下 |
| 半折，折痕横向（桌面 / 笔记本姿态） | 视频在折痕上方，手柄面板在折痕下方，折痕区域本身不放任何控件 |
| 半折，折痕竖向（像书一样拿） | 全屏视频，手柄分成左右两半各在一侧；中间列（触摸板、PS 等）移到肩键下方，避开折痕 |
| 分屏（两个 App 并排） | 按实际宽高，规则同上 |
| 已连接实体手柄（自动模式） | 只显示视频，居中 |

- 控制栏在 iOS 上移到顶部，不会挡住下方的手柄。
- 播放时屏幕不会自动锁定。
- `project.yml` 只在使用 iOS 27.1–27.4 SDK 时打开 `DUO_SDK` 编译条件；用更早的 Xcode 编译时没有折痕 API，布局只按宽高判断，依然能正常构建。
