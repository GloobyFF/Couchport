# 2026-10-22：iOS/iPadOS 适配（含 iPhone Duo）、关于页、开源

## iOS / iPadOS
- `project.yml`：新增 `Couchport-iOS` Target（iPhone + iPad，iOS 26+），和 visionOS Target 共用同一套源码、Bundle ID 和内购。
- `Platform.swift`：所有平台差异都集中在这里，包括玻璃效果、标题字体、最小窗口尺寸、手柄事件路由、全屏播放外观，以及 `LayoutClass`（按实际宽度区分窄屏和宽屏，阈值 600 pt）。
- `PS5VisionCaptureApp.swift`：沉浸式空间仅在 visionOS 上编译；iOS 上只有一个窗口。
- `ImmersiveTheaterView.swift`、`TheaterScene.swift`：整个文件放在 `#if os(visionOS)` 里。
- `ContentView.swift`：iOS 上没有 ornament，控制栏改为浮在视频上方，在安全区内；窄屏只显示图标，并隐藏码率等文字；放不下时可以横向滚动；隐藏“影院”按钮；播放时隐藏状态栏和系统叠加层。
- `HomeView.swift`：窄屏的 hero 改为上图下文，chips 自动换行（`FlowLayout`），主机网格最小宽度改为 260；采集卡区块只在 visionOS 和 iPad 上显示（iPad 的提示是 USB-C 接口，不显示头带插图）；文案按平台变化（“streamed to iPhone/iPad”）。
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
- iOS 上没有触屏虚拟手柄，需要连接蓝牙手柄。
- 局域网自动发现在 iOS 上同样需要 multicast entitlement；没有的话，用“手动输入 IP”配对。
