#if os(macOS)
import Foundation
import Combine
import AppKit
import CoreGraphics
import Darwin

/// 通过 IINA 的 mpv JSON IPC 控制外部播放并回传进度。
///
/// 首次播放启动 `iina-cli` 并指定随机 Unix socket；后续换集复用同一个
/// IINA 窗口，通过 `loadfile` 替换媒体。IINA 关闭后 socket 断开，下次播放
/// 会重新启动。媒体地址和 HTTP 请求头通过 iina-cli 参数传入。
@MainActor
final class IINAPlaybackController: ObservableObject {
    static let shared = IINAPlaybackController()

    enum State: Equatable {
        case idle
        case launching
        case connected
        case failed(String)
    }

    private struct Callbacks {
        let progress: (Double, Double?) -> Void
        let ended: () -> Void
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var currentSessionID: UUID?
    /// 最近一次成功回传的播放位置，窗口关闭后用于重新打开时续播。
    @Published private(set) var lastKnownTime: Double = 0

    private var client: IINAIPCClient?
    private var callbacks: Callbacks?
    private var pendingStartPosition: Double = 0
    private var lastDuration: Double = 0
    private var awaitingFileLoad = false
    private var endedFired = false
    private var sawProgress = false
    private var coreStopped = false
    private var socketPath: String?
    private var socketGeneration = UUID()
    private var windowTimer: Timer?

    private init() {}

    // MARK: - 对外接口

    @discardableResult
    func play(
        url: String,
        startPosition: Double,
        headers: [String: String],
        onProgress: @escaping (Double, Double?) -> Void,
        onEnded: @escaping () -> Void
    ) -> UUID {
        let sessionID = UUID()
        currentSessionID = sessionID
        callbacks = Callbacks(progress: onProgress, ended: onEnded)
        pendingStartPosition = max(startPosition, 0)
        lastKnownTime = max(startPosition, 0)
        lastDuration = 0
        endedFired = false
        awaitingFileLoad = true
        sawProgress = false

        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            fail("播放地址为空")
            return sessionID
        }
        let iinaRunning = !NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.colliderli.iina")
            .isEmpty
        let windowCount = Self.iinaWindowCount()

        if let client, client.isConnected {
            // 关闭 IINA 窗口时 mpv core 可能仍在播放，继续 loadfile 只会出声不出画。
            if coreStopped || windowCount == 0 {
                restartIINA(url: trimmed, headers: headers, sessionID: sessionID)
                return sessionID
            }

            state = .connected
            awaitingFileLoad = true
            sawProgress = false
            coreStopped = false
            startWindowMonitor()
            applyHeaders(headers)
            guard client.send(["command": ["loadfile", trimmed, "replace"]]),
                  client.send(["command": ["set_property", "pause", false]]) else {
                fail("无法向 IINA 发送播放指令")
                return sessionID
            }
            Self.activateIINA()
            return sessionID
        }

        // App 重启后无法确认旧 IINA 实例是否还有播放窗口，直接重启最可靠。
        if iinaRunning {
            restartIINA(url: trimmed, headers: headers, sessionID: sessionID)
            return sessionID
        }

        sawProgress = false
        coreStopped = false
        launch(url: trimmed, headers: headers, sessionID: sessionID)
        return sessionID
    }

    /// 页面离开时只暂停当前会话，保留 IINA 窗口和 IPC，供下次复用。
    func stop(sessionID: UUID) {
        guard currentSessionID == sessionID else { return }
        stopWindowMonitor()
        client?.send(["command": ["set_property", "pause", true]])
        currentSessionID = nil
        callbacks = nil
        awaitingFileLoad = false
        pendingStartPosition = 0
        state = .idle
    }

    /// 切换到系统/VLC 时停止 IINA，避免两个播放器同时出声。
    func stopAll() {
        guard client != nil || currentSessionID != nil else { return }
        stopWindowMonitor()
        client?.send(["command": ["set_property", "pause", true]])
        currentSessionID = nil
        callbacks = nil
        awaitingFileLoad = false
        pendingStartPosition = 0
        state = .idle
    }

    func activate() {
        if Self.iinaWindowCount() == 0 {
            if state == .connected {
                markWindowClosed()
            } else if let url = PlayerEngine.iinaApplicationURL {
                NSWorkspace.shared.open(url)
            }
            return
        }

        Self.activateIINA()
    }

    // MARK: - 启动与 IPC

    private func launch(url: String, headers: [String: String], sessionID: UUID) {
        guard let cli = PlayerEngine.iinaCLIURL else {
            fail("未找到 IINA，请先安装 IINA")
            return
        }
        state = .launching
        awaitingFileLoad = true
        Self.configureIINAWindowSizing()
        let path = Self.makeSocketPath()
        socketPath = path
        try? FileManager.default.removeItem(atPath: path)

        let args = Self.launchArguments(
            url: url,
            headers: headers,
            socketPath: path
        )
        let process = Process()
        process.executableURL = cli
        process.arguments = args
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            fail("IINA 启动失败：\(error.localizedDescription)")
            return
        }

