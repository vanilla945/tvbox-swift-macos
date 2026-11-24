#if os(macOS)
import Foundation
import CryptoKit

/// type=3 Spider 播放结果。
struct JarPlaybackResult {
    let url: String
    let headers: [String: String]
}

enum JarRuntimeError: LocalizedError {
    case runtimeMissing
    case cannotStart(String)
    case timeout
    case invalidJarReference(String)
    case downloadFailed(String)
    case checksumMismatch
    case invalidResponse
    case credentialsMissing
    case plugin(String)

    var errorDescription: String? {
        switch self {
        case .runtimeMissing:
            return "未找到 JAR 运行时，请先运行 scripts/fetch-yingxia-runtime.sh"
        case .cannotStart(let message):
            return "JAR 运行时启动失败：\(message)"
        case .timeout:
            return "JAR 运行时响应超时，请稍后重试"
        case .invalidJarReference(let value):
            return "无效的 JAR 地址：\(value)"
        case .downloadFailed(let message):
            return "JAR 下载失败：\(message)"
        case .checksumMismatch:
            return "JAR 校验失败，文件可能不完整"
        case .invalidResponse:
            return "JAR 运行时返回了无效响应"
        case .credentialsMissing:
            return "请先在设置中保存小雅 / AList 用户名和密码"
        case .plugin(let message):
            return "Spider 执行失败：\(message)"
        }
    }
}

