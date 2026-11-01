#if os(tvOS)
import SwiftUI

/// Apple TV stream settings, laid out like the tvOS Settings app: section
/// list on the left, the focused section's controls on the right. Same
/// settings, bindings and Pro gating as `RemoteSettingsSections`.
struct TVSettingsView: View {
    @ObservedObject var settings: RemotePlaySettings
    var onApplyNow: (() -> Void)? = nil
    /// Opens the paywall; nil asks the main window directly.
    var onUpgrade: (() -> Void)? = nil

    @ObservedObject private var store = PurchaseManager.shared
    @State private var selected: SettingsSection = .video
    @State private var showAbout = false
    @FocusState private var focusedSection: SettingsSection?

    enum SettingsSection: String, CaseIterable, Identifiable, Hashable {
        case video, audio, controller, about
        var id: String { rawValue }

        var icon: String {
            switch self {
            case .video: return "tv"
            case .audio: return "speaker.wave.2.fill"
            case .controller: return "gamecontroller.fill"
            case .about: return "info.circle"
            }
        }

        var title: LocalizedStringKey {
            switch self {
            case .video: return "Video"
            case .audio: return "Audio"
            case .controller: return "Controller"
            case .about: return "About"
            }
        }
    }

    private var bitrates: [Int] { store.isPro ? RemoteSettingsSections.bitrates : FreeTier.bitrates }

    var body: some View {
        TVPage(title: "Stream Settings") {
            sectionList
        } trailing: {
            detail(for: selected)
        }
        .defaultFocus($focusedSection, .video)
        .onAppear { focusedSection = .video }
        .onChange(of: focusedSection) { _, newValue in
            if let newValue { selected = newValue }
        }
        .adaptiveSheet(isPresented: $showAbout) { AboutView() }
    }

    // MARK: Left column

    @ViewBuilder
    private var sectionList: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(SettingsSection.allCases) { section in
                Button {
                    selected = section
                } label: {
                    HStack(spacing: 20) {
                        Image(systemName: section.icon)
                            .frame(width: 44)
                        Text(section.title)
                            .font(TVMetrics.body)
                            .lineLimit(1)
                        Spacer(minLength: 12)
                        if selected == section {
                            Image(systemName: "chevron.forward")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .focused($focusedSection, equals: section)
            }
        }

        if let onApplyNow {
            Button {
                onApplyNow()
            } label: {
                Label("Apply Now (Reconnect)", systemImage: "arrow.triangle.2.circlepath")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.bordered)
            .padding(.top, 24)
        }
    }

    // MARK: Right column

    @ViewBuilder
    private func detail(for section: SettingsSection) -> some View {
        Text(section.title)
            .font(TVMetrics.sectionTitle)
        switch section {
        case .video: videoSection
        case .audio: audioSection
        case .controller: controllerSection
        case .about: aboutSection
        }
    }

    @ViewBuilder
    private var videoSection: some View {
        if !store.isPro {
            ProUpsellRow(title: "Unlock 1080p, HDR and every bitrate with Pro", onUpgrade: onUpgrade)
        }
        TVCard {
            Picker("Resolution", selection: $settings.resolution) {
                Text("720p").tag(720)
                if store.isPro {
                    Text("1080p").tag(1080)
                }
            }
            .pickerStyle(.segmented)
            Picker("Frame Rate", selection: $settings.fps) {
                Text("30 fps").tag(30)
                Text("60 fps").tag(60)
            }
            .pickerStyle(.segmented)
            Toggle("HEVC (PS5 only)", isOn: $settings.useHEVC)
            if store.isPro {
                Toggle("HDR (10-bit)", isOn: $settings.hdr)
                    .disabled(!settings.useHEVC)
            } else {
                // Locked: a disabled toggle can't take focus on tvOS, so the
                // row opens the paywall instead.
                Button {
                    upgrade()
                } label: {
                    HStack(spacing: 12) {
                        Text("HDR (10-bit)")
                        ProBadge()
                        Spacer(minLength: 12)
                        Image(systemName: "lock.fill")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Picker("Bitrate", selection: $settings.bitrateKbps) {
                ForEach(bitrates, id: \.self) { kbps in
                    if kbps == 0 {
                        Text("Automatic").tag(kbps)
                    } else {
                        Text(verbatim: "\(kbps / 1000) Mbps").tag(kbps)
                    }
                }
            }
            .pickerStyle(.menu)
        }
        footer(Text("HDR needs HEVC and an HDR game; the picture is tone-mapped for the headset. 1080p is the highest resolution PS5 Remote Play sends. Above 30 Mbps is experimental: it needs a wired PS5 and strong 5 GHz or 6 GHz Wi-Fi, otherwise frames drop. HEVC looks better at the same bitrate."))
    }

    @ViewBuilder
    private var audioSection: some View {
        TVCard {
            HStack(spacing: 24) {
                Image(systemName: "speaker.fill")
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                AdaptiveSlider(value: $settings.volume, range: 0...1, step: 0.1,
                               valueText: { "\(Int(($0 * 100).rounded()))%" })
                Image(systemName: "speaker.wave.3.fill")
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }

    @ViewBuilder
    private var controllerSection: some View {
        TVCard {
            Toggle("Haptic Feedback", isOn: $settings.haptics)
            if settings.haptics {
                HStack(spacing: 24) {
                    Text("Strength")
                    Spacer(minLength: 12)
                    AdaptiveSlider(value: $settings.hapticsStrength, range: 0.2...1.5, step: 0.1,
                                   valueText: { "\(Int(($0 * 100).rounded()))%" })
                }
            }
            Toggle("Adaptive Triggers", isOn: $settings.adaptiveTriggers)
            Toggle("Motion Controls (Gyro)", isOn: $settings.motion)
            Toggle("Swap ✕ and ○ (Confirm / Cancel)", isOn: $settings.swapConfirmCancel)
            Toggle("Swap □ and △", isOn: $settings.swapSquareTriangle)
        }
        footer(Text("DualSense haptics, adaptive triggers and the light bar follow the game. The touchpad is sent as touch input. Haptics and HDR apply on the next connection.")
            + Text(verbatim: " ")
            + Text("The button swaps apply right away to a connected controller, for example one with a Nintendo-style layout or a game that confirms with ○. The on-screen controller is never swapped."))
    }

    @ViewBuilder
    private var aboutSection: some View {
        Button {
            showAbout = true
        } label: {
            HStack(spacing: 24) {
                Image(systemName: "info.circle.fill")
                    .font(.system(size: 44))
                    .allowsHitTesting(false)
                VStack(alignment: .leading, spacing: 6) {
                    Text("About Couchport")
                        .font(TVMetrics.body.weight(.semibold))
                    Text(verbatim: AppInfo.versionString)
                        .font(TVMetrics.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                Image(systemName: "chevron.forward")
                    .foregroundStyle(.secondary)
            }
            .padding(32)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.card)
    }

    // MARK: Helpers

    private func footer(_ text: Text) -> some View {
        text
            .font(TVMetrics.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func upgrade() {
        if let onUpgrade { onUpgrade() } else { PurchaseManager.shared.requestPaywall(.feature) }
    }
}
#endif
