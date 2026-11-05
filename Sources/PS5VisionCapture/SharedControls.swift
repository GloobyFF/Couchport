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
    /// Re-centres the reclined screen on the head (theater only).
    var onRecenter: (() -> Void)? = nil
    #if os(visionOS)
    @EnvironmentObject private var app: AppModel
    #endif

    var body: some View {
        Section("Theater Screen") {
            HStack(spacing: 10) {
                preset("Desk", width: 2.2, distance: 1.8, height: 1.1, curve: 0.2)
                preset("Living Room", width: 4, distance: 3.2, height: 1.2, curve: 0.3)
                preset("Cinema", width: 8, distance: 6.5, height: 1.8, curve: 0.45)
                preset("IMAX", width: 12, distance: 8, height: 2.4, curve: 0.65)
            }
            slider("Room Dimming", $renderOptions.theaterDim, 0...1, "%")
            #if os(visionOS)
            Toggle("Floor Reflection", isOn: $renderOptions.theaterReflection)
                .disabled(renderOptions.theaterRecline >= 10)
            if renderOptions.theaterReflection && renderOptions.theaterRecline < 10 {
                slider("Reflection Gap", $renderOptions.theaterReflectionGap, 0...1, "cm")
                Toggle("Water Ripples", isOn: Binding(get: { app.remote.settings.waterRipples },
                                                     set: { app.remote.settings.waterRipples = $0 }))
                Text("Ripples follow how fast you press the controller buttons.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            reclineControls
            Toggle("Hide Hands", isOn: $app.theaterHideHands)
            Text("Hiding hands uses full immersion and hides your surroundings. Turn this off to restore passthrough.")
                .font(.caption)
                .foregroundStyle(.secondary)
            #endif
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
                renderOptions.theaterRecline = 0
            } label: {
                Label("Reset Screen", systemImage: "arrow.counterclockwise")
            }
        }
    }

    #if os(visionOS)
    /// Lying back: angle presets, a fine slider and Recenter.
    @ViewBuilder private var reclineControls: some View {
        HStack(spacing: 10) {
            reclinePreset("Sit", 0)
            reclinePreset("Recline", 35)
            reclinePreset("Lie Down", 75)
        }
        slider("Recline", $renderOptions.theaterRecline, 0...85, "°")
        if renderOptions.theaterRecline > 0.5 {
            if let onRecenter {
                Button {
                    onRecenter()
                } label: {
                    Label("Recenter", systemImage: "scope")
                }
            }
            Text("The screen moves up over your head and faces down. Floor reflection is off while reclined.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func reclinePreset(_ title: String, _ angle: Float) -> some View {
        Button {
            withAnimation { renderOptions.theaterRecline = angle }
        } label: {
            Text(LocalizedStringKey(title))
                .font(.callout)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .tint(abs(renderOptions.theaterRecline - angle) < 1 ? Brand.blue : nil)
    }
    #endif

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
        if unit == "cm" { return String(format: "%.0f cm", value * 100) }
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
        #if os(tvOS)
        // Apple TV: plain rows in a Form cannot take focus, so a long list
        // could not scroll. The stats are cards in columns that fit one screen.
        TVPanelPage(title: "Performance Stats", contentWidth: .infinity) {
            TVStatsGrid(statistics: statistics)
        }
        #else
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
        #endif
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

#if os(tvOS)
// MARK: - Apple TV panel pages

/// A full-screen Apple TV page for one player panel: title and Back at the
/// top, then the content in a single centred column. Menu closes it.
struct TVPanelPage<Content: View>: View {
    let title: LocalizedStringKey
    var contentWidth: CGFloat = 1400
    var onClose: (() -> Void)? = nil
    @ViewBuilder var content: Content
    @Environment(\.dismiss) private var dismiss
    @Namespace private var focusScope

    var body: some View {
        VStack(alignment: .leading, spacing: TVMetrics.sectionSpacing) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(TVMetrics.pageTitle)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Spacer(minLength: 40)
                Button {
                    close()
                } label: {
                    Label("Back", systemImage: "chevron.backward")
                }
            }
            .focusSection()

            content
                .frame(maxWidth: contentWidth)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .focusSection()
                // Focus starts on the panel's first control, not on Back.
                .prefersDefaultFocus(in: focusScope)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .focusScope(focusScope)
        .onExitCommand { close() }
    }

    private func close() {
        if let onClose { onClose() } else { dismiss() }
    }
}

/// The performance stats as three columns of cards (same values as
/// `StatsSections`), sized to fit one TV screen without scrolling.
private struct TVStatsGrid: View {
    @ObservedObject var statistics: RenderStatistics

    var body: some View {
        HStack(alignment: .top, spacing: 40) {
            if statistics.isStreamActive {
                card("Remote Play Stream",
                     footer: "High jitter or many lost frames point to Wi-Fi. Use 5 GHz or wire the console, or lower the bitrate.") {
                    row("Bitrate", String(format: "%.1f Mbps", statistics.streamBitrateMbps))
                    row("Round Trip", statistics.rttMs > 0 ? String(format: "%.0f ms", statistics.rttMs) : "—")
                    row("Packet Loss", String(format: "%.1f%%", statistics.packetLoss * 100))
                    row("Decode Time", String(format: "%.1f ms", statistics.averageDecodeTime))
                    row("Frame Jitter", String(format: "%.1f ms", statistics.frameJitter))
                    row("Frames Lost", "\(statistics.framesLost)")
                    row("Decode Errors", "\(statistics.decodeErrors)")
                    row("Keyframe Requests", "\(statistics.keyframeRequests)")
                }
            }

            VStack(spacing: 32) {
                card("GPU Performance") {
                    row("Average Frame Time", String(format: "%.2f ms", statistics.averageGPUTime))
                    row("Est. Max FPS", statistics.averageGPUTime > 0
                        ? String(format: "%.0f", 1000.0 / statistics.averageGPUTime)
                        : "—")
                }
                card("Frame Delivery") {
                    row("Total Frames", "\(statistics.totalFrameCount)")
                    row("Dropped Frames", "\(statistics.droppedFrameCount)")
                    row("Drop Rate", String(format: "%.2f%%", statistics.droppedFrameRate))
                }
            }

            VStack(alignment: .leading, spacing: 32) {
                card("Upscaler State") {
                    row("MetalFX Active", statistics.isMetalFXActive ? String(localized: "Yes") : String(localized: "No"))
                    row("Lanczos Active", statistics.isLanczosActive ? String(localized: "Yes") : String(localized: "No"))
                }
                card("Memory") {
                    row("App Memory", String(format: "%.0f MB", statistics.memoryFootprintMB))
                    row("Video Textures", String(format: "%.1f MB", statistics.textureMemoryMB))
                    row("Memory Warnings", "\(statistics.memoryWarnings)")
                }
                Button {
                    statistics.reset()
                } label: {
                    Label("Reset Statistics", systemImage: "arrow.counterclockwise")
                        .font(TVMetrics.body)
                }
            }
        }
    }

    private func card<Rows: View>(_ title: LocalizedStringKey, footer: LocalizedStringKey? = nil,
                                  @ViewBuilder rows: () -> Rows) -> some View {
        TVCard(padding: 32) {
            Text(title)
                .font(TVMetrics.sectionTitle)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            VStack(alignment: .leading, spacing: 10) { rows() }
            if let footer {
                Text(footer)
                    .font(TVMetrics.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private func row(_ label: LocalizedStringKey, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(label)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Spacer(minLength: 12)
            Text(verbatim: value)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .font(TVMetrics.body)
    }
}
#endif
