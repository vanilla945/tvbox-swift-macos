import Foundation
#if os(macOS)
import AppKit
#endif

/// 播放器引擎类型
enum PlayerEngine: Int, CaseIterable, Identifiable {
    /// 系统 AVPlayer 内核。
    case system = 0
    /// VLC 内核（需编译时可导入 VLCKitSPM）。
    case vlc = 10
    /// IINA 外部播放器（仅 macOS 点播）。
    case iina = 20

    var id: Int { rawValue }

    /// UI 展示名。
    var title: String {
        switch self {
        case .system:
            return "系统播放器"
        case .vlc:
            return "VLC播放器"
        case .iina:
            return "IINA 播放器"
        }
    }

    /// 当前构建产物是否包含 VLC 能力。
    static var isVLCAvailable: Bool {
        #if canImport(VLCKitSPM)
        return true
        #else
        return false
        #endif
    }

    /// IINA 是否已安装且带有命令行工具。
    static var isIINAAvailable: Bool {
        #if os(macOS)
        return iinaCLIURL != nil
        #else
        return false
        #endif
    }

    #if os(macOS)
    /// IINA 应用位置（支持 /Applications 和 ~/Applications）。
    static var iinaApplicationURL: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.colliderli.iina")
    }

    /// IINA 自带的命令行工具，用于传递 mpv 参数并建立 IPC。
    static var iinaCLIURL: URL? {
        guard let app = iinaApplicationURL else { return nil }
        let cli = app.appendingPathComponent("Contents/MacOS/iina-cli")
        return FileManager.default.isExecutableFile(atPath: cli.path) ? cli : nil
    }
    #endif

    /// 点播可选播放器。
    static var vodEngines: [PlayerEngine] {
        var engines: [PlayerEngine] = [.system]
        if isVLCAvailable {
            engines.append(.vlc)
        }
        if isIINAAvailable {
            engines.append(.iina)
        }
        return engines
    }

    /// 直播可选播放器；IINA 只用于点播。
    static var liveEngines: [PlayerEngine] {
        var engines: [PlayerEngine] = [.system]
        if isVLCAvailable {
            engines.append(.vlc)
        }
        return engines
    }

    /// 从持久化值恢复播放器选项，并自动兜底到可用引擎。
    static func fromStoredValue(_ rawValue: Int) -> PlayerEngine {
        guard let engine = PlayerEngine(rawValue: rawValue) else {
            return .system
        }

        if engine == .vlc && !isVLCAvailable {
            return .system
        }
        if engine == .iina && !isIINAAvailable {
            return .system
        }

        return engine
    }
}

/// 视频解码模式
enum VideoDecodeMode: Int, CaseIterable, Identifiable {
    /// 自动策略，优先硬解，失败时用户可切换。
    case auto = 0
    /// 强制硬解。
    case hardware = 1
    /// 强制软解。
    case software = 2
    
    var id: Int { rawValue }
    
    var title: String {
        switch self {
        case .auto:
            return "自动"
        case .hardware:
            return "硬解码"
        case .software:
            return "软解码"
        }
    }
    
    static func fromStoredValue(_ rawValue: Int) -> VideoDecodeMode {
        VideoDecodeMode(rawValue: rawValue) ?? .auto
    }
    
    /// VLC 媒体选项
    /// 返回 `avcodec-hw` 对应的值。
    var vlcHardwareDecodeOption: String? {
        switch self {
        case .auto:
            // 自动模式默认硬解优先，异常时用户仍可手动切到软解。
            return "any"
        case .hardware:
            return "any"
        case .software:
            return "none"
        }
    }
}

/// VLC 缓冲策略
enum VLCBufferMode: Int, CaseIterable, Identifiable {
    /// 低延迟优先，适合直播但容错较低。
    case lowLatency = 0
    /// 兼顾延迟与稳定性，作为默认策略。
    case balanced = 1
    /// 稳定流畅优先，允许更高缓冲。
    case smooth = 2

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .lowLatency:
            return "低延迟"
        case .balanced:
            return "均衡"
        case .smooth:
            return "流畅优先"
        }
    }

    static var defaultMode: VLCBufferMode { .balanced }

    static func fromStoredValue(_ rawValue: Int) -> VLCBufferMode {
        VLCBufferMode(rawValue: rawValue) ?? defaultMode
    }

    var enableFrameDrop: Bool {
        self == .lowLatency
    }

    /// 根据直播/点播场景输出三类缓存值（单位毫秒）。
    /// - Parameters:
    ///   - isLive: 是否直播场景
    /// - Returns: network/live/file 三类缓存配置
    func cacheConfig(isLive: Bool) -> (network: Int, live: Int, file: Int) {
        switch self {
        case .lowLatency:
            if isLive {
                return (network: 1200, live: 1200, file: 1600)
            }
            return (network: 1800, live: 1600, file: 2400)
        case .balanced:
            if isLive {
                return (network: 2600, live: 2600, file: 3200)
            }
            return (network: 6000, live: 5000, file: 6400)
        case .smooth:
            if isLive {
                return (network: 4200, live: 4200, file: 5200)
            }
            return (network: 8000, live: 6800, file: 8400)
        }
    }
}
