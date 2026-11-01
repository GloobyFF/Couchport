#if os(tvOS)
import SwiftUI

/// About, licenses and source code on Apple TV. Same content as `AboutView`
/// (the AGPL "Appropriate Legal Notices" and the Corresponding Source link),
/// laid out as a full-screen page. Apple TV has no browser, so links are shown
/// as text plus a QR code.
struct TVAboutView: View {
    @State private var detail: TVAboutDetail?
    @FocusState private var focus: TVAboutDetail?

    var body: some View {
        TVPage(title: "About", leadingWidth: 760) {
            header

            // The Appropriate Legal Notices (AGPL §0/§5d) in three short lines.
            VStack(alignment: .leading, spacing: 20) {
                Text("Open-source software under the GNU AGPL v3. Provided without any warranty.")
                    .font(TVMetrics.body)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Independent app, not affiliated with Sony Interactive Entertainment or Apple.")
                    .font(TVMetrics.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(verbatim: "Copyright © 2026 The Couchport Authors · \(AppInfo.releaseTag)")
                    .font(TVMetrics.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } trailing: {
            if let url = AppInfo.sourceURLForThisBuild {
                TVCard(padding: 28) {
                    HStack(alignment: .center, spacing: 32) {
                        TVQRCode(text: url.absoluteString, size: 200)
                        VStack(alignment: .leading, spacing: 12) {
                            Label("View Source Code", systemImage: "chevron.left.forwardslash.chevron.right")
                                .font(TVMetrics.sectionTitle)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(verbatim: url.absoluteString)
                                .font(TVMetrics.caption.monospaced())
                                .fixedSize(horizontal: false, vertical: true)
                            Text("Scan with your phone to open this page.")
                                .font(TVMetrics.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }

            ForEach(TVAboutDetail.allCases) { item in
                Button {
                    detail = item
                } label: {
                    HStack(spacing: 24) {
                        Image(systemName: item.icon)
                            .font(.system(size: 34, weight: .semibold))
                            .frame(width: 48)
                        Text(item.title)
                            .font(TVMetrics.body.weight(.semibold))
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 16)
                        Image(systemName: "chevron.forward")
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 32)
                    .padding(.vertical, 24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.card)
                .focused($focus, equals: item)
            }
        }
        .defaultFocus($focus, .license)
        .onAppear { focus = .license }
        .adaptiveSheet(item: $detail) { item in
            NavigationStack {
                item.page
                    .navigationDestination(for: TVLicenseFile.self) { file in
                        TVLicenseTextPage(file: file)
                            .tvPageBackground()
                    }
                    .navigationDestination(for: TVLicenseList.self) { _ in
                        TVLicenseListPage()
                            .tvPageBackground()
                    }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 24) {
            Image("AppMark")
                .resizable()
                .interpolation(.high)
                .frame(width: 112, height: 112)
                .clipShape(Circle())
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: "Couchport")
                    .font(TVMetrics.sectionTitle)
                Text("Sit back. Step in.")
                    .font(TVMetrics.body)
                    .foregroundStyle(.secondary)
                Text(verbatim: AppInfo.versionString)
                    .font(TVMetrics.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Detail pages

private enum TVAboutDetail: String, Identifiable, CaseIterable, Hashable {
    case license, components, trademarks
    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .license: return "License"
        case .components: return "Open-Source Components"
        case .trademarks: return "Trademarks"
        }
    }

    var icon: String {
        switch self {
        case .license: return "doc.text"
        case .components: return "shippingbox"
        case .trademarks: return "c.circle"
        }
    }

    @MainActor @ViewBuilder
    var page: some View {
        switch self {
        case .license: TVLicenseDetailPage()
        case .components: TVComponentsPage()
        case .trademarks: TVTrademarksPage()
        }
    }
}

/// A bundled license text (Resources/Licenses/<name>.txt), pushed by name.
private struct TVLicenseFile: Hashable {
    let title: String
    let fileName: String
}

/// Marker value for pushing the list of bundled license texts.
private struct TVLicenseList: Hashable {}

/// A full-screen reading page. tvOS scrolls by moving focus, so every block
/// inside is focusable (`TVReadableBlock`); the first one takes focus.
private struct TVReadingPage<Content: View>: View {
    let title: Text
    @ViewBuilder var content: Content
    @Environment(\.dismiss) private var dismiss
    @Namespace private var scope

    var body: some View {
        VStack(alignment: .leading, spacing: TVMetrics.sectionSpacing) {
            HStack(alignment: .firstTextBaseline) {
                title
                    .font(TVMetrics.pageTitle)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Spacer(minLength: 40)
                Button {
                    dismiss()
                } label: {
                    Label("Back", systemImage: "chevron.backward")
                }
            }
            .focusSection()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    content.environment(\.tvReadingScope, scope)
                }
                    .frame(maxWidth: 1400, alignment: .leading)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .focusSection()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .focusScope(scope)
        .toolbar(.hidden, for: .navigationBar)
        .onExitCommand { dismiss() }
    }
}

/// One focusable paragraph (or group) on a reading page, highlighted when the
/// remote rests on it.
private struct TVReadableBlock<Content: View>: View {
    var prefersFocus = false
    @ViewBuilder var content: Content
    @FocusState private var isFocused: Bool
    @Environment(\.tvReadingScope) private var scope

    var body: some View {
        VStack(alignment: .leading, spacing: 8) { content }
            .font(TVMetrics.body)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 28)
            .padding(.vertical, 20)
            .background(isFocused ? Color.white.opacity(0.14) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .focusable()
            .focused($isFocused)
            .modifier(TVPreferredFocus(prefers: prefersFocus, scope: scope))
            .animation(.easeOut(duration: 0.15), value: isFocused)
    }
}

/// Lets the first block of a reading page take focus when the page opens.
private struct TVPreferredFocus: ViewModifier {
    let prefers: Bool
    let scope: Namespace.ID?

    func body(content: Content) -> some View {
        if let scope {
            content.prefersDefaultFocus(prefers, in: scope)
        } else {
            content
        }
    }
}

private extension EnvironmentValues {
    @Entry var tvReadingScope: Namespace.ID? = nil
}

/// A focusable navigation row on a reading page.
private struct TVReadingLink<Value: Hashable>: View {
    let title: Text
    let value: Value

    var body: some View {
        NavigationLink(value: value) {
            HStack(spacing: 24) {
                title
                    .font(TVMetrics.body.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 16)
                Image(systemName: "chevron.forward")
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.card)
    }
}

private struct TVLicenseDetailPage: View {
    var body: some View {
        TVReadingPage(title: Text("License")) {
            TVReadableBlock(prefersFocus: true) {
                Text("Couchport is free software: you can redistribute it and/or modify it under the terms of the GNU Affero General Public License, version 3, as published by the Free Software Foundation.")
            }
            TVReadableBlock {
                Text("Couchport is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU Affero General Public License for more details.")
            }
            TVReadingLink(title: Text("GNU Affero General Public License v3"),
                          value: TVLicenseFile(title: "AGPL-3.0", fileName: "AGPL-3.0"))

            Text("Source Code")
                .font(TVMetrics.sectionTitle)
                .padding(.top, 24)
            TVReadableBlock {
                HStack(alignment: .top, spacing: 40) {
                    if let url = AppInfo.repositoryURL {
                        TVQRCode(text: url.absoluteString, size: 200)
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 16) {
                            Text("Version").foregroundStyle(.secondary)
                            Text(verbatim: AppInfo.versionString).monospacedDigit()
                        }
                        HStack(spacing: 16) {
                            Text("Source for this build").foregroundStyle(.secondary)
                            Text(verbatim: AppInfo.releaseTag)
                        }
                        if let url = AppInfo.repositoryURL {
                            Text(verbatim: url.absoluteString)
                                .font(TVMetrics.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            TVReadableBlock {
                Text("The complete source code of this exact version, including build scripts and the pinned versions of every library, is available at no charge under the AGPL. You may build, modify and share it. If you distribute a modified version, or let people use it over a network, you must offer them its source under the same license.")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct TVComponentsPage: View {
    var body: some View {
        TVReadingPage(title: Text("Open-Source Components")) {
            ForEach(Array(ThirdPartyComponent.all.enumerated()), id: \.element.id) { index, component in
                TVReadableBlock(prefersFocus: index == 0) {
                    Text(verbatim: component.name)
                        .font(TVMetrics.body.weight(.semibold))
                    Text(verbatim: component.license)
                        .font(TVMetrics.caption)
                        .foregroundStyle(.secondary)
                    Text(verbatim: component.url)
                        .font(TVMetrics.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
            if !LicenseTextView.bundledFiles.isEmpty {
                TVReadingLink(title: Text("Full License Texts"), value: TVLicenseList())
            }
            TVReadableBlock {
                Text("Remote Play is built on chiaki and its forks chiaki-ng and Pylux. Their copyright holders' notices are kept in the source repository and in the license texts above.")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct TVTrademarksPage: View {
    var body: some View {
        TVReadingPage(title: Text("Trademarks")) {
            TVReadableBlock(prefersFocus: true) {
                Text("Couchport is an independent app and is not affiliated with, endorsed by, or sponsored by Sony Interactive Entertainment, Microsoft, or Apple. PlayStation, PS5, and PS4 are trademarks of Sony Interactive Entertainment Inc. Other names are trademarks of their respective owners and are used only to describe compatibility.")
            }
        }
    }
}

private struct TVLicenseListPage: View {
    var body: some View {
        TVReadingPage(title: Text("Full License Texts")) {
            ForEach(LicenseTextView.bundledFiles, id: \.self) { name in
                TVReadingLink(title: Text(verbatim: name),
                              value: TVLicenseFile(title: name, fileName: name))
            }
        }
    }
}

/// A bundled license text, split into focusable paragraphs.
private struct TVLicenseTextPage: View {
    let file: TVLicenseFile

    private var paragraphs: [String] {
        let url = Bundle.main.url(forResource: file.fileName, withExtension: "txt", subdirectory: "Licenses")
            ?? Bundle.main.url(forResource: file.fileName, withExtension: "txt")
        let text = url.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
            ?? "https://www.gnu.org/licenses/agpl-3.0.txt"
        // Paragraphs are separated by blank lines; the hard line wraps inside
        // each one are joined so the text reflows at TV size.
        return text.components(separatedBy: "\n\n")
            .map { paragraph in
                paragraph.split(whereSeparator: \.isNewline)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .joined(separator: " ")
            }
            .filter { !$0.isEmpty }
    }

    var body: some View {
        TVReadingPage(title: Text(verbatim: file.title)) {
            ForEach(Array(paragraphs.enumerated()), id: \.offset) { index, paragraph in
                TVReadableBlock(prefersFocus: index == 0) {
                    Text(verbatim: paragraph)
                }
            }
        }
    }
}
#endif
