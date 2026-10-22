# Hardware Checklist

## 必买

### Apple Vision Pro Developer Strap Gen 2

用途：把 UVC HDMI 采集卡作为 USB 视频设备接入 Vision Pro。

采购判断：

- 选择 Gen 2，优先使用更高带宽 USB-C 数据链路。
- 只把它当数据接入口，不要期待它提供 HDMI 输入。

### 4K60 UVC HDMI 采集卡

硬要求：

- HDMI 输入支持 3840x2160 60Hz。
- USB 输出明确支持 UVC 3840x2160 60fps。
- 支持 macOS 无驱 UVC 识别。
- 优先支持 NV12/YUY2/MJPEG 多种 UVC 格式。
- 最好带 HDMI passthrough，便于接电视对比延迟。

不要只看这些宣传词：

- `4K input`
- `4K passthrough`
- `HDMI 2.1`
- `8K passthrough`

这些不等于 USB 端能输出 4K60。

候选方向：

- Elgato 4K X 级别：关注 UVC、4K60 USB 输出和 Mac 兼容性。
- AVerMedia Live Gamer ULTRA 2.1 级别：关注 UVC、4K60 USB 输出和 HDMI passthrough。
- Magewell USB Capture HDMI 4K Plus 级别：工业/专业路线，价格高但稳定性通常更强。

采购建议：

- 选择可退货渠道。
- 买回来先接 Mac 用 QuickTime/OBS/系统信息确认 UVC 格式，再接 Vision Pro。
- 如果预算允许，同时买两款不同芯片方案做 A/B 测试。

### 线材

- PS5 到采集卡：HDMI 2.1 线。
- 采集卡到 Developer Strap：短 USB-C 数据线，标称 10Gbps 或 20Gbps。
- 不要使用只支持充电的 USB-C 线。

## 可选

- HDMI EDID 模拟器：用于锁定 4K60 SDR，排查黑屏。
- HDMI 音频分离器：如果采集卡音频延迟或格式不稳定时使用。
- USB-C 功率/协议测试器：排查线材和链路问题。
- 电视/显示器：用于 HDMI passthrough 延迟对比。

## 采购前确认问题

- USB 输出是否明确写 `3840x2160p60`？
- 4K60 输出格式是 MJPEG、NV12、YUY2 还是 H.264？
- macOS 是否无需驱动？
- 是否支持 HDCP 关闭后的 PS5 游戏画面？
- 是否支持固件升级？
- 是否支持 HDMI passthrough？

