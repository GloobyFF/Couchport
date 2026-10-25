import SwiftUI

// MARK: - Shared option controls

/// Upscale + color grading. Used by both the window popover and the theater panel.
struct OptionSections: View {
    @ObservedObject var captureManager: CaptureManager
    @ObservedObject var renderOptions: RenderOptions
    /// Opens the paywall; see RemoteSettingsView.onUpgrade.
    var onUpgrade: (() -> Void)? = nil
    @ObservedObject private var store = PurchaseManager.shared

    var body: some View {
        Group {
            if !store.isPro {
                Section {
                    ProUpsellRow(title: "Upscaling, sharpening and colour presets are part of Pro",
                                 onUpgrade: onUpgrade)
                }
            }

            Section("Upscale") {
                ForEach(UpscaleMode.allCases) { mode in
                    Button {
                        renderOptions.upscale = mode
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(LocalizedStringKey(mode.rawValue))
                                if mode == .metalFX && !captureManager.metalFXSupported {
                                    Text("Not supported on this device")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if renderOptions.upscale == mode {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.tint)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .formRowButtonStyle()
                    .disabled(mode == .metalFX && !captureManager.metalFXSupported)
                }
                Toggle("Sharpen", isOn: $renderOptions.sharpenEnabled)
                if renderOptions.sharpenEnabled && renderOptions.upscale != .metalFX {
                    optionSlider("Sharpen Amount", value: $renderOptions.sharpenAmount,
                                 range: 0...1)
                }
            }
            .disabled(!store.isPro)

            Section("Orientation") {
                Toggle(isOn: $renderOptions.flipHorizontal) {
                    Label("Flip Horizontal", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right")
                }
                Toggle(isOn: $renderOptions.flipVertical) {
                    Label("Flip Vertical", systemImage: "arrow.up.and.down.righttriangle.up.righttriangle.down")
                }
            }

            Section("Color") {
                Picker("Preset", selection: $renderOptions.preset) {
                    ForEach(GradePreset.allCases) {
                        Text(LocalizedStringKey($0.rawValue)).tag($0)
                    }
                }
                .disabled(!store.isPro)
                Picker("Matrix", selection: $renderOptions.colorMatrix) {
                    ForEach(ColorMatrix.allCases) {
                        Text(LocalizedStringKey($0.rawValue)).tag($0)
                    }
                }
                Picker("Range", selection: $renderOptions.colorRange) {
                    ForEach(ColorRange.allCases) {
                        Text(LocalizedStringKey($0.rawValue)).tag($0)
                    }
                }
                .pickerStyle(.segmented)

                if store.isPro && renderOptions.preset == .custom {
                    optionSlider("Exposure", value: $renderOptions.exposure, range: -1...1)
                    optionSlider("Contrast", value: $renderOptions.contrast, range: 0.5...1.5)
                    optionSlider("Saturation", value: $renderOptions.saturation, range: 0...2)
                    optionSlider("Gamma", value: $renderOptions.gamma, range: 0.5...2.2)
                }
            }
        }
    }

    private func optionSlider(_ title: String, value: Binding<Float>,
                              range: ClosedRange<Float>) -> some View {
        HStack {
            Text(LocalizedStringKey(title))
                .frame(width: Platform.isTV ? 260 : 150, alignment: .leading)
            AdaptiveSlider(value: value, range: range,
                           step: (range.upperBound - range.lowerBound) / 20)
            // tvOS: the − value + control already shows the number.
            if !Platform.isTV {
                Text(String(format: "%.2f", value.wrappedValue))
                    .font(.caption.monospacedDigit())
                    .frame(width: 58, alignment: .trailing)
            }
        }
    }
}

struct EnhancePanel: View {
    @ObservedObject var captureManager: CaptureManager
    @ObservedObject var renderOptions: RenderOptions

    var body: some View {
        NavigationStack {
            Form {
                OptionSections(captureManager: captureManager, renderOptions: renderOptions)
            }
            .navigationTitle("Enhance")
        }
        .visionMinFrame(width: 380, height: 460)
    }
}

/// Shared screen placement controls used by both theater control surfaces.
struct TheaterScreenSection: View {
    @ObservedObject var renderOptions: RenderOptions

    var body: some View {
        Section("Theater Screen") {
            HStack(spacing: 10) {
                preset("Desk", width: 2.2, distance: 1.8, height: 1.1, curve: 0.2)
                preset("Living Room", width: 4, distance: 3.2, height: 1.2, curve: 0.3)
                preset("Cinema", width: 8, distance: 6.5, height: 1.8, curve: 0.45)
                preset("IMAX", width: 12, distance: 8, height: 2.4, curve: 0.65)
            }
            slider("Room Dimming", $renderOptions.theaterDim, 0...1, "%")
            slider("Size", $renderOptions.theaterWidth, 2...12, "m")
            slider("Distance", $renderOptions.theaterDistance, 1.5...10, "m")
            slider("Height", $renderOptions.theaterHeight, -1...3, "m")
            slider("Tilt", $renderOptions.theaterTilt, -60...60, "°")
            slider("Curve", $renderOptions.theaterCurvature, 0...1, "")

            Button {
                renderOptions.theaterWidth = 5
                renderOptions.theaterDistance = 4
                renderOptions.theaterHeight = 1.3
                renderOptions.theaterTilt = 0
                renderOptions.theaterCurvature = 0.35
            } label: {
                Label("Reset Screen", systemImage: "arrow.counterclockwise")
            }
        }
    }

    private func preset(_ title: String, width: Float, distance: Float, height: Float,
                        curve: Float) -> some View {
        Button {
            renderOptions.theaterWidth = width
            renderOptions.theaterDistance = distance
            renderOptions.theaterHeight = height
            renderOptions.theaterCurvature = curve
            renderOptions.theaterTilt = 0
        } label: {
            Text(LocalizedStringKey(title))
                .font(.callout)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
    }

    private func slider(_ title: String, _ value: Binding<Float>,
                        _ range: ClosedRange<Float>, _ unit: String) -> some View {
        HStack {
            Text(LocalizedStringKey(title)).frame(width: 120, alignment: .leading)
            AdaptiveSlider(value: value, range: range,
                           step: (range.upperBound - range.lowerBound) / 20)
                .frame(maxWidth: 480)
            Spacer(minLength: 8)
            Text(formatted(value.wrappedValue, unit: unit))
                .font(.caption.monospacedDigit())
                .frame(width: 72, alignment: .trailing)
        }
    }

    private func formatted(_ value: Float, unit: String) -> String {
        if unit.isEmpty { return String(format: "%.2f", value) }
        if unit == "°" { return String(format: "%.0f", value) + unit }
        if unit == "%" { return String(format: "%.0f%%", value * 100) }
        return String(format: "%.1f", value) + unit
    }
}

struct ResolutionPicker: View {
    @ObservedObject var captureManager: CaptureManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Button {
                captureManager.selectFormat(nil)
                dismiss()
            } label: {
                row("Auto (recommended)", selected: captureManager.selectedFormatIndex == nil)
            }
            ForEach(captureManager.availableFormats) { option in
                Button {
                    captureManager.selectFormat(option.id)
                    dismiss()
                } label: {
                    row(option.label, selected: captureManager.selectedFormatIndex == option.id)
                }
            }
        }
        .listStyle(.plain)
        .visionMinFrame(width: 320, height: 400)
    }

    private func row(_ title: String, selected: Bool) -> some View {
        HStack {
            Text(LocalizedStringKey(title))
            Spacer()
            if selected { Image(systemName: "checkmark").foregroundStyle(.tint) }
        }
        .contentShape(Rectangle())
    }
}

struct StatusOverlay: View {
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "video.slash")
                .font(.system(size: 44, weight: .semibold))
            Text(LocalizedStringKey(title)).font(.title3.bold())
            Text(message)
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 420)
        }
        .padding(28)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// Debug performance statistics panel.
