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

    /// Stable identity across devices: the console's MAC (the same console
    /// paired on two devices gets two UUIDs), else the UUID.
    var syncIdentity: String { macHex.isEmpty ? id.uuidString : macHex }
}

/// Saved consoles + the PSN account ID used for pairing and sessions.
@MainActor
final class ConsoleStore: ObservableObject {
    @Published private(set) var consoles: [PSConsole] = []
    @Published private(set) var accountIDBase64: String?

    private let defaultsKey = "remotePlay.consoles.v1"
    private let accountKey = "psn.accountID"

    private let sync = ConsoleSync()
    private var syncObserver: NSObjectProtocol?

    init() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let list = try? JSONDecoder().decode([PSConsole].self, from: data) {
            consoles = list
        }
        accountIDBase64 = Keychain.string(accountKey)

        // Consoles paired on another device signed in to the same Apple
        // Account arrive through iCloud (list: key-value store, secrets:
        // iCloud Keychain). Apple TV relies on this: it cannot show Sony's
        // sign-in page.
        syncObserver = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: NSUbiquitousKeyValueStore.default, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.syncNow() }
            }
        NSUbiquitousKeyValueStore.default.synchronize()
        syncNow()
    }

    /// Pulls consoles paired elsewhere, then publishes ours. Cheap; called on
    /// launch, on iCloud change notifications and when the app becomes active
    /// (the Keychain half can arrive after the list).
    func syncNow() {
        let pulled = sync.pull(into: consoles, hasAccountID: accountIDBase64 != nil)
        if !pulled.added.isEmpty {
            for item in pulled.added {
                Keychain.setData(item.registKey, for: registKeyName(item.console))
                Keychain.setData(item.morning, for: morningName(item.console))
                consoles.append(item.console)
            }
            saveLocal()
        }
        if let id = pulled.accountID, accountIDBase64 == nil {
            Keychain.set(id, for: accountKey)
            accountIDBase64 = id
        }
        publish()
    }

    private func publish() {
        sync.publish(consoles: consoles, secrets: { self.secrets(for: $0) }, accountID: accountIDBase64)
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
        publish()
    }

    func add(host: String, keys: RegisteredConsoleKeys) -> PSConsole {
        // (A fresh pairing has a newer addedAt than any tombstone, so it syncs again.)
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
        // Tell other devices to stop importing it (they keep their own copy).
        sync.markRemoved(console)
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
        saveLocal()
        publish()
    }

    private func saveLocal() {
        if let data = try? JSONEncoder().encode(consoles) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }
}

// MARK: - iCloud sync

/// Shares the paired-console list between the user's devices.
///
/// - The list (names, addresses, MACs; no secrets) lives in iCloud key-value
///   storage, which also tells us when another device changed it.
/// - The pairing secrets (registration key, morning key) and the PSN account
///   ID live in iCloud Keychain (`kSecAttrSynchronizable`), which is end-to-end
///   encrypted, never in key-value storage.
///
/// The merge is additive and conservative:
/// - A console is imported only if no local console has the same identity
///   (MAC) and both of its secrets have arrived; otherwise it is retried on
///   the next sync. Local consoles, names and addresses are never overwritten.
/// - Forgetting a console writes a tombstone. Devices stop importing and
///   re-publishing it, but a device that already has it keeps its copy.
///   Pairing it again (newer `addedAt`) brings it back.
/// - The account ID is adopted only when this device has none.
/// Used only from `ConsoleStore` on the main actor.
final class ConsoleSync {
    struct Record: Codable, Equatable {
        var id: UUID
        var nickname: String
        var host: String
        var isPS5: Bool
        var macHex: String
        var addedAt: Date

        var identity: String { macHex.isEmpty ? id.uuidString : macHex }
    }

    struct Payload: Codable, Equatable {
        var version = 1
        var consoles: [Record] = []
        /// identity → when it was forgotten.
        var removed: [String: Date] = [:]
    }

    struct Imported {
        let console: PSConsole
        let registKey: Data
        let morning: Data
    }

    private let kvs = NSUbiquitousKeyValueStore.default
    private let payloadKey = "remotePlay.consoles.sync.v1"
    private let accountKey = "sync.psn.accountID"
    private let maxTombstones = 100

    private func registName(_ identity: String) -> String { "sync.console.\(identity).registKey" }
    private func morningName(_ identity: String) -> String { "sync.console.\(identity).morning" }

    private func read() -> Payload {
        guard let data = kvs.data(forKey: payloadKey),
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.version == 1 else { return Payload() }
        return payload
    }

    private func write(_ payload: Payload) {
        guard let data = try? JSONEncoder().encode(payload) else { return }
        kvs.set(data, forKey: payloadKey)
    }

    private func isTombstoned(_ identity: String, addedAt: Date, in payload: Payload) -> Bool {
        guard let removedAt = payload.removed[identity] else { return false }
        return removedAt >= addedAt
    }

