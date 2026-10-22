# Research Notes

日期：2026-06-14

## 已确认

- Vision Pro 没有 HDMI 输入，不能直接当 PS5 显示器。
- Developer Strap 是 USB-C 数据链路，不是 HDMI 输入。
- visionOS 支持访问连接设备的视频输入，Apple 有 UVC 外部设备示例。
- PS5 游戏采集需要关闭 HDCP；受保护视频内容不适合这条路线。
- PS Remote Play 不是本项目目标，因为它通常不是原生 4K 输入链路。

## 参考来源

- Apple Developer: Displaying video from connected devices  
  https://developer.apple.com/documentation/visionOS/displaying-video-from-connected-devices
- Apple Developer: visionOS resources  
  https://developer.apple.com/visionos/resources/
- Sony PlayStation: PS5 4K resolution guide  
  https://www.playstation.com/en-us/support/hardware/ps5-4k-resolution-guide/
- Sony PlayStation Blog: PS5 FAQ, HDMI capture devices and HDCP  
  https://blog.playstation.com/2020/11/09/ps5-the-ultimate-faq/
- Sony Remote Play support  
  https://www.sony-asia.com/electronics/support/articles/SX365201

## 需要实机验证

- Developer Strap Gen 2 + 目标采集卡是否能稳定枚举。
- 4K60 在 Vision Pro 上的可选像素格式。
- 4K60 长时间稳定性。
- 音频链路延迟。
- HDR 是否可用，以及色彩是否正确。
- App Store 发布时的权限和审核要求。

