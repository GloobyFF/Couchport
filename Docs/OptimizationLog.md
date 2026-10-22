# PS5VisionCapture 性能优化日志

**日期**: 2026-07-25  
**状态**: ✅ 编译通过，待真机验证

---

## 优化概览

针对 60fps 低延迟视频捕获场景，实施了以下核心优化：

### 1. 锁优化 - 减少竞争开销 ⚡️

**问题**：原有实现每帧都用 `NSLock` 保护帧计数器、时间戳和输出尺寸，在 60fps 下造成不必要的锁竞争。

**解决方案**：
- 新增 `AtomicCounter` 和 `AtomicValue` 类，使用 `os_unfair_lock`（比 NSLock 快 ~3-5x）
- 帧计数改用无锁原子递增
- 将 `theaterGeneration` 从 `NSLock` 保护改为 `AtomicValue`

**影响文件**：
- `AtomicCounter.swift` (新增)
- `MetalVideoRenderer.swift` (重构)

**预期收益**：
- 每帧减少 2-3 次锁操作
- CPU 开销降低约 5-10µs/帧（60fps = 600µs/秒节省）

---

### 2. 纹理池化 - 消除分配延迟峰值 🎯

**问题**：每次分辨率变化都重新创建纹理（1080p↔4K 切换时），导致内存碎片和帧延迟峰值（可达 2-5ms）。

**解决方案**：
- 新增 `MetalTexturePool`，按 (width, height, format, usage) 缓存纹理
- 每个尺寸最多保留 3 个纹理（防止无限增长）
- 5 秒空闲超时自动清理（释放不再使用的分辨率）

**影响文件**：
- `MetalTexturePool.swift` (新增)
- `MetalVideoRenderer.swift` (`ensureTexture` 改为从池获取)

**预期收益**：
- 分辨率切换时零分配开销（首次除外）
- 减少内存碎片，改善长时间运行稳定性
- 常见场景（1080p/1440p/4K）预热后无延迟

---

### 3. Lanczos 生命周期管理 🧹

**问题**：`MPSImageLanczosScale` 对象创建后永不释放，即使用户切换到 MetalFX 或暂停捕获。

**解决方案**：
- 记录 Lanczos 最后使用时间
- 5 秒无使用自动释放（通过纹理池清理定时器）
- 需要时再重新创建（开销 <1ms，可接受）

**影响文件**：
- `MetalVideoRenderer.swift` (`ensureLanczos` + `purgeIdleLanczos`)

**预期收益**：
- 节省 ~5-10MB GPU 内存（当 MetalFX 激活或暂停时）

---

### 4. 错误处理改进 🔍

**问题**：Metal 初始化失败时静默返回 `nil`，用户看到通用错误"Metal is required but unavailable"，无法排查。

**解决方案**：
- 新增 `MetalRendererError` 枚举，包含详细错误和恢复建议
- `MetalVideoRenderer.make()` 改为 `throws`，每步返回具体失败原因
- 示例：shader 编译失败会显示具体函数名和底层错误

**影响文件**：
- `MetalRendererError.swift` (新增)
- `MetalVideoRenderer.swift` (`make()` 改为 throwing)
- `CaptureManager.swift` (调用处适配)

**预期收益**：
- 用户/开发者可快速定位问题（设备不支持 vs shader 损坏 vs 内存不足）
- 生产环境诊断时节省时间

---

### 5. 性能统计系统 📊

**问题**：缺少 GPU 帧时间、丢帧率、内存占用等关键指标，无法验证优化效果或排查性能问题。

**解决方案**：
- 新增 `RenderStatistics` 类，收集：
  - GPU 平均帧时间（60 帧滚动平均）
  - 丢帧计数和比例
  - 当前激活的 upscaler（MetalFX/Lanczos）
  - 纹理池内存占用
- 在 UI 添加"Performance Stats"调试面板（More 菜单 → Performance Stats）
- 使用 `MTLCommandBuffer.addCompletedHandler` 精确测量 GPU 时间

**影响文件**：
- `RenderStatistics.swift` (新增)
- `ContentView.swift` (新增 `DebugStatsPanel` 视图)
- `CaptureManager.swift` (集成统计对象)
- `MetalVideoRenderer.swift` (埋点收集)

**预期收益**：
- 真机测试时可量化优化效果
- 快速发现性能瓶颈（GPU bound vs CPU bound）
- 验证 MetalFX 实际性能 vs Lanczos

---

## 代码质量改进

### 硬编码常量清理
- 帧率采样间隔 `0.25s` 保持（合理默认值）
- 目标分辨率 `3840×2160` 提取为 `RenderOptions` 常量（为未来 1440p 选项留空间）

### 未使用资源清理
**待定**：`Resources/DepthAnything_Small.mlpackage` 深度模型未被代码引用。
- 如果 3D Relief 功能已取消 → 从 bundle 移除（节省 ~50MB）
- 如果待实现 → 需补全 `DepthEstimator` 类

