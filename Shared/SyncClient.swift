import Foundation

struct SyncClient {
    var bridgeBaseURL: URL
    var bearerToken: String?

    private enum Timeout {
        static let fastPush: TimeInterval = 3
        static let normalPush: TimeInterval = 20
        static let health: TimeInterval = 5
        static let draft: TimeInterval = 90
        static let metadata: TimeInterval = 45
        static let remoteCapture: TimeInterval = 10
        static let delete: TimeInterval = 15
    }

    func push(_ item: CaptureItem, fast: Bool = false) async throws -> SyncPushResult {
        var request = makeRequest(
            path: "captures",
            method: "POST",
            queryItems: fast ? [URLQueryItem(name: "fast", value: "1")] : [],
            timeoutInterval: fast ? Timeout.fastPush : Timeout.normalPush
        )
        request.httpMethod = "POST"
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder.captureEncoder.encode(item)

        let (data, response) = try await URLSession.shared.data(for: request)
        try validateHTTPResponse(response, data: data)
        return try JSONDecoder.captureDecoder.decode(SyncPushResult.self, from: data)
    }

    func health() async throws -> BridgeHealth {
        let request = makeRequest(path: "health", method: "GET", timeoutInterval: Timeout.health)
        let (data, response) = try await URLSession.shared.data(for: request)
        try validateHTTPResponse(response, data: data)
        return try JSONDecoder.captureDecoder.decode(BridgeHealth.self, from: data)
    }

    func generateDrafts(for item: CaptureItem) async throws -> MarkdownDraft {
        var request = makeRequest(path: "drafts", method: "POST", timeoutInterval: Timeout.draft)
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder.captureEncoder.encode(item)

        let (data, response) = try await URLSession.shared.data(for: request)
        try validateHTTPResponse(response, data: data)
        return try JSONDecoder.captureDecoder.decode(MarkdownDraft.self, from: data)
    }

    func refreshMetadata(for item: CaptureItem) async throws -> CaptureItem {
        var request = makeRequest(path: "metadata", method: "POST", timeoutInterval: Timeout.metadata)
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder.captureEncoder.encode(item)

        let (data, response) = try await URLSession.shared.data(for: request)
        try validateHTTPResponse(response, data: data)
        return try JSONDecoder.captureDecoder.decode(CaptureItem.self, from: data)
    }

    func fetchRemoteCapture(path: String) async throws -> CaptureItem {
        var request = makeRequest(path: "captures/read", method: "POST", timeoutInterval: Timeout.remoteCapture)
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder.captureEncoder.encode(ReadCaptureRequest(path: path))

        let (data, response) = try await URLSession.shared.data(for: request)
        try validateHTTPResponse(response, data: data)
        return try JSONDecoder.captureDecoder.decode(ReadCaptureResponse.self, from: data).item
    }

    func deleteRemoteNote(path: String) async throws {
        var request = makeRequest(path: "captures/delete", method: "POST", timeoutInterval: Timeout.delete)
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder.captureEncoder.encode(DeleteCaptureRequest(path: path))

        let (data, response) = try await URLSession.shared.data(for: request)
        try validateHTTPResponse(response, data: data)
    }

    private func validateHTTPResponse(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: Data(data.prefix(500)), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let bridgeMessage = try? JSONDecoder.captureDecoder.decode(BridgeErrorEnvelope.self, from: data).error.message
            throw SyncClientHTTPError(
                statusCode: http.statusCode,
                bridgeMessage: bridgeMessage,
                responseBody: body?.isEmpty == false ? body : nil
            )
        }
    }

    private func makeRequest(
        path: String,
        method: String,
        queryItems: [URLQueryItem] = [],
        timeoutInterval: TimeInterval
    ) -> URLRequest {
        var components = URLComponents(url: bridgeBaseURL, resolvingAgainstBaseURL: false)
        let basePath = components?.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""
        let endpointPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components?.path = "/" + [basePath, endpointPath].filter { !$0.isEmpty }.joined(separator: "/")
        if !queryItems.isEmpty {
            let existing = components?.queryItems ?? []
            components?.queryItems = existing + queryItems
        }

        let url = components?.url ?? bridgeBaseURL.appendingPathComponent(endpointPath)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeoutInterval
        if let bearerToken, !bearerToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        }
        return request
    }
}

struct BridgeHealth: Codable, Hashable {
    var ok: Bool
    var queueWritable: Bool?
    var notesRoot: String?
    var aiEnabled: Bool?
    var aiConfigured: Bool?
    var aiProvider: String?
}

struct SyncPushResult: Codable, Hashable {
    var ok: Bool
    var path: String
    var relativePath: String?
    var item: CaptureItem?
}

private struct DeleteCaptureRequest: Codable {
    var path: String
}

private struct ReadCaptureRequest: Codable {
    var path: String
}

private struct ReadCaptureResponse: Codable {
    var ok: Bool
    var item: CaptureItem
}

private struct BridgeErrorEnvelope: Codable, Hashable {
    var error: BridgeError

    struct BridgeError: Codable, Hashable {
        var code: String?
        var message: String?
    }
}

private struct SyncClientHTTPError: LocalizedError, Hashable {
    var statusCode: Int
    var bridgeMessage: String?
    var responseBody: String?

    var errorDescription: String? {
        if statusCode == 401 {
            return bridgeMessage ?? "Bridge authentication failed (401). Check Bridge Token."
        }
        if let bridgeMessage, !bridgeMessage.isEmpty {
            return "Bridge request failed with HTTP \(statusCode): \(bridgeMessage)"
        }
        if let responseBody {
            return "Bridge request failed with HTTP \(statusCode): \(responseBody)"
        }
        return "Bridge request failed with HTTP \(statusCode)."
    }
}
