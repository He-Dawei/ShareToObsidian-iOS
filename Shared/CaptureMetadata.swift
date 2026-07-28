import Foundation

struct CaptureMetadata: Codable, Hashable {
    var title: String? = nil
    var description: String? = nil
    var uploader: String? = nil
    var channel: String? = nil
    var duration: Double? = nil
    var viewCount: Int? = nil
    var likeCount: Int? = nil
    var thumbnail: URL? = nil
    var webpageURL: URL? = nil
    var extractor: String? = nil
    var transcript: String? = nil
    var contentText: String? = nil
    var metadataError: String? = nil

    init(
        title: String? = nil,
        description: String? = nil,
        uploader: String? = nil,
        channel: String? = nil,
        duration: Double? = nil,
        viewCount: Int? = nil,
        likeCount: Int? = nil,
        thumbnail: URL? = nil,
        webpageURL: URL? = nil,
        extractor: String? = nil,
        transcript: String? = nil,
        contentText: String? = nil,
        metadataError: String? = nil
    ) {
        self.title = title
        self.description = description
        self.uploader = uploader
        self.channel = channel
        self.duration = duration
        self.viewCount = viewCount
        self.likeCount = likeCount
        self.thumbnail = thumbnail
        self.webpageURL = webpageURL
        self.extractor = extractor
        self.transcript = transcript
        self.contentText = contentText
        self.metadataError = metadataError
    }

    var authorText: String? {
        uploader ?? channel
    }

    var transcriptText: String? {
        let value = transcript ?? contentText
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return value
    }

    enum CodingKeys: String, CodingKey {
        case title
        case description
        case uploader
        case channel
        case duration
        case viewCount = "view_count"
        case likeCount = "like_count"
        case thumbnail
        case webpageURL = "webpage_url"
        case extractor
        case transcript
        case contentText = "content_text"
        case metadataError = "metadata_error"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decodeStringIfPresent(.title)
        description = try container.decodeStringIfPresent(.description)
        uploader = try container.decodeStringIfPresent(.uploader)
        channel = try container.decodeStringIfPresent(.channel)
        duration = try container.decodeFlexibleDoubleIfPresent(.duration)
        viewCount = try container.decodeFlexibleIntIfPresent(.viewCount)
        likeCount = try container.decodeFlexibleIntIfPresent(.likeCount)
        thumbnail = try container.decodeURLIfPresent(.thumbnail)
        webpageURL = try container.decodeURLIfPresent(.webpageURL)
        extractor = try container.decodeStringIfPresent(.extractor)
        transcript = try container.decodeStringIfPresent(.transcript)
        contentText = try container.decodeStringIfPresent(.contentText)
        metadataError = try container.decodeStringIfPresent(.metadataError)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encodeIfPresent(description, forKey: .description)
        try container.encodeIfPresent(uploader, forKey: .uploader)
        try container.encodeIfPresent(channel, forKey: .channel)
        try container.encodeIfPresent(duration, forKey: .duration)
        try container.encodeIfPresent(viewCount, forKey: .viewCount)
        try container.encodeIfPresent(likeCount, forKey: .likeCount)
        try container.encodeIfPresent(thumbnail?.absoluteString, forKey: .thumbnail)
        try container.encodeIfPresent(webpageURL?.absoluteString, forKey: .webpageURL)
        try container.encodeIfPresent(extractor, forKey: .extractor)
        try container.encodeIfPresent(transcript, forKey: .transcript)
        try container.encodeIfPresent(contentText, forKey: .contentText)
        try container.encodeIfPresent(metadataError, forKey: .metadataError)
    }
}

private extension KeyedDecodingContainer where Key == CaptureMetadata.CodingKeys {
    func decodeStringIfPresent(_ key: Key) throws -> String? {
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            return value
        }
        if let value = try? decodeIfPresent(Int.self, forKey: key) {
            return String(value)
        }
        if let value = try? decodeIfPresent(Double.self, forKey: key) {
            return String(value)
        }
        return nil
    }

    func decodeFlexibleDoubleIfPresent(_ key: Key) throws -> Double? {
        if let value = try? decodeIfPresent(Double.self, forKey: key) {
            return value
        }
        if let value = try? decodeIfPresent(Int.self, forKey: key) {
            return Double(value)
        }
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            return Double(value.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    func decodeFlexibleIntIfPresent(_ key: Key) throws -> Int? {
        if let value = try? decodeIfPresent(Int.self, forKey: key) {
            return value
        }
        if let value = try? decodeIfPresent(Double.self, forKey: key) {
            return Int(value)
        }
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            return Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    func decodeURLIfPresent(_ key: Key) throws -> URL? {
        guard let value = try decodeStringIfPresent(key) else {
            return nil
        }
        guard let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              url.host != nil else {
            return nil
        }
        return url
    }
}
