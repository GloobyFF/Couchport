import SwiftUI

/// About, licenses and source code.
///
/// Couchport links chiaki / chiaki-ng / Pylux, which are AGPL-3.0, so the
/// whole app is distributed under the GNU AGPL v3. AGPL §5(d) requires an
/// interactive program to show "Appropriate Legal Notices" (§0): copyright,
/// no warranty, that the work is licensed under the AGPL, and how to view the
/// license. §6 requires the Corresponding Source of the exact build. This
/// screen does both; `CouchportSourceURL` in Info.plist names the repository
/// and each release is tagged `v<CFBundleShortVersionString>`.
struct AboutView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    header
                }
                .listRowBackground(Color.clear)

                Section {
                    Text(verbatim: "Copyright © 2026 The Couchport Authors")
                    Text("Couchport is free software: you can redistribute it and/or modify it under the terms of the GNU Affero General Public License, version 3, as published by the Free Software Foundation.")
                    Text("Couchport is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU Affero General Public License for more details.")
                    NavigationLink("GNU Affero General Public License v3") {
                        LicenseTextView(title: "AGPL-3.0", fileName: "AGPL-3.0")
                    }
                } header: {
                    Text("License")
                }

                Section {
                    LabeledContent("Version", value: AppInfo.versionString)
                    LabeledContent("Source for this build", value: AppInfo.releaseTag)
                    if let url = AppInfo.sourceURLForThisBuild {
                        Button {
                            openURL(url)
                        } label: {
                            Label("View Source Code", systemImage: "chevron.left.forwardslash.chevron.right")
                        }
                    }
                    if let url = AppInfo.repositoryURL {
                        Text(verbatim: url.absoluteString)
                            .font(.footnote.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                } header: {
                    Text("Source Code")
                } footer: {
                    Text("The complete source code of this exact version, including build scripts and the pinned versions of every library, is available at no charge under the AGPL. You may build, modify and share it. If you distribute a modified version, or let people use it over a network, you must offer them its source under the same license.")
                }

                Section {
                    ForEach(ThirdPartyComponent.all) { component in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(verbatim: component.name)
                                .font(.body.weight(.semibold))
                            Text(verbatim: component.license)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(verbatim: component.url)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.tertiary)
                                .textSelection(.enabled)
                        }
                        .padding(.vertical, 2)
                    }
                    if !LicenseTextView.bundledFiles.isEmpty {
                        NavigationLink("Full License Texts") {
                            LicenseListView()
                        }
                    }
                } header: {
                    Text("Open-Source Components")
                } footer: {
                    Text("Remote Play is built on chiaki and its forks chiaki-ng and Pylux. Their copyright holders' notices are kept in the source repository and in the license texts above.")
                }

                Section {
                    Text("Couchport Pro is an optional purchase that supports development. Because Couchport is open source, you are free to build it from source yourself.")
                } header: {
                    Text("About Couchport Pro")
                }

                Section {
                    Text("Couchport is an independent app and is not affiliated with, endorsed by, or sponsored by Sony Interactive Entertainment, Microsoft, or Apple. PlayStation, PS5, and PS4 are trademarks of Sony Interactive Entertainment Inc. Other names are trademarks of their respective owners and are used only to describe compatibility.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Trademarks")
                }
            }
            .scrollContentBackground(.hidden)
            .navigationTitle("About")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .brandWindowBackground()
        .visionMinFrame(width: 560, height: 680)
    }

    private var header: some View {
        HStack(spacing: 16) {
            Image("AppMark")
                .resizable()
                .interpolation(.high)
                .frame(width: 64, height: 64)
                .clipShape(Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: "Couchport")
                    .font(.title2.weight(.bold))
                Text("Sit back. Step in.")
                    .foregroundStyle(.secondary)
                Text(verbatim: AppInfo.versionString)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

// MARK: - Build info

enum AppInfo {
    static var shortVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }

    static var versionString: String { "\(shortVersion) (\(build))" }

    /// Git tag of the source that produced this build.
    static var releaseTag: String { "v\(shortVersion)" }

    static var repositoryURL: URL? {
        guard let text = Bundle.main.object(forInfoDictionaryKey: "CouchportSourceURL") as? String,
              !text.isEmpty else { return nil }
        return URL(string: text)
    }

    static var sourceURLForThisBuild: URL? {
        repositoryURL?.appending(path: "tree").appending(path: releaseTag)
    }
}

// MARK: - Third-party components

struct ThirdPartyComponent: Identifiable {
    let name: String
    let license: String
    let url: String
    var id: String { name }

    static let all: [ThirdPartyComponent] = [
        .init(name: "Chiaki", license: "AGPL-3.0 with OpenSSL exception",
              url: "https://git.sr.ht/~thestr4ng3r/chiaki"),
        .init(name: "chiaki-ng", license: "AGPL-3.0 with OpenSSL exception",
              url: "https://github.com/streetpea/chiaki-ng"),
        .init(name: "Pylux", license: "AGPL-3.0 with OpenSSL exception",
              url: "https://github.com/ForWard-Technologies-LLC/Pylux"),
        .init(name: "Mbed TLS", license: "Apache-2.0",
              url: "https://github.com/Mbed-TLS/mbedtls"),
        .init(name: "Opus", license: "BSD-3-Clause",
              url: "https://opus-codec.org"),
        .init(name: "json-c", license: "MIT",
              url: "https://github.com/json-c/json-c"),
        .init(name: "miniupnpc", license: "BSD-3-Clause",
              url: "https://github.com/miniupnp/miniupnp"),
        .init(name: "curl", license: "curl License (MIT-style)",
              url: "https://curl.se"),
        .init(name: "nanopb", license: "zlib",
              url: "https://github.com/nanopb/nanopb"),
        .init(name: "Jerasure", license: "BSD-3-Clause",
              url: "https://github.com/tsuraan/Jerasure"),
        .init(name: "GF-Complete", license: "BSD-3-Clause",
              url: "https://github.com/ceph/gf-complete"),
    ]
}

// MARK: - License texts (Resources/Licenses/*.txt)

struct LicenseTextView: View {
    let title: String
    let fileName: String

    static var bundledFiles: [String] {
        let urls = Bundle.main.urls(forResourcesWithExtension: "txt", subdirectory: "Licenses")
            ?? Bundle.main.urls(forResourcesWithExtension: "txt", subdirectory: nil)?
                .filter { $0.lastPathComponent.hasPrefix("LICENSE-") || $0.lastPathComponent == "AGPL-3.0.txt" }
            ?? []
        return urls.map { $0.deletingPathExtension().lastPathComponent }.sorted()
    }

    private var text: String {
        let url = Bundle.main.url(forResource: fileName, withExtension: "txt", subdirectory: "Licenses")
            ?? Bundle.main.url(forResource: fileName, withExtension: "txt")
        if let url, let text = try? String(contentsOf: url, encoding: .utf8) { return text }
        return "https://www.gnu.org/licenses/agpl-3.0.txt"
    }

    var body: some View {
        ScrollView {
            Text(verbatim: text)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .navigationTitle(Text(verbatim: title))
    }
}

private struct LicenseListView: View {
    var body: some View {
        List(LicenseTextView.bundledFiles, id: \.self) { name in
            NavigationLink(name) {
                LicenseTextView(title: name, fileName: name)
            }
        }
        .scrollContentBackground(.hidden)
        .navigationTitle("Full License Texts")
    }
}
