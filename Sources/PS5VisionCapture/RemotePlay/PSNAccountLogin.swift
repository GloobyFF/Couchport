import SwiftUI
import WebKit

/// Gets the PSN account ID (8 bytes, base64) the console needs for pairing.
///
/// Same flow chiaki-ng uses: sign in on Sony's page inside a web view, catch
/// the redirect carrying `code`, exchange it for a token, then read
/// `user_id` and encode it little-endian. Only the account ID is kept.
enum PSNAccountService {
    // Remote Play client credentials as used by chiaki-ng (psnaccountid.h).
    static let clientID = "ba495a24-818c-472b-b12d-ff231c1b5745"
    static let clientSecret = "mvaiZkRsAsI1IBkY"
    static let redirectHost = "remoteplay.dl.playstation.net"
    static let redirectPath = "/remoteplay/redirect"
    static let tokenURL = URL(string: "https://auth.api.sonyentertainmentnetwork.com/2.0/oauth/token")!
    static let scope = "psn:clientapp referenceDataService:countryConfig.read pushNotification:webSocket.desktop.connect sessionManager:remotePlaySession.system.update"

    static var loginURL: URL {
        var c = URLComponents(string: "https://auth.api.sonyentertainmentnetwork.com/2.0/oauth/authorize")!
        c.queryItems = [
            .init(name: "service_entity", value: "urn:service-entity:psn"),
            .init(name: "response_type", value: "code"),
            .init(name: "client_id", value: clientID),
            .init(name: "redirect_uri", value: "https://\(redirectHost)\(redirectPath)"),
            .init(name: "scope", value: scope),
            .init(name: "request_locale", value: "en_US"),
            .init(name: "ui", value: "pr"),
            .init(name: "service_logo", value: "ps"),
            .init(name: "layout_type", value: "popup"),
            .init(name: "smcid", value: "remoteplay"),
            .init(name: "prompt", value: "always"),
            .init(name: "PlatformPrivacyWs1", value: "minimal")
        ]
        return c.url!
    }

    private static var basicAuth: String {
        "Basic " + Data("\(clientID):\(clientSecret)".utf8).base64EncodedString()
    }

    static func accountID(fromCode code: String) async throws -> String {
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue(basicAuth, forHTTPHeaderField: "Authorization")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var form = URLComponents()
        form.queryItems = [
            .init(name: "grant_type", value: "authorization_code"),
            .init(name: "code", value: code),
            .init(name: "scope", value: scope),
            .init(name: "redirect_uri", value: "https://\(redirectHost)\(redirectPath)")
        ]
        request.httpBody = form.percentEncodedQuery?.data(using: .utf8)

        let (tokenData, _) = try await URLSession.shared.data(for: request)
        guard let token = (try JSONSerialization.jsonObject(with: tokenData) as? [String: Any])?["access_token"] as? String else {
            throw RemotePlayError.native(String(localized: "PSN sign-in did not return a token."))
        }

        var infoRequest = URLRequest(url: tokenURL.appendingPathComponent(token))
        infoRequest.setValue(basicAuth, forHTTPHeaderField: "Authorization")
        let (infoData, _) = try await URLSession.shared.data(for: infoRequest)
        guard let userID = (try JSONSerialization.jsonObject(with: infoData) as? [String: Any])?["user_id"] as? String,
              let number = UInt64(userID) else {
            throw RemotePlayError.native(String(localized: "PSN did not return a user ID."))
        }
        var le = number.littleEndian
        return withUnsafeBytes(of: &le) { Data($0) }.base64EncodedString()
    }
}

/// Sheet with Sony's sign-in page. Calls `onAccountID` with the base64 ID.
struct PSNLoginSheet: View {
    let onAccountID: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var working = false
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            ZStack {
                PSNWebView { code in
                    guard !working else { return }
                    working = true
                    Task {
                        do {
                            let id = try await PSNAccountService.accountID(fromCode: code)
                            onAccountID(id)
                            dismiss()
                        } catch {
                            errorText = error.localizedDescription
                            working = false
                        }
                    }
                }
                if working {
                    ProgressView("Getting account ID…")
                        .padding(24)
                        .adaptiveGlass(in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                }
            }
            .navigationTitle("Sign in to PlayStation Network")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .alert("Sign-in failed", isPresented: .constant(errorText != nil)) {
                Button("OK") { errorText = nil }
            } message: {
                Text(errorText ?? "")
            }
        }
        .visionMinFrame(width: 640, height: 760)
    }
}

private struct PSNWebView: UIViewRepresentable {
    let onCode: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()   // always a fresh sign-in
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.load(URLRequest(url: PSNAccountService.loginURL))
        return view
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        let onCode: (String) -> Void
        init(onCode: @escaping (String) -> Void) { self.onCode = onCode }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if let url = navigationAction.request.url,
               url.host == PSNAccountService.redirectHost,
               url.path.hasPrefix(PSNAccountService.redirectPath) {
                let code = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                    .queryItems?.first { $0.name == "code" }?.value
                decisionHandler(.cancel)
                if let code { onCode(code) }
                return
            }
            decisionHandler(.allow)
        }
    }
}
