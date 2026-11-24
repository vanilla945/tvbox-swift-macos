import Foundation

/// 外网访问设置：只改写交给 JAR 的 ext，不修改服务器配置。
enum ExternalAccessRewriter {
    struct Settings {
        /// 是否启用 Alist 内网地址替换。
        let enabled: Bool
        /// 用户填写的外网基地址；为空时使用当前点播接口的 origin。
        let baseURL: String

        static var current: Settings {
            let defaults = UserDefaults.standard
            return Settings(
                enabled: defaults.bool(forKey: HawkConfig.EXTERNAL_ACCESS_ENABLED),
                baseURL: defaults.string(forKey: HawkConfig.EXTERNAL_ALIST_BASE_URL) ?? ""
            )
        }
    }

    /// 规范化用户输入的外网基地址，要求 http/https 且带 host。
    static func normalizedBaseURL(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host,
              !host.isEmpty else {
            return nil
        }

        if components.path.isEmpty {
            components.path = "/"
        } else if !components.path.hasSuffix("/") {
            components.path += "/"
        }
        components.query = nil
        components.fragment = nil
        components.user = nil
        components.password = nil
        return components.url?.absoluteString
    }

    /// 提取配置地址的 origin，例如：
    /// `https://example.com:10443/tvbox/my_ext_jar.json`
    /// -> `https://example.com:10443/`
    static func origin(of raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host,
              !host.isEmpty else {
            return nil
        }

        components.path = "/"
        components.query = nil
        components.fragment = nil
        components.user = nil
        components.password = nil
        return components.url?.absoluteString
    }

    /// 计算本次 JAR 调用应使用的外网基地址。
    ///
    /// - 未启用：不替换。
    /// - 填写了外网地址：始终使用该地址（即使当前配置来自内网）。
    /// - 未填写：仅当配置地址本身是外网时，使用其 origin。
    static func resolvedBaseURL(configURL: String, settings: Settings) -> String? {
        guard settings.enabled else { return nil }

        if let explicit = normalizedBaseURL(settings.baseURL) {
            return explicit
        }
        guard let configOrigin = origin(of: configURL),
              let host = URLComponents(string: configOrigin)?.host,
              !isInternalHost(host) else {
            return nil
        }
        return configOrigin
    }

    /// 仅把内网/本机 server 替换为外网基地址；公网 server 保持不变。
    static func rewriteServer(_ server: String, baseURL: String) -> String? {
        guard let host = URLComponents(string: normalizedServerAddress(server))?.host,
              isInternalHost(host) else {
            return nil
        }
        return baseURL
    }

    /// 判断主机名是否属于内网、本机或局域网域名。
    static func isInternalHost(_ rawHost: String) -> Bool {
        let host = rawHost
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !host.isEmpty else { return true }

        if host == "localhost" || host == "::1" || host == "::" {
            return true
        }
        if host.hasSuffix(".local")
            || host.hasSuffix(".lan")
            || host.hasSuffix(".home")
            || host.hasSuffix(".internal") {
            return true
        }

        // IPv6 本机/链路本地/唯一本地地址。
        if host.contains(":") {
            return host.hasPrefix("fe80:")
                || host.hasPrefix("fc")
                || host.hasPrefix("fd")
        }

        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count == 4,
              labels.allSatisfy({ Int($0) != nil }),
              let a = Int(labels[0]),
              let b = Int(labels[1]) else {
            // 单标签主机名通常是 NAS 等局域网设备。
            return !host.contains(".")
        }

        if a == 10 || a == 127 || a == 0 {
            return true
        }
        if a == 192 && b == 168 {
            return true
        }
        if a == 172 && (16...31).contains(b) {
            return true
        }
        if a == 169 && b == 254 {
            return true
        }
        return false
    }

    private static func normalizedServerAddress(_ server: String) -> String {
        let trimmed = server.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("://") {
            return trimmed
        }
        return "http://" + trimmed
    }
}
