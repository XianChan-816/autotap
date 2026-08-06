//
//  TargetAppManager.swift
//  AutoTap
//
//  v1.0.53：与 FloatingTap tweak 通过 CFPreferences（cfprefsd 守护进程）通信，零第三方依赖。
//  Dopamine rootless 官方无内置 rocketbootstrap（release note: "No rocketbootstrap / IPC"），
//  CFMessagePort + RocketBootstrap 方案实测既崩 SB 又不通（两次 Safe Mode），v1.0.53 废弃。
//
//  协议（与 FloatingTap/Tweak.xm 一字不差）：
//    - 共享 appID = "com.floatingtap.shared"（kCFPreferencesCurrentUser / kCFPreferencesAnyHost）
//    - tweak 写：_loaded=true, _hbtimets=epoch秒, _apps=dict(bundleID -> displayName)
//    - App  写：_config=XML plist data（ClickX/ClickY/IntervalMs）
//    - Darwin 通知：appStarted / configUpdated（App 启动/改配置时发，tweak 常驻 SB 收）
//  App 前台定时 pollTweakData() 读共享偏好（心跳/App 列表），无需常驻回调。
//

import UIKit
import CoreFoundation
import Darwin

enum TargetAppManager {

    // MARK: - CFPreferences 通信（v1.0.53）

    private static let sharedAppID = "com.floatingtap.shared" as CFString

    /// 心跳 / App 列表更新后的 UI 刷新回调
    private static var onTweakData: (() -> Void)?

    /// 最后一次收到 tweak 心跳的 epoch 秒
    static private(set) var lastHeartbeatTime: TimeInterval = 0

    /// tweak 是否已加载（心跳新鲜度 < 120s）
    static var tweakLoaded: Bool {
        return lastHeartbeatTime > 0 && (Date().timeIntervalSince1970 - lastHeartbeatTime) < 120
    }

    /// 最近一次从 tweak 读到的 App 列表（bundleID -> displayName）
    private static var prefsApps: [String: String] = [:]

    /// 读一条共享偏好（current user / any host；SDK 导入为 CFPropertyList?，ARC 管理）
    private static func readPref(_ key: String) -> CFPropertyList? {
        return CFPreferencesCopyValue(key as CFString, sharedAppID,
                                      kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    }

    /// 写一条共享偏好（App 侧）
    private static func writePref(_ key: String, _ value: CFPropertyList) {
        CFPreferencesSetValue(key as CFString, value, sharedAppID,
                              kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        CFPreferencesAppSynchronize(sharedAppID)
    }

    /// 轮询读 tweak 心跳 + App 列表（App 前台定时调用，如 3s 一次）
    static func pollTweakData() {
        // 心跳：只看 _hbtimets（epoch 秒；CFNumber ↔ NSNumber toll-free 桥接）
        if let t = readPref("_hbtimets") as? NSNumber {
            let epoch = t.doubleValue
            if epoch > 0 { lastHeartbeatTime = epoch }
        }
        // App 列表
        if let dict = readPref("_apps") as? NSDictionary {
            var mapped: [String: String] = [:]
            for (k, v) in dict {
                if let key = k as? String { mapped[key] = "\(v)" }
            }
            if !mapped.isEmpty {
                prefsApps = mapped
                invalidateCache()
            }
        }
        DispatchQueue.main.async { onTweakData?() }
    }

    // MARK: - Darwin 通知名（跨进程 ABI，与 tweak 一字不差）

    static let notifyAppStartedName = "com.floatingtap.autotap.appStarted"
    static let notifyConfigUpdatedName = "com.floatingtap.autotap.configUpdated"

    // MARK: - 启动与监听

    /// App 启动：发 Darwin 唤醒（tweak 收到后写心跳 + App 列表到共享偏好），并立即轮询一次
    static func notifyAppStarted() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterPostNotification(center,
            CFNotificationName(rawValue: notifyAppStartedName as CFString), nil, nil, true)
        pollTweakData()
    }

    /// 监听 tweak 数据更新（每次 pollTweakData 读到新数据后回调）
    static func startListeningForTweakUpdates(handler: @escaping () -> Void) {
        onTweakData = handler
    }

    // MARK: - 配置（内存缓存 + CFPreferences 推送 + Darwin 唤醒）

    private static var configCache: [String: Any] = [:]

    private static func pushConfig() {
        var dict: [String: Any] = [:]
        dict["ClickX"] = configCache["ClickX"] ?? 0.5
        dict["ClickY"] = configCache["ClickY"] ?? 0.5
        dict["IntervalMs"] = configCache["IntervalMs"] ?? 200
        if let data = try? PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0) {
            writePref("_config", data as CFData)
        }
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterPostNotification(center,
            CFNotificationName(rawValue: notifyConfigUpdatedName as CFString), nil, nil, true)
    }

    private static func storeConfig(_ key: String, _ value: Any) {
        configCache[key] = value
        pushConfig()
    }

    /// 读取当前目标 App bundleID 列表
    static func loadTargets() -> [String] {
        return (configCache["Targets"] as? [String]) ?? []
    }

    /// 保存目标 App bundleID 列表（推给 tweak）
    static func saveTargets(_ ids: [String]) {
        storeConfig("Targets", ids)
    }

    /// 读取连点间隔（毫秒）
    static func loadIntervalMs() -> Int {
        guard let v = configCache["IntervalMs"] as? NSNumber else { return 200 }
        return max(1, min(v.intValue, 60_000))
    }

    /// 保存连点间隔（毫秒，推给 tweak）
    static func saveIntervalMs(_ ms: Int) {
        storeConfig("IntervalMs", max(1, min(ms, 60_000)))
    }

