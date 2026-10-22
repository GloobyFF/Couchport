import Foundation
import Security

/// A paired PlayStation. Pairing secrets live in the Keychain, not here.
struct PSConsole: Codable, Identifiable, Hashable {
    var id = UUID()
    var nickname: String
    var host: String
    var isPS5: Bool
    var macHex: String
    var addedAt = Date()
    /// Last time a session was started. Optional so older saved data decodes.
    var lastPlayedAt: Date?
}

/// Saved consoles + the PSN account ID used for pairing and sessions.
@MainActor
final class ConsoleStore: ObservableObject {
    @Published private(set) var consoles: [PSConsole] = []
    @Published private(set) var accountIDBase64: String?

    private let defaultsKey = "remotePlay.consoles.v1"
    private let accountKey = "psn.accountID"

    init() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let list = try? JSONDecoder().decode([PSConsole].self, from: data) {
            consoles = list
        }
        accountIDBase64 = Keychain.string(accountKey)
    }

    /// 8 raw bytes decoded from the stored base64 account ID.
    var accountID: Data? {
        guard let b64 = accountIDBase64, let d = Data(base64Encoded: b64), d.count == 8 else { return nil }
        return d
    }

    func setAccountID(base64: String) throws {
        let trimmed = base64.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let d = Data(base64Encoded: trimmed), d.count == 8 else {
            throw RemotePlayError.native(String(localized: "The PSN account ID must be 8 bytes encoded as base64 (12 characters ending in '=')."))
        }
        Keychain.set(trimmed, for: accountKey)
        accountIDBase64 = trimmed
    }

    func add(host: String, keys: RegisteredConsoleKeys) -> PSConsole {
        let mac = keys.mac.map { String(format: "%02X", $0) }.joined(separator: ":")
        // Re-pairing the same console replaces it.
        if let index = consoles.firstIndex(where: { $0.macHex == mac && !mac.isEmpty }) {
            removeSecrets(for: consoles[index])
            consoles.remove(at: index)
        }
        let console = PSConsole(nickname: keys.nickname.isEmpty ? "PlayStation" : keys.nickname,
                                host: host, isPS5: keys.isPS5, macHex: mac)
        Keychain.setData(keys.registKey, for: registKeyName(console))
        Keychain.setData(keys.morning, for: morningName(console))
        consoles.append(console)
        save()
        return console
    }

    func updateHost(_ console: PSConsole, host: String) {
        guard let i = consoles.firstIndex(where: { $0.id == console.id }) else { return }
        consoles[i].host = host
        save()
    }

    func rename(_ console: PSConsole, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let i = consoles.firstIndex(where: { $0.id == console.id }) else { return }
        consoles[i].nickname = trimmed
        save()
    }

    func markPlayed(_ console: PSConsole) {
        guard let i = consoles.firstIndex(where: { $0.id == console.id }) else { return }
        consoles[i].lastPlayedAt = Date()
        save()
    }

    /// The console a one-tap "Play" on Home should use: last played, else first paired.
    var preferredConsole: PSConsole? {
        consoles.max { ($0.lastPlayedAt ?? .distantPast, $1.addedAt) < ($1.lastPlayedAt ?? .distantPast, $0.addedAt) }
    }

    func remove(_ console: PSConsole) {
        removeSecrets(for: console)
        consoles.removeAll { $0.id == console.id }
        save()
    }

    func secrets(for console: PSConsole) -> (registKey: Data, morning: Data)? {
        guard let r = Keychain.data(registKeyName(console)), r.count == 16,
              let m = Keychain.data(morningName(console)), m.count == 16 else { return nil }
        return (r, m)
    }

    private func removeSecrets(for console: PSConsole) {
        Keychain.delete(registKeyName(console))
        Keychain.delete(morningName(console))
    }

    private func registKeyName(_ c: PSConsole) -> String { "console.\(c.id.uuidString).registKey" }
    private func morningName(_ c: PSConsole) -> String { "console.\(c.id.uuidString).morning" }

    private func save() {
        if let data = try? JSONEncoder().encode(consoles) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }
}

/// Minimal generic-password Keychain wrapper.
enum Keychain {
    private static let service = (Bundle.main.bundleIdentifier ?? "UVCTheater") + ".remoteplay"

    static func setData(_ data: Data, for key: String) {
        delete(key)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: data
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    static func data(_ key: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    static func set(_ string: String, for key: String) { setData(Data(string.utf8), for: key) }
    static func string(_ key: String) -> String? { data(key).flatMap { String(data: $0, encoding: .utf8) } }

    static func delete(_ key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
    }
}
