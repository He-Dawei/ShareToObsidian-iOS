import Foundation

struct BridgePairingConfig: Codable, Hashable {
    var bridgeURL: String?
    var bridgeAddress: String?
    var token: String?
    var notesRoot: String?
    var createdAt: String?

    var resolvedBridgeAddress: String? {
        bridgeURL ?? bridgeAddress
    }
}