    /// 读取点击位置（归一化 0~1）
    static func loadClick() -> (Double, Double)? {
        guard let x = configCache["ClickX"] as? Double,
              let y = configCache["ClickY"] as? Double else { return nil }
        return (x, y)
    }

    /// 保存点击位置（归一化 0~1，推给 tweak）
    static func saveClick(x: Double, y: Double) {
        configCache["ClickX"] = min(1, max(0, x))
        configCache["ClickY"] = min(1, max(0, y))
        pushConfig()
    }

    // MARK: - 已安装 App 枚举

    struct AppInfo {
        let bundleID: String
        let name: String
    }

    private static var cachedApps: [AppInfo]?

    static func invalidateCache() {
        cachedApps = nil
    }

    /// 枚举所有已安装 App（含系统 App，可按需过滤），按显示名排序。
    /// 主方案：tweak（SB 特权进程）写共享偏好的清单（pollTweakData 已读入 prefsApps）。
    /// 兜底：文件系统扫描安装目录（越狱环境可读）。
    static func installedApps(includeSystem: Bool = false) -> [AppInfo] {
        if let cached = cachedApps { return cached }
        var found: [String: AppInfo] = [:]

        // 方式 1（主）：tweak 枚举写进共享偏好的清单
        if !prefsApps.isEmpty {
            for (bid, name) in prefsApps {
                if !includeSystem && bid.hasPrefix("com.apple.") { continue }
                found[bid] = AppInfo(bundleID: bid, name: name.isEmpty ? bid : name)
            }
        }

        // 方式 2（兜底）：文件系统扫描安装目录
        if found.isEmpty {
            let roots = [
                "/var/containers/Bundle/Application",
                "/private/var/containers/Bundle/Application",
                "/var/jb/var/containers/Bundle/Application",
                "/private/var/jb/var/containers/Bundle/Application",
                "/Applications",
                "/var/jb/Applications",
            ]
            let fm = FileManager.default
            for root in roots {
                guard let dirs = try? fm.contentsOfDirectory(atPath: root) else { continue }
                for dir in dirs {
                    let appDir = (root as NSString).appendingPathComponent(dir)
                    guard let apps = try? fm.contentsOfDirectory(atPath: appDir) else { continue }
                    for appName in apps where appName.hasSuffix(".app") {
                        let infoPath = ((appDir as NSString).appendingPathComponent(appName)
                                        as NSString).appendingPathComponent("Info.plist")
                        guard let dict = NSDictionary(contentsOfFile: infoPath),
                              let bid = dict["CFBundleIdentifier"] as? String, !bid.isEmpty else { continue }
                        if !includeSystem && bid.hasPrefix("com.apple.") { continue }
                        let display = (dict["CFBundleDisplayName"] as? String)
                            ?? (dict["CFBundleName"] as? String)
                            ?? bid
                        found[bid] = AppInfo(bundleID: bid, name: display)
                    }
                }
            }
        }

        var result = Array(found.values)
        result.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        cachedApps = result
        return result
    }

    // MARK: - tweak 诊断（v1.0.53：CFPreferences 连通性）

    struct TweakDiagnostic {
        let prefsReady: Bool      // 共享偏好可读（tweak 至少写过一条）
        let tweakLoaded: Bool     // 心跳新鲜（<120s）
        let hbAge: TimeInterval   // 心跳年龄（秒；-1 = 从未收到）
        let appsCount: Int        // 共享偏好里 App 数

        /// 诊断详情（通信状态）
        var pathSummary: String {
            var s = "通信诊断："
            s += "\n  CFPreferences: \(prefsReady ? "已连接 ✓" : "不可用 ✗")"
            if hbAge < 0 {
                s += "\n  心跳: 从未收到 ✗"
            } else {
                s += String(format: "\n  心跳: %.0fs 前 ✓", hbAge)
            }
            s += "\n  App 列表: \(appsCount) 个"
            if !prefsReady {
                s += "\n  → 共享偏好不可用：确认 tweak 已注入、App 无 sandbox（TrollStore）"
            }
            return s
        }

        /// 供 UI 展示的一行状态描述
        var message: String {
            if !prefsReady {
                return "通信未就绪：CFPreferences 共享偏好不可用（确认 FloatingTap.deb 已装并重启）。"
            }
            if !tweakLoaded {
                if hbAge < 0 {
                    return "tweak 未加载：尚未收到心跳（确认 FloatingTap.deb 已装并重启）。"
                }
                return "tweak 心跳过期：\(Int(hbAge))s 前最后一次，请确认 tweak 在运行。"
            }
            if appsCount == 0 {
                return "tweak 已加载 ✓ 心跳正常，但 App 列表为空，等待推送…"
            }
            return "tweak 已加载 ✓ 心跳正常，已收到 \(appsCount) 个 App。"
        }
    }

    static func tweakDiagnostic() -> TweakDiagnostic {
        let age = lastHeartbeatTime > 0 ? Date().timeIntervalSince1970 - lastHeartbeatTime : -1
        let prefsReady = readPref("_loaded") != nil || readPref("_hbtimets") != nil
        return TweakDiagnostic(prefsReady: prefsReady,
                               tweakLoaded: tweakLoaded,
                               hbAge: age,
                               appsCount: prefsApps.count)
    }

    // MARK: - 打开目标 App

    @discardableResult
    static func openApp(bundleID: String) -> Bool {
        return LSApplicationWorkspace.default()?.openApplication(withBundleID: bundleID) ?? false
    }
}
