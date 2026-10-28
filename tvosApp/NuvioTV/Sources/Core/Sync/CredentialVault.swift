import Foundation
import Combine
import CryptoKit
import CommonCrypto
import Security

/// Sign-ins and passwords that follow the account, end-to-end encrypted.
///
/// IPTV sources (Xtream logins included), Trakt and Simkl sessions, Jellyfin
/// servers and SMB shares are sealed per profile with a key derived from a
/// passphrase only the viewer knows (PBKDF2-SHA256, AES-GCM), and ride in the
/// profile's account settings blob as `omni_vault`. Nuvio's server only ever
/// holds the sealed box. Each device asks for the passphrase once and keeps
/// it in its own keychain, never synced.
///
/// Newest wins: a device's local change, or the box another device pushed,
/// whichever is later. A device without the passphrase leaves the box as it
/// is and keeps its own credentials.
@MainActor
final class CredentialVault: ObservableObject {
    static let shared = CredentialVault()

    /// The account settings feature the box travels in.
    nonisolated static let feature = "omni_vault"
    static let changedNotification = Notification.Name("omni.vault.changed")
    private static let iterations = 210_000

    enum Status: Equatable {
        /// Signed out, or a guest.
        case unavailable
        /// The account has no vault yet.
        case notSetUp
        /// The account has one; this device does not have the passphrase.
        case locked
        case unlocked
    }

    @Published private(set) var status: Status = .unavailable
    /// Asking the account for its box; the passphrase step waits on it.
    @Published private(set) var isChecking = false
    private var checkTimeout: Task<Void, Never>?
    /// What the last unlock or restore brought over, for onboarding's summary.
    @Published private(set) var lastRestore: Summary?

    struct Summary: Equatable {
        var iptvSources = 0
        var trakt = false
        var simkl = false
        var jellyfinServers = 0
        var smbShares = 0
        var isEmpty: Bool { iptvSources == 0 && !trakt && !simkl && jellyfinServers == 0 && smbShares == 0 }
    }

    private var accountID: String? {
        didSet { if accountID != oldValue { refreshStatus() } }
    }
    private var isApplying = false
    private var keyCache: [String: SymmetricKey] = [:]
    private var observers: [NSObjectProtocol] = []