        let generation = UUID()
        socketGeneration = generation
        connect(path: path, sessionID: sessionID, generation: generation)
    }

    /// IINA 关闭窗口后会保留 idle mpv core，loadfile 不会重建窗口。
    /// 彻底重启 IINA 后再打开新的播放窗口。
    private func restartIINA(url: String, headers: [String: String], sessionID: UUID) {
        state = .launching
        stopWindowMonitor()
        awaitingFileLoad = true
        sawProgress = false
        coreStopped = false
        // 让旧 socket 的回调失效，避免终止过程中把状态改成 failed。
        socketGeneration = UUID()
        client?.send(["command": ["set_property", "pause", true]])
        client?.close()
        client = nil
        cleanupSocketFile()

        let apps = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.colliderli.iina"
        )
        guard !apps.isEmpty else {
            launch(url: url, headers: headers, sessionID: sessionID)
            return
        }

        let pids = apps.map { $0.processIdentifier }
        for app in apps {
            app.terminate()
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let deadline = Date().addingTimeInterval(6)
            while Date() < deadline && pids.contains(where: { kill($0, 0) == 0 }) {
                usleep(100_000)
            }
            for pid in pids where kill(pid, 0) == 0 {
                kill(pid, SIGKILL)
            }
            let killDeadline = Date().addingTimeInterval(2)
            while Date() < killDeadline && pids.contains(where: { kill($0, 0) == 0 }) {
                usleep(50_000)
            }
            usleep(500_000)
            DispatchQueue.main.async {
                guard let self, self.currentSessionID == sessionID else { return }
                if pids.allSatisfy({ kill($0, 0) != 0 }) {
                    self.launch(url: url, headers: headers, sessionID: sessionID)
                } else {
                    self.fail("无法关闭 IINA，请手动退出 IINA 后重试")
                }
            }
        }
    }

    private func connect(path: String, sessionID: UUID, generation: UUID) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let fd = Self.connectUnixSocket(path: path, timeout: 10)
            DispatchQueue.main.async {
                guard let self, self.socketGeneration == generation,
                      self.currentSessionID == sessionID else {
                    if fd >= 0 { close(fd) }
                    return
                }
                guard fd >= 0 else {
                    self.fail("IINA 已启动，但无法连接进度同步。请确认 IINA 未被其他窗口占用后重试。")
                    return
                }

                chmod(path, 0o600)
                let client = IINAIPCClient(fd: fd)
                client.start(
                    onEvent: { [weak self] event in
                        DispatchQueue.main.async {
                            guard let self, self.socketGeneration == generation else { return }
                            self.handle(event)
                        }
                    },
                    onDisconnect: { [weak self] in
                        DispatchQueue.main.async {
                            guard let self, self.socketGeneration == generation else { return }
                            self.stopWindowMonitor()
                            self.client = nil
                            self.currentSessionID = nil
                            self.callbacks = nil
                            self.awaitingFileLoad = false
                            self.sawProgress = false
                            self.coreStopped = false
                            self.state = .failed("IINA 已关闭，点击重试。")
                            self.cleanupSocketFile()
                        }
                    }
                )
                self.client = client
                self.state = .connected
                self.startWindowMonitor()
                Self.activateIINA()
                client.send(["command": ["observe_property", 1, "time-pos"]])
                client.send(["command": ["observe_property", 2, "duration"]])
                client.send(["command": ["observe_property", 3, "eof-reached"]])
                client.send(["command": ["observe_property", 4, "idle-active"]])
                client.send(["command": ["set_property", "pause", false]])
                if self.pendingStartPosition > 0 {
                    client.send(["command": ["seek", self.pendingStartPosition, "absolute+exact"]])
                }
            }
        }
    }

    private func applyHeaders(_ headers: [String: String]) {
        let userAgent = Self.headerValue("User-Agent", in: headers) ?? Self.defaultUserAgent
        client?.send(["command": ["set_property", "user-agent", userAgent]])
        client?.send([
            "command": ["set_property", "http-header-fields", Self.headerFields(from: headers)]
        ])
    }

    private func handle(_ event: [String: Any]) {
        guard currentSessionID != nil else { return }
        guard let name = event["event"] as? String else { return }

        switch name {
        case "file-loaded":
            awaitingFileLoad = false
            endedFired = false
            coreStopped = false
            state = .connected
            if pendingStartPosition > 0 {
                client?.send([
                    "command": ["seek", pendingStartPosition, "absolute+exact"]
                ])
                pendingStartPosition = 0
            }

        case "property-change":
            guard let property = event["name"] as? String else { return }
            switch property {
            case "time-pos":
                guard !awaitingFileLoad, let value = Self.doubleValue(event["data"]) else { return }
                sawProgress = true
                // 首次启动时 socket 可能连上得比 file-loaded 晚，用第一条
                // time-pos 再补一次 seek，确保历史续播从正确位置开始。
                if pendingStartPosition > 0 {
                    let target = pendingStartPosition
                    pendingStartPosition = 0
                    client?.send(["command": ["seek", target, "absolute+exact"]])
                    return
                }
                lastKnownTime = value
                callbacks?.progress(value, lastDuration > 0 ? lastDuration : nil)
            case "duration":
                if let value = Self.doubleValue(event["data"]) {
                    lastDuration = value
                }
            case "eof-reached":
                guard !awaitingFileLoad,
                      let flag = event["data"] as? Bool,
                      flag else { return }
                fireEnded()
            case "idle-active":
                guard let idle = event["data"] as? Bool else { return }
                if idle {
                    if sawProgress && !awaitingFileLoad && !endedFired {
                        coreStopped = true
                        markWindowClosed()
                    }
                } else {
                    coreStopped = false
                }
            default:
                break
            }

        case "end-file":
            // IINA 关闭窗口时会对 mpv 发送 stop；正常换集的 end-file
            // 已被 awaitingFileLoad 屏蔽。
            if event["reason"] as? String == "stop",
               sawProgress,
               !awaitingFileLoad,
               !endedFired {
                coreStopped = true
                markWindowClosed()
            }

        default:
            break
        }
    }

    private func fireEnded() {
        guard !endedFired else { return }
        endedFired = true
        callbacks?.ended()
    }

    /// IINA 窗口被关闭：停止进度回调，保留最后位置供“重新播放”续播。
    private func markWindowClosed() {
        guard state == .connected else { return }
        stopWindowMonitor()
        coreStopped = true
        currentSessionID = nil
        callbacks = nil
        awaitingFileLoad = false
        state = .failed("IINA 窗口已关闭，点击重新播放。")
    }

    private func startWindowMonitor() {
        stopWindowMonitor()
        let timer = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.state == .connected, self.sawProgress else { return }
                if Self.iinaWindowCount() == 0 {
                    self.markWindowClosed()
                }
            }
        }
        windowTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopWindowMonitor() {
        windowTimer?.invalidate()
        windowTimer = nil
    }

    private func fail(_ message: String) {
        stopWindowMonitor()
        state = .failed(message)
        callbacks = nil
        awaitingFileLoad = false
        if client == nil {
            cleanupSocketFile()
        }
    }

    private func cleanupSocketFile() {
        if let path = socketPath {
            try? FileManager.default.removeItem(atPath: path)
        }
        socketPath = nil
    }

    // MARK: - 参数与 socket

    nonisolated private static let defaultUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

    nonisolated private static func launchArguments(
        url: String,
        headers: [String: String],
        socketPath: String
    ) -> [String] {
        var args = [
            "--no-stdin",
            "--mpv-ytdl=no",
            "--mpv-resume-playback=no",
            "--mpv-input-ipc-server=\(socketPath)",
            "--mpv-user-agent=\(headerValue("User-Agent", in: headers) ?? defaultUserAgent)"
        ]
        let fields = headerFields(from: headers)
        if !fields.isEmpty {
            args.append("--mpv-http-header-fields=\(fields)")
        }
        args.append(url)
        return args
    }

    /// mpv 的 http-header-fields 是逗号分隔列表，且同名参数会覆盖。
    /// User-Agent 单独通过 --mpv-user-agent 传递，避免值里的逗号被拆分。
    nonisolated private static func headerFields(from headers: [String: String]) -> String {
        headers
            .filter { $0.key.caseInsensitiveCompare("User-Agent") != .orderedSame }
            .filter { name, value in
                !name.isEmpty
                    && !name.contains("\n") && !name.contains("\r")
                    && !value.isEmpty
                    && !value.contains("\n") && !value.contains("\r")
                    && !value.contains(",")
            }
            .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
            .map { "\($0.key): \($0.value)" }
            .joined(separator: ",")
    }

    nonisolated private static func headerValue(
        _ name: String,
        in headers: [String: String]
    ) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    nonisolated private static func makeSocketPath() -> String {
        let manager = FileManager.default
        if let caches = manager.urls(for: .cachesDirectory, in: .userDomainMask).first {
            let directory = caches.appendingPathComponent("TVBox/IINA", isDirectory: true)
            if (try? manager.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )) != nil {
                try? manager.setAttributes(
                    [.posixPermissions: 0o700],
                    ofItemAtPath: directory.path
                )
                return directory
                    .appendingPathComponent("s-\(UUID().uuidString.prefix(8)).sock")
                    .path
            }
        }
        return "/tmp/tvbox-iina-\(UUID().uuidString.prefix(8)).sock"
    }

    /// 让 IINA 每次加载视频都按屏幕可用区域重新调整窗口。
    /// 否则重播时会沿用上次关闭时的小窗口，出现左右不到边。
    nonisolated private static func configureIINAWindowSizing() {
        let appID = "com.colliderli.iina" as CFString
        CFPreferencesSetAppValue(
            "resizeWindowTiming" as CFString,
            NSNumber(value: 0), // always
            appID
        )
        CFPreferencesSetAppValue(
            "resizeWindowOption" as CFString,
            NSNumber(value: 0), // fitScreen
            appID
        )
        CFPreferencesAppSynchronize(appID)
    }

    /// 将 IINA 窗口切到当前桌面并置前。
    ///
    /// 不要改用 `NSWorkspace.openApplication`：IINA 1.5.0 在通过
    /// LaunchServices 激活时会弹出欢迎窗口，盖住播放窗口。
    nonisolated private static func activateIINA() {
        NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.colliderli.iina")
            .first?
            .activate(options: [.activateAllWindows])
    }

    /// 判断 IINA 是否还有播放窗口。窗口关闭后 IINA 进程仍在，但不会重建播放窗口。
    nonisolated static func iinaWindowCount() -> Int {
        guard let app = NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.colliderli.iina")
            .first else {
            return 0
        }
        let pid = app.processIdentifier
        let windows = (CGWindowListCopyWindowInfo(
            [.optionAll, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]]) ?? []

        return windows.reduce(into: 0) { count, window in
            guard let owner = (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  owner == pid,
                  let layer = (window[kCGWindowLayer as String] as? NSNumber)?.intValue,
                  layer == 0,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let width = (bounds["Width"] as? NSNumber)?.doubleValue,
                  let height = (bounds["Height"] as? NSNumber)?.doubleValue,
                  width >= 200, height >= 100 else {
                return
            }
            count += 1
        }
    }

    nonisolated private static func doubleValue(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let value = value as? Double { return value }
        return nil
    }

    nonisolated private static func connectUnixSocket(
        path: String,
        timeout: TimeInterval
    ) -> Int32 {
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path) else {
            return -1
        }
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { return -1 }

            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            withUnsafeMutableBytes(of: &address.sun_path) { raw in
                raw.copyBytes(from: bytes)
            }
            let length = socklen_t(MemoryLayout<sockaddr_un>.size)
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, length)
                }
            }
            if result == 0 { return fd }
            close(fd)
            usleep(100_000)
        } while Date() < deadline
        return -1
    }
}

