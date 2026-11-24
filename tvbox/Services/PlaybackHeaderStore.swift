import Foundation

/// 按播放地址保存 Spider 返回的 HTTP 请求头，供播放器创建媒体时读取。
final class PlaybackHeaderStore {
    static let shared = PlaybackHeaderStore()

    private let lock = NSLock()
    private var headersByURL: [String: [String: String]] = [:]

    private init() {}

    func set(_ headers: [String: String], for url: String) {
        lock.lock()
        defer { lock.unlock() }
        if headers.isEmpty {
            headersByURL.removeValue(forKey: url)
        } else {
            headersByURL[url] = headers
        }
    }

    func headers(for url: String) -> [String: String] {
        lock.lock()
        defer { lock.unlock() }
        return headersByURL[url] ?? [:]
    }
}
