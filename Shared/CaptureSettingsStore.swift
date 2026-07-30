import Foundation

enum CaptureSettingsStore {
    private static let bridgeAddressKey = "bridgeAddress"
    private static let bridgeTokenKey = "bridgeToken"
    private static let didMigrateKey = "didMigrateSettingsToAppGroup"
    private static var defaults: UserDefaults {
        if CaptureFileStore.hasSharedAppGroup,
           let sharedDefaults = UserDefaults(suiteName: CaptureFileStore.appGroupIdentifier) {
            return sharedDefaults
        }
        return .standard
    }

    static var isConfiguredForDevice: Bool {
        guard let url = URL(string: bridgeAddress),
              let host = url.host?.lowercased(),
              !["127.0.0.1", "localhost", "::1"].contains(host) else {
            return false
        }
        return !bridgeToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static var pairingText: String {
        let config = BridgePairingConfig(
            bridgeURL: bridgeAddress,
            bridgeAddress: nil,
            token: bridgeToken,
            notesRoot: nil,
            createdAt: nil
        )
        guard let data = try? JSONEncoder().encode(config),
              let text = String(data: data, encoding: .utf8) else {
            return ""
        }
        return text
    }

    static var bridgeAddress: String {
        get {
            migrateLegacySettingsIfNeeded()
            return defaults.string(forKey: bridgeAddressKey) ?? "http://127.0.0.1:8765"
        }
        set {
            defaults.set(newValue, forKey: bridgeAddressKey)
            UserDefaults.standard.set(newValue, forKey: bridgeAddressKey)
        }
    }

    static var bridgeToken: String {
        get {
            migrateLegacySettingsIfNeeded()
            return defaults.string(forKey: bridgeTokenKey) ?? ""
        }
        set {
            defaults.set(newValue, forKey: bridgeTokenKey)
            UserDefaults.standard.set(newValue, forKey: bridgeTokenKey)
        }
    }

    static func applyPairingText(_ text: String) throws -> BridgePairingConfig {
        let cleaned = text
            .replacingOccurrences(of: "\u{feff}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if isValidBridgeAddress(cleaned) {
            bridgeAddress = cleaned
            bridgeToken = ""
            return BridgePairingConfig(bridgeURL: cleaned, bridgeAddress: nil, token: nil, notesRoot: nil, createdAt: nil)
        }

        let data = Data(cleaned.utf8)
        let config = try JSONDecoder().decode(BridgePairingConfig.self, from: data)
        guard let address = config.resolvedBridgeAddress?.trimmingCharacters(in: .whitespacesAndNewlines),
              isValidBridgeAddress(address) else {
            throw URLError(.badURL)
        }
        bridgeAddress = address
        bridgeToken = config.token ?? ""
        return config
    }

    static func applyPairingURL(_ url: URL) throws -> BridgePairingConfig {
        guard url.scheme?.lowercased() == "sharetoobsidian",
              url.host?.lowercased() == "pair",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw URLError(.badURL)
        }

        let queryItems = Dictionary(
            uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
                item.value.map { (item.name, $0) }
            }
        )

        if let configText = queryItems["config"], !configText.isEmpty {
            return try applyPairingText(configText)
        }

        guard let address = queryItems["bridgeURL"] ?? queryItems["bridgeAddress"] ?? queryItems["url"],
              isValidBridgeAddress(address) else {
            throw URLError(.badURL)
        }

        bridgeAddress = address
        bridgeToken = queryItems["token"] ?? ""
        return BridgePairingConfig(
            bridgeURL: address,
            bridgeAddress: nil,
            token: queryItems["token"],
            notesRoot: nil,
            createdAt: nil
        )
    }

    static func applyPairingInput(_ text: String) throws -> BridgePairingConfig {
        let cleaned = text
            .replacingOccurrences(of: "\u{feff}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: cleaned),
           url.scheme?.lowercased() == "sharetoobsidian" {
            return try applyPairingURL(url)
        }
        return try applyPairingText(cleaned)
    }

    private static func isValidBridgeAddress(_ value: String) -> Bool {
        guard let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil else {
            return false
        }
        return true
    }

    private static func migrateLegacySettingsIfNeeded() {
        guard defaults.bool(forKey: didMigrateKey) == false else {
            return
        }
        if defaults.string(forKey: bridgeAddressKey) == nil,
           let legacyAddress = UserDefaults.standard.string(forKey: bridgeAddressKey) {
            defaults.set(legacyAddress, forKey: bridgeAddressKey)
        }
        if defaults.string(forKey: bridgeTokenKey) == nil,
           let legacyToken = UserDefaults.standard.string(forKey: bridgeTokenKey) {
            defaults.set(legacyToken, forKey: bridgeTokenKey)
        }
        defaults.set(true, forKey: didMigrateKey)
    }
}
