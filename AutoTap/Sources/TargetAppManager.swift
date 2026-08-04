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

    /// tweak（SpringBoard）导出的已装 App 清单（mobile 可读路径）
    /// 普通 App 受沙盒 + 文件权限限制无法枚举已装 App，故由 FloatingTap tweak 代劳写入
    static let appsDumpPath = "/var/mobile/Library/Preferences/FloatingTap.apps.plist"

    /// 枚举诊断状态文件（tweak 写）：_count / _error / _time
    static let appsStatusPath = "/var/mobile/Library/Preferences/FloatingTap.apps.status.plist"

    /// tweak 心跳文件（%ctor 立即写）：_loaded / _version / _time
    static let tweakStatusPath = "/var/mobile/Library/Preferences/FloatingTap.tweak.plist"

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

    /// 读取点击位置（归一化 0~1），供 tweak 悬浮球定位（球心=点击点）
    static func loadClick() -> (Double, Double)? {
        guard let dict = NSDictionary(contentsOfFile: configPath),
              let x = dict["ClickX"] as? NSNumber,
              let y = dict["ClickY"] as? NSNumber else { return nil }
        return (x.doubleValue, y.doubleValue)
    }

    /// 保存点击位置（归一化 0~1），tweak 悬浮球读此定位（用户在 App 内调节，目标 App 内不可调）
    static func saveClick(x: Double, y: Double) {
        let dict = NSMutableDictionary(contentsOfFile: configPath) ?? NSMutableDictionary()
        dict["ClickX"] = min(1, max(0, x))
        dict["ClickY"] = min(1, max(0, y))
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

    /// 枚举所有已安装 App（含系统 App，可按需过滤），按显示名排序。
    /// 主方案：读 FloatingTap tweak（SpringBoard 特权进程）写入的 appsDumpPath 清单。
    /// 兜底：文件系统扫描安装目录（部分环境可读）。
    /// 注意：App 进程内直接调 LSApplicationWorkspace.allApplications() 在沙盒/权限下
    /// 返回空，故枚举完全依赖 tweak 导出的清单。
    static func installedApps(includeSystem: Bool = false) -> [AppInfo] {
        if let cached = cachedApps { return cached }

        var found: [String: AppInfo] = [:]  // bundleID -> info（去重）

        // 方式 1（主）：读 tweak 导出的已装 App 清单
        if let dict = NSDictionary(contentsOfFile: appsDumpPath) as? [String: String] {
            for (bid, name) in dict {
                if !includeSystem && bid.hasPrefix("com.apple.") { continue }
                let display = name.isEmpty ? bid : name
                found[bid] = AppInfo(bundleID: bid, name: display)
            }
        }

        // 方式 2（兜底）：文件系统扫描安装目录
        if found.isEmpty {
            let roots: [String] = [
                "/private/var/containers/Bundle/Application",
                "/var/containers/Bundle/Application",
                "/var/jb/var/containers/Bundle/Application",
                "/private/var/jb/var/containers/Bundle/Application",
                "/Applications",
                "/var/jb/Applications"
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

    // MARK: - tweak 诊断

    /// 读取 tweak 状态，用于排查「选择应用列表为空」问题。
    /// - tweakLoaded：心跳文件存在且近期写入（证明 tweak 已加载）
    /// - dumpCount：tweak 导出的 App 数量
    /// - dumpError：tweak 枚举报错信息（若有）
    /// - dumpTime：tweak 最近一次枚举的时间戳
    struct TweakDiagnostic {
        let tweakLoaded: Bool
        let tweakTime: TimeInterval
        let hbExists: Bool
        let hbReadDetail: String?
        let writeTest: String?
        let dumpExists: Bool
        let dumpCount: Int
        let dumpError: String?
        let dumpTime: TimeInterval
        /// 供 UI 展示的一行状态描述
        var message: String {
            if !tweakLoaded {
                var detail = "tweak 未加载："
                if !hbExists {
                    detail += "App 看不到心跳文件（\(tweakStatusPath) 不存在）"
                } else if let rd = hbReadDetail {
                    detail += "心跳文件在，但读取失败：\(rd)"
                } else {
                    detail += "心跳文件在且可读，但 _loaded/_time 判定为过期"
                }
                if let wt = writeTest, !wt.isEmpty {
                    detail += "；写目录测试：\(wt)"
                }
                return detail + "。请确认 FloatingTap.deb 已安装并 sbreload。"
            }
            if let err = dumpError, !err.isEmpty {
                return "tweak 已加载，但枚举失败：\(err)"
            }
            if dumpCount == 0 {
                return "tweak 已加载，但导出 0 个 App（枚举返回空）。"
            }
            return "tweak 已加载，已导出 \(dumpCount) 个 App。"
        }
    }

    static func tweakDiagnostic() -> TweakDiagnostic {
        let now = Date().timeIntervalSince1970
        // 心跳：文件存在性 + 读取详情（区分「App 看不到文件」和「文件在但解析失败」）
        let hbExists = FileManager.default.fileExists(atPath: tweakStatusPath)
        var tweakLoaded = false
        var tweakTime: TimeInterval = 0
        var hbReadDetail: String?
        if hbExists {
            if let hb = NSDictionary(contentsOfFile: tweakStatusPath) {
                if (hb["_loaded"] as? NSNumber)?.boolValue == true,
                   let t = (hb["_time"] as? NSNumber)?.doubleValue {
                    // 超过 120s 视为过期（tweak 可能在 Safe Mode 下未加载）
                    tweakLoaded = (now - t/1000) < 120
                    tweakTime = t
                }
            } else {
                hbReadDetail = "NSDictionary 解析返回 nil（权限或格式问题）"
            }
        }
        // 写测试：App 能否写入同一目录（判断 App 对该路径的访问能力）
        var writeTest: String?
        let testPath = tweakStatusPath + ".apptest"
        do {
            try "ok".write(toFile: testPath, atomically: true, encoding: .utf8)
            writeTest = "可写"
            try? FileManager.default.removeItem(atPath: testPath)
        } catch {
            writeTest = "不可写（\(error.localizedDescription)）"
        }
        // 枚举状态
        let dumpExists = FileManager.default.fileExists(atPath: appsDumpPath)
        var dumpCount = 0
        var dumpError: String?
        var dumpTime: TimeInterval = 0
        if let st = NSDictionary(contentsOfFile: appsStatusPath) {
            dumpCount = (st["_count"] as? NSNumber)?.intValue ?? 0
            dumpError = st["_error"] as? String
            dumpTime = (st["_time"] as? NSNumber)?.doubleValue ?? 0
        }
        return TweakDiagnostic(tweakLoaded: tweakLoaded, tweakTime: tweakTime,
                               hbExists: hbExists, hbReadDetail: hbReadDetail,
                               writeTest: writeTest,
                               dumpExists: dumpExists, dumpCount: dumpCount,
                               dumpError: dumpError, dumpTime: dumpTime)
    }

    // MARK: - 打开目标 App

    /// 通过 LSApplicationWorkspace 打开目标 App
    @discardableResult
    static func openApp(bundleID: String) -> Bool {
        return LSApplicationWorkspace.default()?.openApplication(withBundleID: bundleID) ?? false
    }
}