struct DebugStatsPanel: View {
    @ObservedObject var statistics: RenderStatistics
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                StatsSections(statistics: statistics)
            }
            .formBackgroundHidden()
            .navigationTitle("Performance Stats")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .brandWindowBackground()
        .visionMinFrame(width: 400, height: 500)
    }
}

/// The stats as Form sections, shared by the window sheet and the
/// immersive theater's inline panel.
struct StatsSections: View {
    @ObservedObject var statistics: RenderStatistics

    var body: some View {
        if statistics.isStreamActive {
            Section {
                LabeledContent("Bitrate", value: String(format: "%.1f Mbps", statistics.streamBitrateMbps))
                LabeledContent("Round Trip", value: statistics.rttMs > 0 ? String(format: "%.0f ms", statistics.rttMs) : "—")
                LabeledContent("Packet Loss", value: String(format: "%.1f%%", statistics.packetLoss * 100))
                LabeledContent("Decode Time", value: String(format: "%.1f ms", statistics.averageDecodeTime))
                LabeledContent("Frame Jitter", value: String(format: "%.1f ms", statistics.frameJitter))
                LabeledContent("Frames Lost", value: "\(statistics.framesLost)")
                LabeledContent("Decode Errors", value: "\(statistics.decodeErrors)")
                LabeledContent("Keyframe Requests", value: "\(statistics.keyframeRequests)")
            } header: {
                Text("Remote Play Stream")
            } footer: {
                Text("High jitter or many lost frames point to Wi-Fi. Use 5 GHz or wire the console, or lower the bitrate.")
            }
        }

        Section("GPU Performance") {
            LabeledContent("Average Frame Time", value: String(format: "%.2f ms", statistics.averageGPUTime))
            LabeledContent("Est. Max FPS", value: statistics.averageGPUTime > 0
                          ? String(format: "%.0f", 1000.0 / statistics.averageGPUTime)
                          : "—")
        }

        Section("Frame Delivery") {
            LabeledContent("Total Frames", value: "\(statistics.totalFrameCount)")
            LabeledContent("Dropped Frames", value: "\(statistics.droppedFrameCount)")
            LabeledContent("Drop Rate", value: String(format: "%.2f%%", statistics.droppedFrameRate))
        }

        Section("Upscaler State") {
            LabeledContent("MetalFX Active", value: statistics.isMetalFXActive ? String(localized: "Yes") : String(localized: "No"))
            LabeledContent("Lanczos Active", value: statistics.isLanczosActive ? String(localized: "Yes") : String(localized: "No"))
        }

        Section("Memory") {
            LabeledContent("App Memory", value: String(format: "%.0f MB", statistics.memoryFootprintMB))
            LabeledContent("Video Textures", value: String(format: "%.1f MB", statistics.textureMemoryMB))
            LabeledContent("Memory Warnings", value: "\(statistics.memoryWarnings)")
        }

        Section {
            Button("Reset Statistics") {
                statistics.reset()
            }
        }
    }
}