/// 在独立 JVM 中执行 type=3 Spider JAR。
///
/// 运行时来自 Yingxia 的 JavaHost（GPL-3.0，仅本机自用，不随公开仓库分发）。
/// App 只通过 stdin JSON lines 与 responses/<id>.json 文件通信。
actor JarRuntimeService {
    static let shared = JarRuntimeService()

    nonisolated static var isAvailable: Bool {
        runtimeDirectory() != nil
    }

    private let network = NetworkManager.shared
    private var process: Process?
    private var stdin: FileHandle?
    private var root: URL?
    private var logHandle: FileHandle?
    private var startupTask: Task<Startup, Error>?

    private struct Startup {
        let root: URL
        let process: Process
        let stdin: FileHandle
    }

    private init() {}

    // MARK: - 对外接口

    func home(source: SourceBean) async throws -> (sorts: [MovieSort.SortData], homeVideos: [Movie.Video]) {
        let object = try await invoke(source: source, params: [:], deadline: 150)
        return (parseSorts(object), parseVideos(object, sourceKey: source.key))
    }

    func category(
        source: SourceBean,
        tid: String,
        page: Int,
        filters: [String: String]?
    ) async throws -> [Movie.Video] {
        var params: [String: String] = [
            "t": tid,
            "pg": String(page)
        ]
        // 当前 JavaHost 的 categoryContent 以空筛选表调用；保留入参供后续扩展。
        if let filters, !filters.isEmpty {
            params["_filters"] = filters
                .sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: "&")
        }
        let object = try await invoke(source: source, params: params, deadline: 150)
        return parseVideos(object, sourceKey: source.key)
    }

    func detail(source: SourceBean, id: String) async throws -> VodInfo? {
        // 详情首次加载需要抓取豆瓣元数据，可能超过 10 秒。即使界面 task
        // 被取消也读完响应，避免 JVM 已返回结果而 UI 永远拿不到。
        let object = try await invoke(
            source: source,
            params: ["ids": id],
            deadline: 150,
            honorCancellation: false
        )
        guard let first = (object["list"] as? [[String: Any]])?.first,
              let data = try? JSONSerialization.data(withJSONObject: first),
              var video = try? JSONDecoder().decode(Movie.Video.self, from: data) else {
            return nil
        }
        video.sourceKey = source.key
        let playFrom = stringValue(first["vod_play_from"])
        let playUrl = stringValue(first["vod_play_url"])
        return VodInfo.from(video: video, playFrom: playFrom, playUrl: playUrl)
    }

    func search(source: SourceBean, keyword: String) async throws -> [Movie.Video] {
        let object = try await invoke(
            source: source,
            params: ["wd": keyword, "pg": "1"],
            deadline: 60
        )
        return parseVideos(object, sourceKey: source.key)
    }

    func player(source: SourceBean, flag: String, episodeID: String, detailID: String) async throws -> JarPlaybackResult {
        let object = try await invoke(
            source: source,
            params: ["play": episodeID, "flag": flag, "detailID": detailID],
            deadline: 90,
            honorCancellation: false
        )
        let parse = intValue(object["parse"])
        let jx = intValue(object["jx"])
        guard parse != 1, jx != 1 else {
            throw JarRuntimeError.plugin("该播放地址需要网页解析，当前版本暂不支持")
        }
        let url: String
        if let value = object["url"] as? String {
            url = value
        } else if let values = object["url"] as? [String] {
            url = values.first ?? ""
        } else {
            url = ""
        }
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw JarRuntimeError.plugin("Spider 没有返回可播放地址")
        }
        if trimmed.lowercased().hasPrefix("magnet:") {
            throw JarRuntimeError.plugin("该线路返回磁力链接，当前播放器不支持")
        }
        return JarPlaybackResult(url: trimmed, headers: sanitizedHeaders(object["header"]))
    }

    // MARK: - JVM 生命周期

    private func ensureStarted() async throws -> Startup {
        if let process, process.isRunning, let root, let stdin {
            return Startup(root: root, process: process, stdin: stdin)
        }
        if let startupTask {
            return try await startupTask.value
        }
        let task = Task { try await startProcess() }
        startupTask = task
        do {
            let value = try await task.value
            startupTask = nil
            return value
        } catch {
            startupTask = nil
            throw error
        }
    }

    private func startProcess() async throws -> Startup {
        guard let host = Self.runtimeDirectory() else { throw JarRuntimeError.runtimeMissing }
        if process != nil {
            stopProcess()
        }

        let base = try Self.runtimeRoot()
        let ready = base.appendingPathComponent("ready.json")
        let responses = base.appendingPathComponent("responses", isDirectory: true)
        try? FileManager.default.removeItem(at: ready)
        try? FileManager.default.removeItem(at: responses)
        try FileManager.default.createDirectory(at: responses, withIntermediateDirectories: true)
        for folder in ["Jars", "Jobs", "Profiles", "Runtimes", "Converted"] {
            try FileManager.default.createDirectory(
                at: base.appendingPathComponent(folder, isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        // 启动时清除上次运行留下的登录文件，稍后按当前 Keychain 凭据重建。
        Self.removeCredentialFiles(in: base)

        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = host.appendingPathComponent("jre/bin/java")
        process.arguments = [
            "--add-opens", "java.base/java.lang=ALL-UNNAMED",
            "--add-opens", "java.base/sun.net.www.protocol.jar=ALL-UNNAMED",
            // 允许 Java 在服务器未发送中间证书时通过 AIA 补齐证书链。
            "-Dcom.sun.security.enableAIAcaIssuers=true",
            "-Dtvbox.lazyDex=true",
            "-Dorg.slf4j.simpleLogger.defaultLogLevel=error",
            "-Djava.io.tmpdir=\(base.path)",
            "-cp", host.appendingPathComponent("host.jar").path + ":" + host.appendingPathComponent("lib/*").path,
            "tvbox.runtime.ProcessHost", base.path
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["TMPDIR"] = base.path
        process.environment = environment
        process.currentDirectoryURL = base
        process.standardInput = input
        process.standardOutput = output
        process.standardError = output

        let logURL = base.appendingPathComponent("host.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let log = try FileHandle(forWritingTo: logURL)
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { try? log.write(contentsOf: data) }
        }

        do {
            try process.run()
        } catch {
            try? log.close()
            throw JarRuntimeError.cannotStart(error.localizedDescription)
        }

        self.process = process
        self.stdin = input.fileHandleForWriting
        self.root = base
        self.logHandle = log

        let deadline = Date().addingTimeInterval(60)
        while !FileManager.default.fileExists(atPath: ready.path) {
            if !process.isRunning {
                let message = Self.logTail(logURL)
                stopProcess()
                throw JarRuntimeError.cannotStart(message)
            }
            if Date() >= deadline {
                stopProcess()
                throw JarRuntimeError.timeout
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        return Startup(root: base, process: process, stdin: input.fileHandleForWriting)
    }

    private func stopProcess() {
        try? stdin?.close()
        if let process, process.isRunning {
            process.terminate()
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        process = nil
        stdin = nil
        root = nil
        try? logHandle?.close()
        logHandle = nil
    }

    // MARK: - 请求

    private func invoke(
        source: SourceBean,
        params: [String: String],
        deadline: Int,
        honorCancellation: Bool = true
    ) async throws -> [String: Any] {
        guard source.type == 3,
              source.api.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("csp_"),
              let jarReference = source.jar,
              !jarReference.isEmpty else {
            throw JarRuntimeError.invalidJarReference(source.jar ?? source.api)
        }
        let startup = try await ensureStarted()
        let jar = try await ensureJar(reference: jarReference)
        let digest = try Self.sha256Hex(of: jar)
        let configURL = await MainActor.run { ApiConfig.shared.configUrl }

        let identity = "\(source.key)|\(source.api)|\(jar.path)|\(digest)"
        let session = String(Self.sha256Hex(identity).prefix(24))
        let profileKey = String(Self.sha256Hex("\(identity)|\(configURL)").prefix(24))
        let job = startup.root.appendingPathComponent("Jobs/\(session)", isDirectory: true)
        let profile = startup.root.appendingPathComponent("Profiles/\(profileKey)", isDirectory: true)
        let runtimeCache = startup.root.appendingPathComponent("Runtimes/\(digest)", isDirectory: true)
        try FileManager.default.createDirectory(at: job, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        let ext = try await Task.detached(priority: .userInitiated) {
            try Self.prepareExtension(
                source: source,
                runtimeCache: runtimeCache,
                configURL: configURL
            )
        }.value

        let input: [String: Any] = [
            "session": session,
            "runtime": digest,
            "runtimeCache": runtimeCache.path,
            "jar": jar.path,
            "cache": job.path,
            "conversionCache": startup.root.appendingPathComponent("Converted").path,
            "profile": profile.path,
            "api": source.api,
            "key": source.key,
            "ext": ext,
            "subscription": configURL,
            "params": params,
            "deadline": deadline
        ]

        let id = UUID().uuidString
        var line = try JSONSerialization.data(withJSONObject: ["id": id, "input": input] as [String: Any])
        line.append(0x0A)
        try startup.stdin.write(contentsOf: line)

        let responseURL = startup.root.appendingPathComponent("responses/\(id).json")
        let end = Date().addingTimeInterval(TimeInterval(deadline + 30))
        while Date() < end {
            if honorCancellation {
                try Task.checkCancellation()
            }
            if let data = try? Data(contentsOf: responseURL) {
                try? FileManager.default.removeItem(at: responseURL)
                return try parseEnvelope(data)
            }
            if !startup.process.isRunning {
                throw JarRuntimeError.cannotStart(Self.logTail(startup.root.appendingPathComponent("host.log")))
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw JarRuntimeError.timeout
    }

    // MARK: - 小雅 / AList 凭据

    /// 把 Keychain 凭据写入 JAR 原版读取的 `.login` 文件，并从 ext 中移除 `login`。
    /// 启用外网访问时，同时把 ext 中的内网 server 替换为外网地址。
    ///
    /// JavaHost 的 SharedPluginRuntime 把 getFilesDir() 映射到
    /// `<runtimeCache>/profile/files`，不是请求里的 `profile`。
    private nonisolated static func prepareExtension(
        source: SourceBean,
        runtimeCache: URL,
        configURL: String
    ) throws -> String {
        let raw = source.ext ?? ""
        let api = source.api.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard api.hasPrefix("csp_alist") else { return raw }

        let credential: AlistCredential
        do {
            guard let loaded = try AlistCredentialStore.loadCredential() else {
                throw JarRuntimeError.credentialsMissing
            }
            credential = loaded
        } catch let error as JarRuntimeError {
            throw error
        } catch {
            throw JarRuntimeError.plugin(error.localizedDescription)
        }

        let username = credential.username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !username.isEmpty, !credential.password.isEmpty else {
            throw JarRuntimeError.credentialsMissing
        }
        guard !credential.password.contains("\n"), !credential.password.contains("\r") else {
            throw JarRuntimeError.plugin("小雅密码不能包含换行")
        }

        guard let data = raw.data(using: .utf8),
              var drives = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw JarRuntimeError.plugin("小雅扩展配置格式错误")
        }

        let externalBase = ExternalAccessRewriter.resolvedBaseURL(
            configURL: configURL,
            settings: .current
        )

        var servers = Set<String>()
        for index in drives.indices {
            drives[index].removeValue(forKey: "login")
            if let baseURL = externalBase,
               let server = drives[index]["server"] as? String,
               let rewritten = ExternalAccessRewriter.rewriteServer(server, baseURL: baseURL) {
                drives[index]["server"] = rewritten
            }
            if let server = drives[index]["server"] as? String,
               !server.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                servers.insert(server)
            }
        }
        guard !servers.isEmpty else {
            throw JarRuntimeError.plugin("小雅扩展配置中没有 server 地址")
        }

        let files = runtimeCache.appendingPathComponent("profile/files", isDirectory: true)
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: files.path)

        for server in servers {
            let file = files.appendingPathComponent(loginFileName(for: server) + ".login")
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("\(username)\n\(credential.password)".utf8).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }

        let rewritten = try JSONSerialization.data(withJSONObject: drives, options: [.withoutEscapingSlashes])
        return String(decoding: rewritten, as: UTF8.self)
    }

    /// 与 AListSh 的 `dVar.o()` 保持一致：先去掉末尾 `/`，再替换 `://` 和 `:`。
    private static func loginFileName(for server: String) -> String {
        let normalized = server.hasSuffix("/") ? String(server.dropLast()) : server
        return normalized
            .replacingOccurrences(of: "://", with: "_")
            .replacingOccurrences(of: ":", with: "_")
    }

    /// 删除所有 JAR 登录缓存；设置页删除凭据时也会调用。
    nonisolated static func clearCredentialFiles() {
        guard let root = try? runtimeRoot() else { return }
        removeCredentialFiles(in: root)
    }

    private nonisolated static func removeCredentialFiles(in root: URL) {
        for folder in ["Profiles", "Runtimes"] {
            removeLoginFiles(
                in: root.appendingPathComponent(folder, isDirectory: true),
                recursive: true
            )
        }
    }

    private nonisolated static func removeLoginFiles(in directory: URL, recursive: Bool) {
        let manager = FileManager.default
        let urls: [URL]
        if recursive {
            guard let enumerator = manager.enumerator(at: directory, includingPropertiesForKeys: nil) else {
                return
            }
            urls = enumerator.compactMap { $0 as? URL }
        } else {
            urls = (try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        }
        for file in urls where file.pathExtension == "login" {
            try? manager.removeItem(at: file)
        }
    }

    // MARK: - JAR 下载与校验

    private func ensureJar(reference: String) async throws -> URL {
        guard let parsed = Self.parseJarReference(reference) else {
            throw JarRuntimeError.invalidJarReference(reference)
        }
        let cacheRoot = try Self.runtimeRoot().appendingPathComponent("Jars", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        let cacheKey = Self.sha256Hex(parsed.url.absoluteString + parsed.checksumSuffix)
        let file = cacheRoot.appendingPathComponent(cacheKey + ".jar")

        if FileManager.default.fileExists(atPath: file.path),
           try Self.verifyChecksum(file: file, algorithm: parsed.algorithm, expected: parsed.checksum) {
            return file
        }

        let data: Data
        do {
            data = try await network.getData(from: parsed.url.absoluteString)
        } catch {
            throw JarRuntimeError.downloadFailed(error.localizedDescription)
        }
        let prefix = String(decoding: data.prefix(256), as: UTF8.self).lowercased()
        guard !prefix.contains("<!doctype"), !prefix.contains("<html") else {
            throw JarRuntimeError.downloadFailed("服务器返回了网页而不是 JAR")
        }
        guard data.count > 4, data[0] == 0x50, data[1] == 0x4B else {
            throw JarRuntimeError.downloadFailed("文件不是有效的 ZIP/JAR")
        }
        if let algorithm = parsed.algorithm,
           let expected = parsed.checksum,
           !Self.verify(data: data, algorithm: algorithm, expected: expected) {
            throw JarRuntimeError.checksumMismatch
        }
        try data.write(to: file, options: .atomic)
        return file
    }

    private struct JarReference {
        let url: URL
        let algorithm: String?
        let checksum: String?
        let checksumSuffix: String
    }

    private static func parseJarReference(_ value: String) -> JarReference? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var raw = trimmed
        var algorithm: String?
        var checksum: String?
        var suffix = ""
        for marker in [";md5;", ";sha256;"] {
            if let range = raw.range(of: marker, options: .caseInsensitive) {
                suffix = String(raw[range.lowerBound...])
                raw = String(raw[..<range.lowerBound])
                algorithm = marker.hasPrefix(";md5") ? "md5" : "sha256"
                checksum = String(suffix.dropFirst(marker.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }
        guard let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return nil
        }
        return JarReference(
            url: url,
            algorithm: algorithm,
            checksum: checksum,
            checksumSuffix: suffix
        )
    }

    private static func verify(data: Data, algorithm: String, expected: String) -> Bool {
        let digest: String
        switch algorithm {
        case "md5":
            digest = Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
        case "sha256":
            digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        default:
            return false
        }
        return digest.caseInsensitiveCompare(expected) == .orderedSame
    }

    private static func verifyChecksum(file: URL, algorithm: String?, expected: String?) throws -> Bool {
        guard let algorithm, let expected else { return true }
        let data = try Data(contentsOf: file)
        return verify(data: data, algorithm: algorithm, expected: expected)
    }

    // MARK: - 响应解析

    private func parseEnvelope(_ data: Data) throws -> [String: Any] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw JarRuntimeError.invalidResponse
        }
        if let error = object["error"] as? String {
            throw JarRuntimeError.plugin(error)
        }
        if let result = object["result"] as? String {
            guard !result.isEmpty else { return [:] }
            guard let payload = result.data(using: .utf8),
                  let value = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
                throw JarRuntimeError.invalidResponse
            }
            return value
        }
        if object["result"] is [String: Any] {
            return object["result"] as? [String: Any] ?? [:]
        }
        return object
    }

    private func parseSorts(_ object: [String: Any]) -> [MovieSort.SortData] {
        guard let classes = object["class"] as? [[String: Any]] else { return [] }
        return classes.compactMap { item in
            let id = stringValue(item["type_id"])
            guard !id.isEmpty else { return nil }
            return MovieSort.SortData(id: id, name: stringValue(item["type_name"]))
        }
    }

    private func parseVideos(_ object: [String: Any], sourceKey: String) -> [Movie.Video] {
        guard let list = object["list"] as? [[String: Any]] else { return [] }
        return list.compactMap { item in
            guard let data = try? JSONSerialization.data(withJSONObject: item),
                  var video = try? JSONDecoder().decode(Movie.Video.self, from: data) else {
                return nil
            }
            video.sourceKey = sourceKey
            return video
        }
    }

    private func stringValue(_ value: Any?) -> String {
        if let value = value as? String { return value }
        if let value = value as? Int { return String(value) }
        if let value = value as? NSNumber { return value.stringValue }
        return ""
    }

    private func intValue(_ value: Any?) -> Int {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) ?? 0 }
        return 0
    }

    private func sanitizedHeaders(_ value: Any?) -> [String: String] {
        var headers: [String: String] = [:]
        if let dictionary = value as? [String: String] {
            headers = dictionary
        } else if let dictionary = value as? [String: Any] {
            for (name, value) in dictionary {
                if let text = value as? String { headers[name] = text }
            }
        } else if let text = value as? String,
                  let data = text.data(using: .utf8),
                  let dictionary = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
            headers = dictionary
        }
        var result: [String: String] = [:]
        for (name, value) in headers.prefix(32) {
            let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedName.isEmpty,
                  trimmedName.count <= 64,
                  value.count <= 8_192,
                  !trimmedName.contains("\r"), !trimmedName.contains("\n"),
                  !value.contains("\r"), !value.contains("\n") else {
                continue
            }
            result[trimmedName] = value
        }
        return result
    }

    // MARK: - 路径与哈希

    nonisolated static func runtimeDirectory() -> URL? {
        if let resources = Bundle.main.resourceURL {
            let bundled = resources.appendingPathComponent("JavaHost", isDirectory: true)
            if isRuntime(at: bundled) { return bundled }
        }
        #if DEBUG
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("vendor/yingxia-java-host/JavaHost", isDirectory: true)
        if isRuntime(at: source) { return source }
        #endif
        return nil
    }

    nonisolated private static func isRuntime(at url: URL) -> Bool {
        FileManager.default.isExecutableFile(atPath: url.appendingPathComponent("jre/bin/java").path)
            && FileManager.default.fileExists(atPath: url.appendingPathComponent("host.jar").path)
    }

    private static func runtimeRoot() throws -> URL {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TVBox/JarRuntime", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private static func sha256Hex(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func sha256Hex(of file: URL) throws -> String {
        let data = try Data(contentsOf: file)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func logTail(_ url: URL, limit: Int = 1200) -> String {
        guard let data = try? Data(contentsOf: url) else { return "JVM 进程已退出" }
        let text = String(decoding: data.suffix(limit), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "JVM 进程已退出" : text
    }
}
#endif
