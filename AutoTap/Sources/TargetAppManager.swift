//
//  TargetAppManager.swift
//  AutoTap
//
//  目标 App 管理：与 FloatingTap tweak 通过共享 plist 通信。
//  - 枚举已安装 App（LSApplicationWorkspace 私有 API）
//  - 读写 /var/mobile/Library/Preferences/FloatingTap.plist（Targets / IntervalMs）
//  - 打开目标 App
//
//  App 需在 TrollStore/越狱环境运行（platform-application + no-sandbox entitlement），
//  否则无法枚举全部 App 与写入系统偏好目录。
//

import UIKit

enum TargetAppManager {

    static let configPath = "/var/mobile/Library/Preferences/FloatingTap.plist"

    // MARK: - 共享配置

    /// 读取当前目标 App bundleID 列表
    static func loadTargets() -> [String] {
        guard let dict = NSDictionary(contentsOfFile: configPath),
              let targets = dict["Targets"] as? [String] else { return [] }
        return targets
    }

    /// 保存目标 App bundleID 列表
    static func saveTargets(_ ids: [String]) {
        let dict = NSMutableDictionary(contentsOfFile: configPath) ?? NSMutableDictionary()
        dict["Targets"] = ids
        dict.write(toFile: configPath, atomically: true)
    }

    /// 读取连点间隔（毫秒），供 tweak 使用
    static func loadIntervalMs() -> Int {
        guard let dict = NSDictionary(contentsOfFile: configPath),
              let v = dict["IntervalMs"] as? NSNumber else { return 200 }
        return max(1, min(v.intValue, 60_000))
    }

    /// 保存连点间隔（毫秒）
    static func saveIntervalMs(_ ms: Int) {
        let dict = NSMutableDictionary(contentsOfFile: configPath) ?? NSMutableDictionary()
        dict["IntervalMs"] = max(1, min(ms, 60_000))
        dict.write(toFile: configPath, atomically: true)
    }

    // MARK: - 已安装 App 枚举

    struct AppInfo {
        let bundleID: String
        let name: String
    }

    /// 缓存：避免频繁枚举（刷新由外部主动失效，见 invalidateCache）
    private static var cachedApps: [AppInfo]?

    static func invalidateCache() {
        cachedApps = nil
    }

    /// 枚举所有已安装 App（含系统 App，可按需过滤），按显示名排序
    /// 注意：普通 App（含 TrollStore）调用 LSApplicationWorkspace.allApplications()
    /// 受沙盒限制返回空，因此改用**文件系统扫描**安装目录，不依赖私有 API 权限。
    static func installedApps(includeSystem: Bool = false) -> [AppInfo] {
        if let cached = cachedApps { return cached }

        // 候选根目录：覆盖 rootless（Dopamine /var/jb）与非 rootless 两种布局
        let roots: [String] = [
            "/var/containers/Bundle/Application",          // 非 rootless 用户 App
            "/var/jb/var/containers/Bundle/Application",   // Dopamine rootless 用户 App
            "/Applications",                               // 系统 App（非 rootless）
            "/var/jb/Applications"                          // 系统 App（rootless）
        ]

        var found: [String: AppInfo] = [:]  // bundleID -> info（去重）
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

        var result = Array(found.values)
        result.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        cachedApps = result
        return result
    }

    // MARK: - 打开目标 App

    /// 通过 LSApplicationWorkspace 打开目标 App
    @discardableResult
    static func openApp(bundleID: String) -> Bool {
        return LSApplicationWorkspace.default()?.openApplication(withBundleID: bundleID) ?? false
    }
}
