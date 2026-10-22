# Build And Run

## 生成项目

```sh
cd /Volumes/2T/APPTest/PS5
xcodegen generate
open PS5VisionCapture.xcodeproj
```

## 命令行编译检查

```sh
xcodebuild -project PS5VisionCapture.xcodeproj \
  -scheme PS5VisionCapture \
  -destination 'generic/platform=visionOS' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

当前已在 Xcode 26.5 / visionOS SDK 26.5 下通过 generic build。

## 真机运行

1. 打开 `PS5VisionCapture.xcodeproj`。
2. 选择 `PS5VisionCapture` target。
3. 在 Signing & Capabilities 里选择你的 Apple Developer Team。
4. Bundle ID 如冲突，改成自己的反向域名。
5. 连接 Vision Pro。
6. 运行到 Vision Pro 真机。

## 当前原型限制

- 只做 UVC 设备发现和实时预览。
- 没有录制功能。
- 没有音频选择功能。
- 没有手动选择 UVC 分辨率/帧率。
- 没有主动强制 4K preset，因为 `AVCaptureSession.sessionPreset` 在 visionOS 不可用。

## 后续技术任务

第一优先级：

- 枚举 `AVCaptureDevice.formats`。
- 找出采集卡可用的 3840x2160 / 60fps 格式。
- 使用 `activeFormat` 和 frame duration 设置目标格式。
- 在 UI 上显示实际输入格式和帧率。

第二优先级：

- 增加设备选择器。
- 增加音频输入链路。
- 加入丢帧计数和运行时状态。
- 做 Fit / Fill / 1:1 画面模式。