    /// Consoles to add locally, plus the account ID when this device lacks one.
    func pull(into local: [PSConsole], hasAccountID: Bool) -> (added: [Imported], accountID: String?) {
        let payload = read()
        var known = Set(local.map(\.syncIdentity))
        let localIDs = Set(local.map(\.id))
        var added: [Imported] = []
        for record in payload.consoles {
            let identity = record.identity
            guard !known.contains(identity),
                  !isTombstoned(identity, addedAt: record.addedAt, in: payload),
                  let regist = Keychain.data(registName(identity), synchronizable: true), regist.count == 16,
                  let morning = Keychain.data(morningName(identity), synchronizable: true), morning.count == 16
            else { continue }
            let console = PSConsole(id: localIDs.contains(record.id) ? UUID() : record.id,
                                    nickname: record.nickname, host: record.host,
                                    isPS5: record.isPS5, macHex: record.macHex,
                                    addedAt: record.addedAt, lastPlayedAt: nil)
            added.append(Imported(console: console, registKey: regist, morning: morning))
            known.insert(identity)
        }
        var accountID: String?
        if !hasAccountID, let id = Keychain.string(accountKey, synchronizable: true),
           let raw = Data(base64Encoded: id), raw.count == 8 {
            accountID = id
        }
        return (added, accountID)
    }

    /// Merges our consoles into the shared list (never drops other devices'
    /// entries) and makes sure their secrets are in iCloud Keychain.
    func publish(consoles: [PSConsole], secrets: (PSConsole) -> (registKey: Data, morning: Data)?,
                 accountID: String?) {
        var payload = read()
        let before = payload
        var byIdentity = Dictionary(payload.consoles.map { ($0.identity, $0) }, uniquingKeysWith: { a, _ in a })
        for console in consoles {
            let identity = console.syncIdentity
            guard !isTombstoned(identity, addedAt: console.addedAt, in: payload),
                  let secret = secrets(console) else { continue }
            if byIdentity[identity] == nil {
                byIdentity[identity] = Record(id: console.id, nickname: console.nickname, host: console.host,
                                              isPS5: console.isPS5, macHex: console.macHex,
                                              addedAt: console.addedAt)
            }
            setIfChanged(secret.registKey, registName(identity))
            setIfChanged(secret.morning, morningName(identity))
        }
        payload.consoles = byIdentity.values
            .filter { !isTombstoned($0.identity, addedAt: $0.addedAt, in: payload) }
            .sorted { $0.addedAt < $1.addedAt }
        if payload != before { write(payload) }

        if let accountID, Keychain.string(accountKey, synchronizable: true) != accountID {
            Keychain.set(accountID, for: accountKey, synchronizable: true)
        }
    }

    /// Forgotten here: drop it from the shared list and iCloud Keychain.
    func markRemoved(_ console: PSConsole) {
        var payload = read()
        let identity = console.syncIdentity
        payload.removed[identity] = Date()
        if payload.removed.count > maxTombstones {
            let keep = payload.removed.sorted { $0.value > $1.value }.prefix(maxTombstones)
            payload.removed = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
        payload.consoles.removeAll { $0.identity == identity }
        write(payload)
        Keychain.delete(registName(identity), synchronizable: true)
        Keychain.delete(morningName(identity), synchronizable: true)
    }

    private func setIfChanged(_ data: Data, _ name: String) {
        if Keychain.data(name, synchronizable: true) != data {
            Keychain.setData(data, for: name, synchronizable: true)
        }
    }
}

/// Minimal generic-password Keychain wrapper. Local items are this-device
/// only; `synchronizable` items go to iCloud Keychain (end-to-end encrypted)
/// and are used only for sharing pairings between the user's own devices.
enum Keychain {
    private static let service = (Bundle.main.bundleIdentifier ?? "UVCTheater") + ".remoteplay"

    private static func base(_ key: String, synchronizable: Bool) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecAttrSynchronizable as String: synchronizable
        ]
    }

    static func setData(_ data: Data, for key: String, synchronizable: Bool = false) {
        delete(key, synchronizable: synchronizable)
        var query = base(key, synchronizable: synchronizable)
        // Synchronizable items cannot be "ThisDeviceOnly".
        query[kSecAttrAccessible as String] = synchronizable
            ? kSecAttrAccessibleAfterFirstUnlock : kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        query[kSecValueData as String] = data
        SecItemAdd(query as CFDictionary, nil)
    }

    static func data(_ key: String, synchronizable: Bool = false) -> Data? {
        var query = base(key, synchronizable: synchronizable)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    static func set(_ string: String, for key: String, synchronizable: Bool = false) {
        setData(Data(string.utf8), for: key, synchronizable: synchronizable)
    }

    static func string(_ key: String, synchronizable: Bool = false) -> String? {
        data(key, synchronizable: synchronizable).flatMap { String(data: $0, encoding: .utf8) }
    }

    static func delete(_ key: String, synchronizable: Bool = false) {
        SecItemDelete(base(key, synchronizable: synchronizable) as CFDictionary)
    }
}