---

## 构建验证

```bash
xcodegen generate
xcodebuild -project PS5VisionCapture.xcodeproj \
  -scheme PS5VisionCapture \
  -destination 'generic/platform=visionOS' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

**结果**: ✅ **BUILD SUCCEEDED**

---

## 待真机验证项

以下优化的实际效果需要在 Vision Pro 上测量：

1. **锁优化**
   - 验证方式：Performance Stats 面板查看 GPU 时间是否降低
   - 预期：GPU 时间不变，但 CPU 开销降低（需 Instruments 验证）

2. **纹理池化**
   - 验证方式：Performance Stats 查看内存占用稳定性
   - 测试场景：1080p ↔ 4K 频繁切换 10 次，观察帧时间峰值

3. **统计系统准确性**
   - 验证方式：对比 Performance Stats 的 GPU 时间 vs Instruments Metal System Trace
   - 确认 `addCompletedHandler` 计时准确

4. **整体延迟**
   - 验证方式：HDMI passthrough 对比（PS5 → 电视 vs PS5 → Vision Pro）
   - 目标：保持 <50ms 端到端延迟（捕获卡 + 处理 + 显示）

---

## 未来优化方向

### 高优先级（需真机数据决策）
1. **16-bit 浮点纹理** (issue #6)
   - 先在真机验证暗部是否有色带
   - 如果有，实现 `rgba16Float` 中间纹理 + 最终阶段有序抖动
   - 权衡：2× 带宽/内存 vs 画质提升

2. **音频同步** (issue #8)
   - 添加可调音频延迟补偿（slider: -500ms ~ +500ms）
   - 测量实际 USB Audio Class 延迟
   - 探索 `AVSampleBufferAudioRenderer` 时间戳对齐（需验证 visionOS 可用性）

### 中优先级
3. **预设系统扩展**
   - 添加游戏针对性预设（Dark Souls/FPS/Racing）
   - 允许用户保存/加载自定义预设

4. **1440p 可选目标**
   - 为低端采集卡或降低 GPU 负载提供选项
   - 在 `RenderOptions` 添加目标分辨率选择器

### 低优先级（架构改进）
5. **渲染管线可测试性**
   - 引入 `VideoFrameSource` 协议
   - 允许注入测试视频序列
   - 独立验证色彩分级/锐化算法

6. **Swift/Metal 结构体同步**
   - 使用代码生成或运行时断言验证 `ColorParams` 布局一致性

---

## 性能基线（预期）

| 指标 | 优化前（估算） | 优化后（目标） | 测量方法 |
|------|--------------|--------------|---------|
| 帧计数锁开销 | ~10µs/帧 | ~2µs/帧 | Instruments Time Profiler |
| 分辨率切换峰值 | 2-5ms | <0.5ms | Performance Stats GPU Time |
| 内存碎片（1h运行） | 逐步增长 | 稳定 | Memory Graph Debugger |
| Lanczos 空闲内存 | 常驻 10MB | 按需 | Performance Stats |

---

## 回滚方案

如果真机测试发现性能回退：

1. **锁优化** → 恢复 `NSLock`（保留 `AtomicCounter` 文件，改回调用 `NSLock`）
2. **纹理池** → 禁用池，`ensureTexture` 改回直接创建
3. **统计系统** → 从 `MetalVideoRenderer` 移除埋点（保留独立文件供调试）

---

## 参考资源

- Apple Metal Best Practices: https://developer.apple.com/metal/Metal-Best-Practices-Guide.pdf
- os_unfair_lock vs NSLock: https://mjtsai.com/blog/2015/12/16/osspinlock-is-unsafe/
- Metal Performance Shaders: https://developer.apple.com/documentation/metalperformanceshaders
- visionOS UVC 限制: memory 文件 `ps5-vision-capture.md`

---

## 提交历史

```
[2026-07-25] 性能优化第一阶段
- 锁优化：AtomicCounter + os_unfair_lock
- 纹理池化：MetalTexturePool
- 错误处理：MetalRendererError
- 统计系统：RenderStatistics + DebugStatsPanel
- Lanczos 生命周期管理
```

---

## 作者注

这些优化针对"4K60 低延迟"目标设计，所有改动保持向后兼容。**关键下一步**是在真机测量基线 → 对比优化后数据 → 根据实际瓶颈调整策略。

如果 GPU 已经是瓶颈（shader 耗时 >14ms），CPU 优化收益有限；反之如果 CPU bound，这些改动会直接提升帧率稳定性。

**推荐测试流程**：
1. 启动捕获（1080p60）
2. 打开 Performance Stats 面板
3. 记录 GPU 时间基线
4. 切换到 4K + MetalFX
5. 观察 GPU 时间和丢帧率
6. 重复切换 10 次，验证纹理池效果

---

**下一步行动**: 🚀 在 Vision Pro 上运行并收集真实数据
