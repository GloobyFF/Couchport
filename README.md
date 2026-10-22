# Couchport

**Sit back. Step in.** 窝进沙发，一步入战。

PS5 / PS4 遥控游玩（Remote Play）客户端，支持 **Apple Vision Pro**、**iPhone**（包括折叠屏 iPhone Duo）和 **iPad**；Vision Pro 和 iPad 还可以通过 UVC 采集卡接入任意 HDMI 设备。

> Couchport 以 **GNU AGPL-3.0** 开源（见 `LICENSE`、`NOTICE.md`、`Docs/Licensing.md`）。它是独立 App，与 Sony Interactive Entertainment、Microsoft、Apple 均无关联。

## 平台

| 平台 | Target | 遥控游玩 | 采集卡 | 沉浸式影院 |
|---|---|---|---|---|
| visionOS 26+ | `PS5VisionCapture` | ✓ | ✓（Developer Strap） | ✓ |
| iOS / iPadOS 26+ | `Couchport-iOS` | ✓ | 仅 iPad（USB-C） | — |

iPhone Duo：布局按窗口实际宽度切换，不按机型判断。所以折叠和展开、旋转、分屏都会实时切换布局，串流不中断。窄屏（折叠状态、普通 iPhone）用单列布局，控制栏只显示图标；宽屏（展开状态、iPad）用双栏布局。

## 构建

```bash
brew install cmake ninja protobuf xcodegen
./Tools/build_libchiaki_visionos.sh    # 构建 visionOS + iOS 的 VPChiaki.xcframework，并拷贝许可证
xcodegen generate
open PS5VisionCapture.xcodeproj        # 选择 PS5VisionCapture（Vision Pro）或 Couchport-iOS scheme
```

两个 Target 共用 Bundle ID `com.glooby.UVCTheater`（通用购买）和内购项目 `com.glooby.UVCTheater.pro`。

## 发版前

按 `Docs/Licensing.md` 检查一遍，然后打 tag：`git tag v1.0 && git push --tags`。App 关于页的 “View Source Code” 会打开 `…/tree/v<版本号>`。

---

## 历史说明（原 UVC Theater）

目标：在 Apple Vision Pro 里玩 PS5，画质尽量接近 4K，并优先控制延迟。

两种信号源（主页二选一）：

- **采集卡模式**：有线、最高 4K60、延迟最低，需要开发者头带。采集卡若有 USB 音频，会自动播放声音。
- **Remote Play 模式**：无线、最高 1080p60、**有声音**，不需要头带。见 `Docs/RemotePlay.md`。

采集卡推荐路线：

```text
PS5 HDMI
  -> HDMI 2.1 / 4K60 UVC 采集卡
  -> USB-C
  -> Vision Pro Developer Strap Gen 2
  -> visionOS UVC Viewer App
```

本项目包含两部分：

- `Docs/`：采购、连接、验证和排障文档。
- `Sources/PS5VisionCapture/`：一个最小 visionOS UVC Viewer 原型，用于验证采集卡输入。

## 当前判断

- Vision Pro 不能直接接 HDMI，当普通显示器使用。
- Developer Strap 提供 USB-C 数据链路，配合 UVC HDMI 采集卡可以把 PS5 画面作为外部视频输入显示。
- Remote Play/PS Portal 类路线通常不是原生 4K，不适合作为本目标的主方案。
- 采集卡是否能在 Vision Pro 上稳定输出 4K60，需要实机验证。很多设备只是 4K 输入或 4K passthrough，USB 输出仍可能只有 1080p。

## 最小资源

硬件：

- Apple Vision Pro
- Vision Pro Developer Strap Gen 2
- PS5
- HDMI 2.1 线
- 真 4K60 UVC HDMI 采集卡
- 短 USB-C 线，优先 10Gbps/20Gbps 标称线材
- 可选：带 HDMI passthrough 的采集卡，便于同时接电视做延迟对比

软件：

- visionOS 26 或更新版本
- Xcode 26.5 或更新版本
- Apple Developer 账号
- 商用 UVC Viewer：CaptureLinker/同类 App
- 自研验证 App：本项目 `PS5VisionCapture`

## 快速开始

1. 先按 `Docs/HardwareChecklist.md` 采购或确认设备。
2. 按 `Docs/ConnectionRunbook.md` 接线和设置 PS5。
3. 先用商用 UVC Viewer 验证画面、分辨率和延迟。
4. 再用本项目原型验证自研路线。
5. Xcode 构建和真机运行见 `Docs/BuildAndRun.md`。

生成 Xcode 项目（先编译 Remote Play 库，详见 `Docs/RemotePlay.md`）：

```sh
cd /Volumes/2T/APPTest/PS5
./Tools/build_libchiaki_visionos.sh
xcodegen generate
open PS5VisionCapture.xcodeproj
```

命令行构建：

```sh
xcodebuild -project PS5VisionCapture.xcodeproj \
  -scheme PS5VisionCapture \
  -destination 'generic/platform=visionOS' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

## 成功标准

- PS5 关闭 HDCP 后，Vision Pro 端能看到稳定画面。
- UVC Viewer 能识别采集卡并显示 3840x2160 或接近 4K 的输入格式。
- 60fps 稳定，声音无明显断续。
- 主观延迟可接受；如果玩动作/竞技游戏，应和电视 passthrough 对比。

## 关键风险

- UVC 采集卡宣传的 4K 可能只是输入或 passthrough，不是 USB 输出。
- HDR、VRR、120Hz、HDCP 都可能导致黑屏或格式降级。
- visionOS 对 UVC 访问能力和权限随系统版本变化，旧系统尤其容易受 entitlement 限制。
- 4K60 MJPEG/YUY2/NV12 的实际解码与显示延迟差异很大，需要逐卡测试。
- 本项目已实现基于采集卡 `activeFormat` 的 4K60 格式选择（遍历 `device.formats`，优先 3840×2160@60），并在 UI 显示实际分辨率/帧率。
- **音频（实验性）**：visionOS 将采集音频路径标记为 `API_UNAVAILABLE(visionos)`（`AVCaptureAudioDataOutput` 等），所以 HDMI 音频**不能**走 `AVCaptureSession`。但多数采集卡会把音频单独枚举成一个 USB Audio Class 设备，本项目用一条**独立**的 `AVAudioSession` + `AVAudioEngine` 链路（`AudioMonitor`）选中 `.usbAudio` 输入并实时播放。这是尽力而为：卡有 UAC 音频才出声，且音视频各走各的时基、可能有唇音偏差；能否出声取决于具体采集卡，必须实机验证。

## Couchport Pro

One-time in-app purchase `com.glooby.UVCTheater.pro`. Free: 10-minute Remote Play sessions, 720p, 10–20 Mbps, no HDR, no picture enhancement, no capture card mode. Pro unlocks all of it. Local testing uses `UVC Theater.storekit` (set as the scheme's StoreKit configuration by `project.yml`). See `Docs/Changes-2026-10-22-pro.md`.

## Trademarks

Couchport is an independent app and is not affiliated with, endorsed by, or sponsored by Sony Interactive Entertainment, Microsoft, or Apple. PlayStation, PS5 and PS4 are trademarks of Sony Interactive Entertainment Inc.