    private init() {
        accountID = UserDefaults.standard.string(forKey: Self.accountKey)
        // Moved out of UserDefaults (see `state`): carry any old entries over.
        let defaults = UserDefaults.standard
        let old = defaults.dictionaryRepresentation().filter {
            $0.key.hasPrefix("omni.vault.") && $0.key != Self.accountKey
        }
        if !old.isEmpty {
            for (key, value) in old where state[key] == nil { state[key] = value }
            saveState()
            old.keys.forEach(defaults.removeObject(forKey:))
        }
        let center = NotificationCenter.default
        for name in [
            IPTVSourceStore.changedNotification,
            TraktAuthStore.changedNotification,
            SimklAuthStore.changedNotification,
            JellyfinServerStore.changedNotification,
            SMBServerStore.changedNotification,
            AISubtitleKeyStore.changedNotification,
        ] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                Task { @MainActor in CredentialVault.shared.noteLocalChange() }
            })
        }
        refreshStatus()
    }

    // MARK: Account

    /// The signed-in account, from the sync service; nil on sign-out.
    func setAccount(_ id: String?) {
        if id != accountID {
            keyCache.removeAll()
            UserDefaults.standard.set(id, forKey: Self.accountKey)
        }
        accountID = id
    }

    var hasPassphrase: Bool { passphrase != nil }

    /// Posted for the sync service to fetch the account's box.
    static let refreshRequestNotification = Notification.Name("omni.vault.refreshRequested")

    /// Fetches the account's box now (the passphrase step calls this).
    func refreshFromAccount() {
        isChecking = true
        NotificationCenter.default.post(name: Self.refreshRequestNotification, object: nil)
        checkTimeout?.cancel()
        checkTimeout = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 12_000_000_000)
            guard !Task.isCancelled else { return }
            self?.isChecking = false
        }
    }

    /// Takes a passphrase for an account that already has a vault: true when
    /// it opens the box, which is then applied to this device.
    @discardableResult
    func unlock(with typed: String, profileScope: String = ProfileSettings.activeProfileScope) -> Bool {
        guard let envelope = cachedEnvelope(profileScope) ?? anyCachedEnvelope() else { return false }
        // As typed, then without a stray space a phone keyboard can add.
        let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let candidate = [typed, trimmed].first(where: { attempt in
            guard let key = derive(attempt, salt: envelope.salt, iterations: envelope.iterations) else { return false }
            return (try? open(envelope, key: key)) != nil
        }) else { return false }
        storePassphrase(candidate)
        if let own = cachedEnvelope(profileScope) {
            applyIfNewer(own, profileScope: profileScope, force: true)
        }
        refreshStatus()
        return true
    }

    /// Sets the passphrase for an account with no vault yet (or replaces it,
    /// re-sealing this device's credentials), and pushes.
    func create(passphrase: String) {
        storePassphrase(passphrase)
        keyCache.removeAll()
        setLocalModified(ProfileSettings.activeProfileScope, Date())
        refreshStatus()
        requestPush()
    }

    /// After sign-out wipes this device's profiles: forgets which boxes were
    /// applied here and when its sign-ins last changed, so the next sign-in
    /// restores them instead of taking the empty device for the newer one.
    func forgetLocalHistory() {
        let stale = state.keys.filter { $0.hasPrefix("omni.vault.modified.") || $0.hasPrefix("omni.vault.applied.") }
        guard !stale.isEmpty else { return }
        stale.forEach { state[$0] = nil }
        saveState()
    }

    /// Forgets the passphrase on this device only.
    func lockThisDevice() {
        guard let accountID else { return }
        KeychainItem.remove(service: Self.keychainService, account: accountID)
        keyCache.removeAll()
        refreshStatus()
    }

    // MARK: Sync hooks

    /// The box to push for a profile: freshly sealed when this device holds
    /// the passphrase and has the newer credentials, otherwise the one already
    /// on the account, untouched.
    func envelopeForPush(profileScope: String, existing: Any?) -> Any? {
        guard let passphrase else { return existing }
        let remote = (existing as? [String: Any]).flatMap(Envelope.init(json:))
        let localModified = localModified(profileScope)
        // The account's box is as new as this device's sign-ins (its time is
        // stored to the millisecond, so allow for the rounding).
        if let remote, let localModified, remote.updatedAt.timeIntervalSince(localModified) > -0.002 { return existing }
        if remote != nil, localModified == nil { return existing }
        // Already sealed for this change: the same box again. Sealing anew
        // gives a different box every time (a fresh nonce), and an upload
        // retried before the last one landed must not count as a new change.
        if let localModified, let sealed = cachedEnvelope(profileScope),
           abs(sealed.updatedAt.timeIntervalSince(localModified)) < 0.002 {
            return sealed.json
        }
        let salt = remote?.salt ?? anyCachedEnvelope()?.salt ?? Self.randomSalt()
        guard let key = derive(passphrase, salt: salt, iterations: Self.iterations),
              let contents = try? JSONEncoder().encode(Contents.export(profileScope: profileScope)),
              let box = try? AES.GCM.seal(contents, using: key).combined else { return existing }
        let envelope = Envelope(
            salt: salt,
            iterations: Self.iterations,
            box: box,
            updatedAt: localModified ?? Date()
        )
        cache(envelope, profileScope: profileScope)
        setLastApplied(profileScope, envelope.updatedAt)
        return envelope.json
    }

    /// A pulled blob's box: kept for unlocking later, and applied now when
    /// this device can open it and it is newer than what is here.
    func received(_ json: Any?, profileScope: String) {
        isChecking = false
        checkTimeout?.cancel()
        guard let envelope = (json as? [String: Any]).flatMap(Envelope.init(json:)) else {
            refreshStatus()
            return
        }
        cache(envelope, profileScope: profileScope)
        applyIfNewer(envelope, profileScope: profileScope, force: false)
        refreshStatus()
    }

    private func applyIfNewer(_ envelope: Envelope, profileScope: String, force: Bool) {
        // A device holding none of the box's sign-ins (just signed in, or
        // wiped by a sign-out) takes the box whatever the times say: the
        // times can be left from before the wipe.
        let deviceIsEmpty = Contents.export(profileScope: profileScope).isEmpty
        if !force, !deviceIsEmpty {
            if let applied = lastApplied(profileScope), applied >= envelope.updatedAt { return }
            if let local = localModified(profileScope), local > envelope.updatedAt { return }
        }
        guard let passphrase,
              let key = derive(passphrase, salt: envelope.salt, iterations: envelope.iterations),
              let data = try? open(envelope, key: key),
              let contents = try? JSONDecoder().decode(Contents.self, from: data) else { return }
        isApplying = true
        // The first unlock on a device merges: it may hold sign-ins the box
        // has never seen, which replacing would delete. The union is then
        // pushed. Later boxes replace, so removals elsewhere carry over.
        lastRestore = contents.apply(profileScope: profileScope, merging: force)
        isApplying = false
        setLastApplied(profileScope, envelope.updatedAt)
        if force {
            setLocalModified(profileScope, Date())
            requestPush()
        } else {
            setLocalModified(profileScope, nil)
        }
        NotificationCenter.default.post(name: Self.changedNotification, object: nil)
    }

    private func noteLocalChange() {
        // Signed out, a change is the sign-out's own wipe, not new sign-ins.
        guard !isApplying, accountID != nil else { return }
        setLocalModified(ProfileSettings.activeProfileScope, Date())
        if hasPassphrase { requestPush() }
    }

    private func requestPush() {
        NotificationCenter.default.post(name: Self.pushRequestNotification, object: nil)
    }

    /// Asks the sync service for a settings push.
    static let pushRequestNotification = Notification.Name("omni.vault.pushRequested")

    private func refreshStatus() {
        let next: Status
        if accountID == nil {
            next = .unavailable
        } else if anyCachedEnvelope() == nil {
            next = hasPassphrase ? .unlocked : .notSetUp
        } else {
            next = hasPassphrase ? .unlocked : .locked
        }
        if next != status { status = next }
    }

    // MARK: Crypto

    private struct Envelope {
        let salt: Data
        let iterations: Int
        let box: Data
        let updatedAt: Date

        init(salt: Data, iterations: Int, box: Data, updatedAt: Date) {
            self.salt = salt
            self.iterations = iterations
            self.box = box
            self.updatedAt = updatedAt
        }

        init?(json: [String: Any]) {
            guard (json["v"] as? Int ?? 1) == 1,
                  let salt = (json["salt"] as? String).flatMap({ Data(base64Encoded: $0) }),
                  let box = (json["box"] as? String).flatMap({ Data(base64Encoded: $0) }),
                  let iterations = json["iter"] as? Int,
                  let updated = json["updatedAt"] as? Double else { return nil }
            self.salt = salt
            self.iterations = iterations
            self.box = box
            self.updatedAt = Date(timeIntervalSince1970: updated / 1000)
        }

        var json: [String: Any] {
            [
                "v": 1,
                "salt": salt.base64EncodedString(),
                "iter": iterations,
                "box": box.base64EncodedString(),
                "updatedAt": (updatedAt.timeIntervalSince1970 * 1000).rounded(),
            ]
        }
    }

    private func open(_ envelope: Envelope, key: SymmetricKey) throws -> Data {
        try AES.GCM.open(AES.GCM.SealedBox(combined: envelope.box), using: key)
    }

    private func derive(_ passphrase: String, salt: Data, iterations: Int) -> SymmetricKey? {
        let cacheKey = "\(salt.base64EncodedString())|\(iterations)|\(passphrase.hashValue)"
        if let cached = keyCache[cacheKey] { return cached }
        var derived = Data(count: 32)
        let password = Array(passphrase.utf8).map { Int8(bitPattern: $0) }
        let status = derived.withUnsafeMutableBytes { out in
            salt.withUnsafeBytes { saltBytes in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    password, password.count,
                    saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                    UInt32(iterations),
                    out.bindMemory(to: UInt8.self).baseAddress, 32
                )
            }
        }
        guard status == kCCSuccess else { return nil }
        let key = SymmetricKey(data: derived)
        keyCache[cacheKey] = key
        return key
    }

    private static func randomSalt() -> Data {
        Data((0..<16).map { _ in UInt8.random(in: 0...255) })
    }

    // MARK: Local state

    private static let accountKey = "omni.vault.account"
    private static let keychainService = "com.saminaden.omni.vault"

    private var passphrase: String? {
        guard let accountID else { return nil }
        return KeychainItem.read(service: Self.keychainService, account: accountID)
    }

    private func storePassphrase(_ value: String) {
        guard let accountID else { return }
        KeychainItem.save(value, service: Self.keychainService, account: accountID)
    }

    private func scopedKey(_ name: String, _ profileScope: String) -> String {
        "omni.vault.\(name).\(accountID ?? "-").\(profileScope)"
    }

    // The boxes and change times live in a file of their own, not in
    // UserDefaults: every UserDefaults write starts an account upload, and
    // the upload itself writing here cancelled itself in a loop, so no
    // setting from that device reached the account.
    private lazy var state: [String: Any] = Self.loadState()

    private static var stateFile: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("omni-vault-state.plist")
    }

    private static func loadState() -> [String: Any] {
        guard let file = stateFile, let data = try? Data(contentsOf: file),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return [:] }
        return plist
    }

    private func store(_ value: Any?, forKey key: String) {
        state[key] = value
        saveState()
    }

    private func saveState() {
        guard let file = Self.stateFile,
              let data = try? PropertyListSerialization.data(fromPropertyList: state, format: .binary, options: 0) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    private func cache(_ envelope: Envelope, profileScope: String) {
        guard let data = try? JSONSerialization.data(withJSONObject: envelope.json) else { return }
        if (state[scopedKey("box", profileScope)] as? Data) == data { return }
        state[scopedKey("box", profileScope)] = data
        state[scopedKey("box", "any")] = data
        saveState()
    }

    private func cachedEnvelope(_ profileScope: String) -> Envelope? {
        (state[scopedKey("box", profileScope)] as? Data)
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            .flatMap(Envelope.init(json:))
    }

    /// Any profile's box, to test a passphrase against on a profile that has
    /// none yet: the account shares one passphrase.
    private func anyCachedEnvelope() -> Envelope? { cachedEnvelope("any") }

    private func localModified(_ profileScope: String) -> Date? {
        state[scopedKey("modified", profileScope)] as? Date
    }

    private func setLocalModified(_ profileScope: String, _ date: Date?) {
        store(date, forKey: scopedKey("modified", profileScope))
    }

    private func lastApplied(_ profileScope: String) -> Date? {
        state[scopedKey("applied", profileScope)] as? Date
    }

    private func setLastApplied(_ profileScope: String, _ date: Date) {
        guard lastApplied(profileScope) != date else { return }
        store(date, forKey: scopedKey("applied", profileScope))
    }
}