// MARK: - mpv JSON IPC

private final class IINAIPCClient {
    private let handle: FileHandle
    private let lock = NSLock()
    private var buffer = Data()
    private var closed = false
    private var lastProgressDispatch = Date.distantPast
    private var onEvent: (([String: Any]) -> Void)?
    private var onDisconnect: (() -> Void)?

    init(fd: Int32) {
        handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    var isConnected: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !closed
    }

    func start(
        onEvent: @escaping ([String: Any]) -> Void,
        onDisconnect: @escaping () -> Void
    ) {
        self.onEvent = onEvent
        self.onDisconnect = onDisconnect
        handle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                self?.didDisconnect()
            } else {
                self?.consume(data)
            }
        }
    }

    @discardableResult
    func send(_ object: [String: Any]) -> Bool {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else {
            return false
        }
        var line = data
        line.append(0x0A)

        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return false }
        do {
            try handle.write(contentsOf: line)
            return true
        } catch {
            return false
        }
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[..<newline]
            buffer.removeSubrange(...newline)
            guard !line.isEmpty,
                  let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else {
                continue
            }
            emit(object)
        }
    }

    private func emit(_ object: [String: Any]) {
        if object["event"] as? String == "property-change",
           object["name"] as? String == "time-pos" {
            let now = Date()
            guard now.timeIntervalSince(lastProgressDispatch) >= 1 else { return }
            lastProgressDispatch = now
        }
        onEvent?(object)
    }

    func close() {
        lock.lock()
        guard !closed else {
            lock.unlock()
            return
        }
        closed = true
        lock.unlock()

        handle.readabilityHandler = nil
        try? handle.close()
    }

    private func didDisconnect() {
        lock.lock()
        guard !closed else {
            lock.unlock()
            return
        }
        closed = true
        lock.unlock()

        handle.readabilityHandler = nil
        try? handle.close()
        onDisconnect?()
    }
}
#endif
