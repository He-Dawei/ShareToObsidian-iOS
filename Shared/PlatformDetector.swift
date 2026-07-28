import Foundation

enum PlatformDetector {
    static func detect(url: URL) -> CapturePlatform {
        let host = (url.host ?? "").lowercased()
        if matches(host, domains: ["douyin.com", "iesdouyin.com", "amemv.com"]) {
            return .douyin
        }
        if matches(host, domains: ["bilibili.com", "b23.tv", "bili2233.cn"]) {
            return .bilibili
        }
        if matches(host, domains: ["xiaohongshu.com", "xhslink.com"]) {
            return .xiaohongshu
        }
        if matches(host, domains: ["weixin.qq.com", "mp.weixin.qq.com"]) {
            return .wechat
        }
        if !host.isEmpty {
            return .web
        }
        return .unknown
    }

    private static func matches(_ host: String, domains: [String]) -> Bool {
        domains.contains { host == $0 || host.hasSuffix("." + $0) }
    }
}