// MARK: - Contents

private extension CredentialVault {
    /// What a profile's box holds.
    struct Contents: Codable {
        /// Profile settings that are secrets or go with them: Trakt and Simkl
        /// sessions, the client IDs they were issued to, IPTV sources, and the
        /// Jellyfin and SMB server lists. Values as property-list data.
        var settings: [String: Data] = [:]
        var simklAccessToken: String?
        var simklRefreshToken: String?
        var jellyfinTokens: [String: String] = [:]
        var smbPasswords: [String: String] = [:]
        /// AI subtitle translation keys, by provider (absent in older boxes).
        var aiSubtitleKeys: [String: String]? = nil

        /// Nothing worth restoring: no sign-in, source or key.
        var isEmpty: Bool {
            let meaningful = settings.keys.filter {
                $0 != SettingsKey.traktClientID && $0 != SettingsKey.traktClientSecret && $0 != SettingsKey.simklClientID
            }
            return meaningful.isEmpty && (simklAccessToken ?? "").isEmpty && jellyfinTokens.isEmpty
                && smbPasswords.isEmpty && (aiSubtitleKeys ?? [:]).isEmpty
        }

        static var settingKeys: [String] {
            TraktAuthStore.credentialKeys + SimklAuthStore.credentialKeys + [
                SettingsKey.traktClientID, SettingsKey.traktClientSecret, SettingsKey.simklClientID,
                SettingsKey.iptvSources, SettingsKey.jellyfinServers, SettingsKey.smbServers,
            ]
        }

