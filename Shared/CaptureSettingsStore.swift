import Foundation

enum CaptureSettingsStore {
    private static let bridgeAddressKey = "bridgeAddress"
    private static let bridgeTokenKey = "bridgeToken"
    private static let didMigrateKey = "didMigrateSettingsToAppGroup"
    private static var defaults: UserDefaults {
        UserDefaults(suiteName: CaptureFileStore.appGroupIdentifier) ?? .standard
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
        if let url = URL(string: cleaned),
           ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
           url.host != nil {
            bridgeAddress = cleaned
            bridgeToken = ""
            return BridgePairingConfig(bridgeURL: cleaned, bridgeAddress: nil, token: nil, notesRoot: nil, createdAt: nil)
        }

        let data = Data(cleaned.utf8)
        let config = try JSONDecoder().decode(BridgePairingConfig.self, from: data)
        guard let address = config.resolvedBridgeAddress?.trimmingCharacters(in: .whitespacesAndNewlines),
              URL(string: address) != nil else {
            throw URLError(.badURL)
        }
        bridgeAddress = address
        bridgeToken = config.token ?? ""
        return config
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
