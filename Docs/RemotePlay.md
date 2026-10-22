# Remote Play 模式（第一阶段：基于 chiaki-ng）

目标：不插开发者头带、通过 Wi‑Fi 玩 PS5，并且**有声音**。与 UVC 采集卡模式共用同一套 Metal 渲染、画质增强和沉浸式影院。

## 架构

```text
PS5 ──Wi‑Fi/LAN──► libchiaki（C，AGPL）
                    │  被 ChiakiShim/vp_chiaki.c 包成不透明 C API（vp_chiaki.h）
                    ▼
RemotePlayBridge.swift   RemoteSessionCore / RegistrationTask / DiscoveryWatcher
                    │
RemotePlayManager.swift  唤醒 → 连接 → 状态、统计、PIN、震动
   ├─ StreamVideoDecoder  Annex‑B → VideoToolbox 硬解 → NV12 CVPixelBuffer
   │                         └─► MetalVideoRenderer.enqueue(pixelBuffer:)（与采集卡同一管线）
   ├─ StreamAudioPlayer   Opus 已在库内解码 → PCM → 40 ms 抖动缓冲 → AVAudioEngine
   └─ GamepadBridge       GameController（DualSense 等）→ PS 按键映射；主机震动 → CoreHaptics
```

关键约定：**App 代码永远不 include chiaki 头文件、不碰 chiaki 结构体。**
`vp_chiaki.c` 被编进 chiaki 静态库内部，结构体偏移与库的编译开关（mbedTLS 等）一致。
Pylux 踩过的坑：Xcode 侧直接调用 `chiaki_session_set_*` 这类 `static inline` 函数会写错偏移，导致回调静默失效。

第二阶段（净室重写）只需用自己的实现重新提供 `vp_chiaki.h` 这套 API，上层 Swift 不用改。

## 构建

1. Mac 上安装依赖：`brew install cmake ninja protobuf python3 xcodegen`
2. 编译 visionOS 版协议库（真机 + 模拟器，首次约 5–10 分钟）：
   ```sh
   ./Tools/build_libchiaki_visionos.sh
   ```
   产物：`Frameworks/VPChiaki.xcframework`（Swift 里 `import VPChiaki`）。
3. 生成并打开工程：
   ```sh
   xcodegen generate && open PS5VisionCapture.xcodeproj
   ```
4. 只想编译采集卡版：删掉 `project.yml` 里 `VPChiaki.xcframework` 那两行，代码会自动走桩实现（`#if canImport(VPChiaki)`）。

## 首次配对

1. PS5：设置 › 系统 › 遥控游玩 › 打开「启用遥控游玩」。
2. PS5：设置 › 系统 › 节能 › 待机模式中可用的功能 › 打开「保持连接到互联网」和「允许通过网络开启 PS5」（用于远程唤醒）。
3. App 主页 › 遥控游玩 › 添加主机：
   - 用 PSN 登录（取账号 ID，只保存 ID）或手动粘贴 base64 账号 ID；
   - 填 PS5 的 IP（设置 › 网络 › 连接状态）；
   - PS5 上打开 设置 › 系统 › 遥控游玩 › 链接设备，输入 8 位 PIN，点「配对」。
4. 主页的主机卡片显示 就绪 / 待机 / 离线；待机时点「唤醒并游玩」。

## 已知限制 / 待验证（需要真机）

- 本工程在 Linux 上编写，`vp_chiaki.c` 已对照 chiaki-ng 头文件编译通过；Swift 部分和构建脚本**尚未在 Xcode / visionOS 上编译验证**，首次编译可能需要小修。
- visionOS 下 CMake：脚本用 ios-cmake `PLATFORM=VISIONOS`，并让 Pylux 的 `CHIAKI_ENABLE_IOS` 路径生效。若库里某些 `TARGET_OS_IOS` 条件在 visionOS 上不成立，需要补 `TARGET_OS_VISION`。
- 局域网自动搜索需要 `com.apple.developer.networking.multicast`（向苹果申请，见 `Config/Multicast.entitlements`）；手动填 IP 不需要。
- HDR（H.265 HDR）暂未开启：渲染器目前只吃 8 位 NV12。
- 外网（PSN 打洞）暂未接入，只支持同一局域网。
- 手柄 PS 键可能被系统占用，界面上有「PS」按钮代替。
- 音画各自走时钟，抖动缓冲上限 120 ms，正常不会明显不同步。

## 许可证

chiaki-ng / Pylux 为 AGPL‑3.0。链接 `VPChiaki.xcframework` 的构建必须按 AGPL 开源才能分发。
**自用和开发测试没问题；要闭源上架，必须先完成第二阶段的净室重写并移除该库。**