        @MainActor
        static func export(profileScope: String) -> Contents {
            let defaults = ProfileSettings.store(for: profileScope)
            var contents = Contents()
            for key in settingKeys {
                guard let value = defaults.object(forKey: key),
                      let data = try? PropertyListSerialization.data(fromPropertyList: [key: value], format: .binary, options: 0)
                else { continue }
                contents.settings[key] = data
            }
            let simkl = SimklKeychainTokenStorage()
            contents.simklAccessToken = simkl.accessToken(for: profileScope)
            contents.simklRefreshToken = simkl.refreshToken(for: profileScope)
            for server in Self.ids(in: defaults, key: SettingsKey.jellyfinServers) {
                let token = JellyfinCredentialStore.token(forServerID: server, profileScope: profileScope)
                if !token.isEmpty { contents.jellyfinTokens[server] = token }
            }
            for server in Self.ids(in: defaults, key: SettingsKey.smbServers) {
                let password = SMBCredentialStore.password(forServerID: server, profileScope: profileScope)
                if !password.isEmpty { contents.smbPasswords[server] = password }
            }
            var aiKeys: [String: String] = [:]
            for provider in AISubtitleProvider.allCases {
                if let key = AISubtitleKeyStore.storedKey(for: provider, profileScope: profileScope), !key.isEmpty {
                    aiKeys[provider.rawValue] = key
                }
            }
            contents.aiSubtitleKeys = aiKeys.isEmpty ? nil : aiKeys
            return contents
        }

