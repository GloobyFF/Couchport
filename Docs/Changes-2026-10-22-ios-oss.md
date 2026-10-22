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
| 半折，折痕横向（桌面 / 笔记本姿态） | 视频贴着折痕放在上半屏；下半屏显示画面倒影，上面叠加内容按连接的手柄决定：没连实体手柄时叠整套屏幕手柄；连的手柄没有触摸板时，在底部叠一块紧凑触摸板；连的是 DualSense 时只显示倒影；折痕区域本身不放任何控件 |
| 半折，折痕竖向（像书一样拿） | 全屏视频，手柄分成左右两半各在一侧；中间列（触摸板、PS 等）移到肩键下方，避开折痕 |
| 分屏（两个 App 并排） | 按实际宽高，规则同上 |
| 已连接 DualSense（自动模式，非桌面姿态） | 只显示视频，居中 |
| 已连接没有触摸板的手柄（自动模式） | 竖屏时下方显示大触摸板；横屏时底部显示一条触摸板 |

- 控制栏在 iOS 上移到顶部，不会挡住下方的手柄。
- 播放时屏幕不会自动锁定。
- `project.yml` 只在使用 iOS 27.1–27.4 SDK 时打开 `DUO_SDK` 编译条件；用更早的 Xcode 编译时没有折痕 API，布局只按宽高判断，依然能正常构建。

## 按键交换（参考 Pylux 的 Swap Cross/Moon 设置）
- Stream Settings › Controller 新增两项：“Swap ✕ and ○ (Confirm / Cancel)”、“Swap □ and △”。
- 只作用于实体手柄（`GamepadBridge.output` 中交换 bit 0/1、2/3），切换后立即生效；屏幕手柄不会交换，保证屏幕上显示的按键就是实际发送的按键。
- 自己实现，未复制 Pylux 代码。

## 画中画、手机陀螺仪、仅触摸板、桌面倒影（2026-10-22 晚）
- **画中画**（`PictureInPicture.swift`）：在 Metal 视图下方放一个 `AVSampleBufferDisplayLayer`，解码后的每一帧会同时包装后送进去（不复制像素）。离开 App 时自动进入画中画，也可以从“More”菜单手动打开。App 进入后台后，Metal 视图暂停呈现（`presentationEnabled`），避免 `nextDrawable` 阻塞。Info.plist 新增 `UIBackgroundModes = audio`，这是画中画的必要条件。
  - 需要在真机上确认：后台时 VideoToolbox 硬解是否会被系统中断。如果出现 -12903（`kVTInvalidSessionErr`），需要让解码器重建会话。
- **手机陀螺仪**：手柄没有陀螺仪，或者没连手柄只用屏幕手柄时，改用 `CMMotionManager` 的数据（100 Hz）。坐标按当前界面方向换算到 PlayStation 坐标系：屏幕右方 = +X，屏幕法线 = +Y，屏幕上方 = −Z。只在串流期间运行。
- **仅触摸板**：触控模式新增“Touchpad Only”。在“自动”模式下，如果连的手柄没有触摸板（比如 Xbox 手柄、8BitDo），会自动只显示触摸板。
- **桌面倒影**（iPhone Duo）：系统没有提供这个效果的 API，是我们自己画的。渲染器新增第二路输出 `attachMirror`，每帧多一次 blit；画面上下翻转后，叠一层 `ultraThinMaterial` 模糊，再加渐隐遮罩。在 Xcode 27.1 下，倒影强度会随 `onHingeChange` 报告的折叠角度变化（约 120° 最强，接近 170° 时淡出）。铰链角度只用于这个效果，不参与布局判断。
  - `onHingeChange` / `DeviceHingeContext.hinge.angle` 的写法参考的是第三方整理的资料，需要用 Xcode 27.1 编译确认。
- 新增设置项：Stream Settings › iPhone & iPad › Picture in Picture、Phone Motion (Gyro)、Tabletop Reflection。
- 以上都是自己实现，没有复制 Pylux 的代码。

## 修正（2026-10-22 20:10）
- 桌面姿态的下半屏改为和其他姿态同一套规则，不再“只要连了手柄就显示大触摸板”。触摸板缩成紧凑尺寸（最大 520×240 pt，放在底部），给倒影留出空间。
- 判断手柄时排除键盘、鼠标和遥控器，避免模拟器或 Mac 外设被当成实体手柄，把屏幕手柄隐藏掉。
- 播放器的 More 菜单新增“桌面倒影”快捷开关，并显示“检测到的手柄：…”，方便排查自动模式为什么这样显示。

## 水面倒影（2026-10-22 20:20）
- 倒影改为在 Metal 着色器 `waterReflection`（Shaders.metal）里直接渲染：画面翻转，叠加环境水波（离折痕越远起伏越大），并且越远越模糊，最后渐隐到 Brand.night 水色。触摸下半屏（包括按手柄按键）会从触点荡开一圈水纹，最多同时 6 圈，3 秒内消散。
- 按视图分辨率的一半渲染，每帧只多一次很小的计算；去掉了原来的 SwiftUI 材质模糊和遮罩。关掉倒影后完全不渲染。
- 新增设置项“Water Ripples”：关掉后就是静止的镜面倒影。
- 参数用 10 个 float4 传给着色器（`WaterParams`），Swift 侧按同样的顺序填充，避免结构体对齐问题。

