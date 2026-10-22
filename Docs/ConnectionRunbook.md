# Connection Runbook

## 接线

```text
PS5 HDMI OUT
  -> HDMI 2.1 cable
  -> Capture card HDMI IN
  -> USB-C data cable
  -> Vision Pro Developer Strap Gen 2
```

如果采集卡有 passthrough：

```text
Capture card HDMI OUT
  -> TV/monitor HDMI IN
```

## PS5 设置

先用保守设置跑通：

- `Settings > System > HDMI > Enable HDCP`：关闭
- `Settings > Screen and Video > Video Output > Resolution`：2160p
- `HDR`：Off
- `120 Hz Output`：Off
- `VRR`：Off
- `Deep Color Output`：Automatic 或 Off，黑屏时改 Off
- `RGB Range`：Automatic，颜色异常时改 Limited

跑通后再逐项打开：

1. HDR
2. 120Hz
3. VRR

注意：目标是 4K60。120Hz 和 VRR 通常不是 UVC Viewer 的第一阶段目标。

## Vision Pro 端验证顺序

1. 先用商用 UVC Viewer，例如 CaptureLinker/同类 App。
2. 确认能看到采集卡。
3. 确认输入格式接近 3840x2160 60fps。
4. 测试 15 分钟，观察黑屏、掉帧、音频断续和发热。
5. 再用本项目 `PS5VisionCapture` 原型验证自研 App 路线。

## Mac 端预检

在接 Vision Pro 之前，建议先接 Mac：

- 打开 QuickTime Player，选择新建影片录制，看是否能选到采集卡。
- 打开 OBS，查看采集卡可选分辨率和帧率。
- `System Information > USB` 查看设备是否按 SuperSpeed/USB 3.x 连接。

如果 Mac 端都无法稳定 4K60，不要先排查 Vision Pro。

## 黑屏排障

优先顺序：

1. 关闭 PS5 HDCP。
2. 关闭 HDR。
3. 关闭 120Hz。
4. 关闭 VRR。
5. 换 HDMI 线。
6. 换 USB-C 数据线。
7. 用 Mac 预检采集卡。
8. 给采集卡升级固件。
9. 用 EDID 模拟器锁定 4K60 SDR。

## 延迟测试

有 passthrough 时：

1. 电视显示 passthrough 画面。
2. Vision Pro 显示 UVC 画面。
3. 在 PS5 菜单快速左右移动光标。
4. 观察 Vision Pro 相对电视的滞后。

无 passthrough 时：

1. 用 DualSense 操作高响应菜单或训练场。
2. 记录主观延迟。
3. 与 Remote Play 对比。