        /// Lists merged by `id`: IPTV sources, Jellyfin servers, SMB shares.
        static let listKeys: Set<String> = [SettingsKey.iptvSources, SettingsKey.jellyfinServers, SettingsKey.smbServers]

        /// `merging`: keep what this device has that the box lacks, and
        /// combine the lists, rather than replacing.
        @MainActor
        func apply(profileScope: String, merging: Bool) -> CredentialVault.Summary {
            let defaults = ProfileSettings.store(for: profileScope)
            for key in Self.settingKeys {
                let remote = settings[key]
                    .flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] }?[key]
                if merging, Self.listKeys.contains(key) {
                    if let merged = Self.mergedList(local: defaults.object(forKey: key), remote: remote) {
                        defaults.set(merged, forKey: key)
                    }
                } else if let remote {
                    defaults.set(remote, forKey: key)
                } else if !merging {
                    defaults.removeObject(forKey: key)
                }
            }
            let simkl = SimklKeychainTokenStorage()
            if !merging || simklAccessToken != nil {
                simkl.setAccessToken(simklAccessToken, for: profileScope)
                simkl.setRefreshToken(simklRefreshToken, for: profileScope)
            }
            for (server, token) in jellyfinTokens {
                JellyfinCredentialStore.save(token, forServerID: server, profileScope: profileScope)
            }
            for (server, password) in smbPasswords {
                SMBCredentialStore.save(password, forServerID: server, profileScope: profileScope)
            }
            for provider in AISubtitleProvider.allCases {
                if let key = aiSubtitleKeys?[provider.rawValue], !key.isEmpty {
                    AISubtitleKeyStore.save(key, for: provider, profileScope: profileScope)
                } else if !merging, aiSubtitleKeys != nil {
                    AISubtitleKeyStore.remove(for: provider, profileScope: profileScope)
                }
            }
            if profileScope == ProfileSettings.activeProfileScope {
                JellyfinServerStore.shared.reload()
                SMBServerStore.shared.reload()
            }
            for name in [
                IPTVSourceStore.changedNotification, TraktAuthStore.changedNotification,
                SimklAuthStore.changedNotification,
            ] {
                NotificationCenter.default.post(name: name, object: nil)
            }
            return CredentialVault.Summary(
                iptvSources: IPTVSourceStore.sources(in: defaults).count,
                trakt: !(defaults.string(forKey: TraktAuthStore.credentialKeys[0]) ?? "").isEmpty,
                simkl: !(simklAccessToken ?? "").isEmpty,
                jellyfinServers: Self.ids(in: defaults, key: SettingsKey.jellyfinServers).count,
                smbShares: Self.ids(in: defaults, key: SettingsKey.smbServers).count
            )
        }

        /// Two stored lists (a JSON string or JSON data of objects with `id`)
        /// as one, the box's entries first and this device's after, in the
        /// form the local value had. Nil when neither is there.
        static func mergedList(local: Any?, remote: Any?) -> Any? {
            func decode(_ value: Any?) -> [[String: Any]]? {
                let data = (value as? Data) ?? (value as? String).map { Data($0.utf8) }
                return data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [[String: Any]] }
            }
            let remoteList = decode(remote) ?? []
            let localList = decode(local) ?? []
            guard !remoteList.isEmpty || !localList.isEmpty else { return local ?? remote }
            var seen = Set<String>()
            let merged = (remoteList + localList).filter { item in
                guard let id = item["id"] as? String else { return true }
                return seen.insert(id).inserted
            }
            guard let data = try? JSONSerialization.data(withJSONObject: merged) else { return local ?? remote }
            // Keep the stored form: IPTV sources are a string, servers data.
            if (local ?? remote) is String { return String(data: data, encoding: .utf8) }
            return data
        }

        /// The `id`s in a stored server list.
        static func ids(in defaults: UserDefaults, key: String) -> [String] {
            guard let data = defaults.data(forKey: key),
                  let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
            return list.compactMap { $0["id"] as? String }
        }
    }
}

// MARK: - Keychain

/// One device-only keychain string.
enum KeychainItem {
    static func read(service: String, account: String) -> String? {
        var query = base(service: service, account: account)
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, let value = String(data: data, encoding: .utf8), !value.isEmpty else { return nil }
        return value
    }

    static func save(_ value: String, service: String, account: String) {
        remove(service: service, account: account)
        var query = base(service: service, account: account)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        query[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(query as CFDictionary, nil)
    }

    static func remove(service: String, account: String) {
        SecItemDelete(base(service: service, account: account) as CFDictionary)
    }

    private static func base(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