## iOS 悬浮控制按钮（2026-10-22 20:50）
- 在 iPhone、iPad 和 iPhone Duo 上，所有姿态都去掉了顶部的弹出控制条（桌面姿态的贴边控制条也删了），改成一个可以拖动的悬浮按钮（FloatingControls.swift）。按钮直径 54pt，松手后会吸附到最近的左右边缘；位置保存在 `rp.fab.x`/`rp.fab.y` 里，按比例记录，所以转屏或折叠后位置仍然合适。免费时段时，按钮右上角会显示剩余时间。
- 点按钮会打开一个面板，按 3 列排列大尺寸带文字的按钮：PS 键、串流、画质增强、性能统计、画中画、倒影开关、水波纹开关、休眠，下面是屏幕手柄的分段选择、检测到的手柄，最后是“停止”大按钮。点面板外的暗色区域就会关闭。
- visionOS 不受影响，仍然用 ornament 控制条。
- 修复 20:58：Duo 桌面姿态下，下半屏手柄面板顶部的肩键被挡住了。原因是面板的尺寸单位按 高度/5.2 计算，实际内容大约 7.5 个单位高，超出了可用高度。现在改为 高度/7.6，最小值 28。
- 弹出的设置面板改成纯系统 Liquid Glass（`glassEffect(.regular)`），带细描边，强制深色，不再使用 brandPanel 的底纹。悬浮按钮改成我们自己的圆形 AppMark 图标。
- 吸附规则：从只吸附左右两边，改为吸附到最近的四条边之一（上、下、左、右），因此也可以停在顶部中央。

## 竖屏布局：所有 iPhone 和 iPad（2026-10-22 21:15）
- 竖屏（高度大于宽度的 1.1 倍）的规则不再只适用于桌面姿态：画面放在最上面，紧贴安全区顶部（灵动岛、刘海、状态栏）下方，宽度铺满屏幕，最高占 55%；画面下方一直到屏幕底部都是水面倒影。如果显示屏幕手柄或触摸板，会叠在倒影上，规则和以前一样。即使连着 DualSense，竖屏也会显示倒影；只有倒影开关关掉、而且不需要显示屏幕控件时，才回到画面居中。
- 竖屏下倒影始终是满强度，只有桌面姿态才根据铰链角度变淡。点按倒影区域会产生水纹。
- 实现方式：`PlayerArrangement.stacked` 增加了 `videoTop` 参数；PhonePlayerStage 外层用一个 GeometryReader 读取安全区顶部高度。
- 设置项“Tabletop Reflection”改名为“Reflection”（倒影），7 种语言都已更新；设置页脚注说明倒影在竖屏和桌面姿态下都有效。

## 免费时长改为每天 10 分钟（2026-10-22 21:25）
- 原来是“每次 10 分钟”，改为每个自然日（本机时区）一共 10 分钟，所有会话共用。只有实际串流的时间计入，连接、唤醒、重连不算。
- 已用时长存在 UserDefaults 里（`free.day`、`free.usedSeconds`），过了零点自动清零。当天额度用完后，点“开始游玩”会直接弹出付费页（timeUp），不会再连接。最后一分钟的提醒每天只出现一次。
- 删除 App 后重装会清零额度（这一点可以接受；以后可以改存 iCloud 键值存储或钥匙串）。
- 相关文案已改成“每天”，7 种语言都已更新。
- 修复 21:30：竖屏的顶部避让高度改为从 key window 读取安全区（播放器在更上层忽略了安全区，导致 GeometryReader 读到的是 0）。手柄面板的尺寸单位改为宽度/9.6，避免在窄屏 iPhone 上超出屏幕。触摸水纹的强度减半（默认 amplitude 改为 0.5）。
- 修复 21:40：横屏的叠加手柄单位改为短边/7.6（最小 30），之前在 iPhone 横屏时按键会超出屏幕。触摸水纹改成只在触点附近出现：扩散半径约为宽度的 0.12，扩散更慢，大约 1.6 秒后消失。
- 22:15 波纹整体加强：环境水波的幅度提高约 70%，起伏也更快；触摸水纹的扭曲幅度从 0.018 提高到 0.03，高光从 0.25 提高到 0.4，强度从 0.5 提高到 0.75，扩散半径从 0.12 加大到 0.16，持续时间从 1.6 秒延长到 2 秒。
- 22:18 按用户要求，环境水波恢复到原来的幅度和速度，只保留触摸水纹的加强。
- 22:20 修复 PiP 的 tearDown 在视图更新过程中直接改 @Published 属性的问题（警告：Publishing changes from within view updates）。现在改为延后到下一轮主线程再发布，并且只在值真的变化时才发布。
