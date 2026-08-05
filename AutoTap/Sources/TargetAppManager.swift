//
//  TargetAppManager.swift
//  AutoTap
//
//  目标 App 管理：与 FloatingTap tweak 通过「Darwin notification + 文件」通信。
//  v1.0.50-fix3 多路径探针：tweak 和 App 都按顺序试 4 个候选路径，确保至少一个两端
//  都能读能写。诊断 UI 把哪些路径 App 能 stat、哪些能读、哪些能写全部展现出来。
//
//  候选路径（按"两边都能访问"概率排序）：
//    [0] /var/mobile/Library/Logs/CrashReporter/      （Logs 一定可写，绕过 TCC）
//    [1] /var/mobile/                                  （直挂 /var/mobile，跳过 Library 保护）
//    [2] /var/mobile/Library/Preferences/              （fix2 默认；实测 App 看不到）
//    [3] /tmp/                                         （兜底）
//
//  失败史：
//  - v1.0.50 试图用 sandbox_container_path_for_pid 反查沙盒 → arm64e 下 dlsym 私有函数崩
//  - v1.0.50-fix2 改固定 /var/mobile/Library/Preferences/ → tweak 写成功但 App hbExists=false
//  - v1.0.50-fix3 上多路径探针 + 把每个候选的 stat/read/write 测试结果都打到诊断屏
//
//  App 需在 TrollStore/越狱环境运行（platform-application + no-sandbox entitlement）。
//

import UIKit

// MARK: - tweak handler 包装（保留以备后用，当前用 polling 替代）

final class TweakUpdateBox: NSObject {
    let handler: () -> Void
    init(_ h: @escaping () -> Void) { self.handler = h }
    @objc func invoke() { handler() }
}

enum TargetAppManager {

    // MARK: - 路径（v1.0.50-fix3：多路径探针——先按顺序列出候选，实际读写时尝试到找到能用的）
    //
    // 候选规则：
    //   - 避开 TCC 可能拒的 /var/mobile/Library/Preferences / Documents（App 注释里早就标记过拒）
    //   - Logs/CrashReporter 一直是 iOS 公认的崩溃日志共享目录（mobile 写入，SB 也能写入）
    //   - /var/mobile 直挂不绕任何 Library 防护
    //   - /tmp 兜底（iOS 沙盒下 App 的 /tmp 实际是容器内，但 no-sandbox 应该是真 /tmp）
    //
    // 真实读写 API 会遍历这些候选直到 NSDictionary(contentsOfFile:) / write(toFile:atomically:)
    // 任一返回非空（heartbeat 也类似），并记忆第一个能写的。
    //
    // 重要：v1.0.50-fix2 实测 fix2 候选 [2] 写入成功的路径 App 看不到 → 必须探针多元化。

    /// App 自己的 Caches 目录（保留给写测试用，沙盒内一定可写）
    static let appCachesDir: String = {
        return NSSearchPathForDirectoriesInDomains(.cachesDirectory, .userDomainMask, true).first!
    }()

    /// 心跳候选路径（顺序）
    static let heartbeatCandidates: [String] = [
        "/var/mobile/Library/Logs/CrashReporter/com.floatingtap.tweak.plist",
        "/var/mobile/com.floatingtap.tweak.plist",
        "/var/mobile/Library/Preferences/com.floatingtap.tweak.plist",
        "/tmp/com.floatingtap.tweak.plist",
    ]

    /// 配置候选路径（顺序）
    static let configCandidates: [String] = [
        "/var/mobile/Library/Logs/CrashReporter/com.floatingtap.config.plist",
        "/var/mobile/com.floatingtap.config.plist",
        "/var/mobile/Library/Preferences/com.floatingtap.config.plist",
        "/tmp/com.floatingtap.config.plist",
    ]

    /// 兼容旧 API 的「首选路径」（fix2 默认，本质上是 [2]）；实际读写用上面的 candidates
    static let configPath = configCandidates[0]
    static let appsDumpPath = "/var/mobile/Library/Logs/CrashReporter/com.floatingtap.apps.plist"
    static let appsStatusPath = "/var/mobile/Library/Logs/CrashReporter/com.floatingtap.apps.status.plist"
    static let tweakStatusPath = heartbeatCandidates[0]

    /// 取第一个能 stat 的心跳路径（nil = 全部不存在/不可 stat）
    static func firstExistingHeartbeatPath() -> String? {
        let fm = FileManager.default
        return heartbeatCandidates.first { fm.fileExists(atPath: $0) }
    }

    /// 第一个可读出 plist 的心跳路径（nil = 全部不存在或解析失败）
    static func firstReadableHeartbeatPath() -> String? {
        return heartbeatCandidates.first { path in
            guard FileManager.default.fileExists(atPath: path) else { return false }
            return NSDictionary(contentsOfFile: path) != nil
        }
    }

    /// 第一个能存活的 NSDictionary 读出 config 的路径
    static func loadConfig(from path: String) -> NSDictionary? {
        return NSDictionary(contentsOfFile: path)
    }

    /// 把 dict 写到第一个能写入成功的候选路径；返回成功路径或 nil
    @discardableResult
    static func writeConfigDict(_ dict: NSDictionary, candidates: [String]) -> String? {
        for p in candidates {
            do {
                try dict.write(toFile: p, atomically: false)
                return p
            } catch {
                continue
            }
        }
        return nil
    }

    // MARK: - Darwin notification 名（跨进程 ABI，tweak 端必须一字不差）

    /// App 启动后发送，tweak 收到后用 proc 找到 App 反查沙盒路径
    static let notifyAppStartedName = "com.floatingtap.autotap.appStarted"

    /// App 写完 config 后发送，tweak 收到后重新读取目标 App / 间隔 / 点击位置
    static let notifyConfigUpdatedName = "com.floatingtap.autotap.configUpdated"

    /// tweak 写完心跳/枚举后发送，App 收到后重新读取 tweak status / apps
    static let notifyTweakDataUpdatedName = "com.floatingtap.autotap.tweakDataUpdated"

    // MARK: - 启动与监听

    /// App 启动时调用：通知 tweak 通过 sysctl 找 App PID 后开始写数据
    /// 用 CFNotificationCenter 发送 Darwin notification（tweak 端 notify_register_dispatch 接收，
    /// 两者底层都是 Darwin notification，互通）
    static func notifyAppStarted() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let name = CFNotificationName(rawValue: notifyAppStartedName as CFString)
        CFNotificationCenterPostNotification(center, name, nil, nil, true)
    }

    /// App 端轮询心跳文件变化（每 2s 检查心跳的 _time 字段，变化就 reload）
    /// v1.0.50-fix3：多路径探针——找任一候选路径能 stat 且能解析出 plist 的视为心跳
    private static var lastSeenTweakTime: TimeInterval = 0
    private static var pollingTimer: Timer?
    private static var lastSeenPath: String?  // 命中探测到的路径，诊断屏展示

    static func startListeningForTweakUpdates(handler: @escaping () -> Void) {
        // 立即读取一次基线（用探针找能读的路径）
        for p in heartbeatCandidates {
            if let hb = NSDictionary(contentsOfFile: p),
               let t = (hb["_time"] as? NSNumber)?.doubleValue {
                lastSeenTweakTime = t
                lastSeenPath = p
                break
            }
        }
        // 已在轮询则不重复
        if pollingTimer != nil { return }
        pollingTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
            var localMaxTime = lastSeenTweakTime
            for p in heartbeatCandidates {
                guard let hb = NSDictionary(contentsOfFile: p),
                      let t = (hb["_time"] as? NSNumber)?.doubleValue else { continue }
                if t > localMaxTime {
                    localMaxTime = t
                    lastSeenPath = p
                }
            }
            if localMaxTime > lastSeenTweakTime {
                lastSeenTweakTime = localMaxTime
                DispatchQueue.main.async { handler() }
            }
        }
    }

    // MARK: - 共享配置（v1.0.50-fix3：多路径探针版 — 读写都遍历 candidate 直到命中）

    /// 读第一个能成功解析的候选路径（nil = 全部不存在或解析失败）
    private static func readConfigDict() -> NSDictionary? {
        for p in configCandidates {
            if let d = NSDictionary(contentsOfFile: p) {
                return d
            }
        }
        return nil
    }

    /// 写到第一个写入成功的候选；返回成功路径（nil = 全部失败）
    private static func writeConfigDictAny(_ dict: NSDictionary) -> String? {
        for p in configCandidates {
            do {
                try dict.write(toFile: p, atomically: false)
                return p
            } catch {
                continue
            }
        }
        return nil
    }

    /// 读取当前目标 App bundleID 列表（任一候选路径解析成功即可）
    static func loadTargets() -> [String] {
        guard let dict = readConfigDict(),
              let targets = dict["Targets"] as? [String] else { return [] }
        return targets
    }

    /// 保存目标 App bundleID 列表（写第一个能写的候选 + 通知 tweak）
    static func saveTargets(_ ids: [String]) {
        let dict = NSMutableDictionary(contentsOfFile: configCandidates[0]) ??
                   NSMutableDictionary(contentsOfFile: configCandidates[1]) ??
                   NSMutableDictionary(contentsOfFile: configCandidates[2]) ??
                   NSMutableDictionary(contentsOfFile: configCandidates[3]) ??
                   NSMutableDictionary()
        dict["Targets"] = ids
        writeConfig(dict)
    }

    /// 读取连点间隔（毫秒），供 tweak 使用
    static func loadIntervalMs() -> Int {
        guard let dict = readConfigDict(),
              let v = dict["IntervalMs"] as? NSNumber else { return 200 }
        return max(1, min(v.intValue, 60_000))
    }

    /// 保存连点间隔（毫秒，写完会通知 tweak）
    static func saveIntervalMs(_ ms: Int) {
        let dict = NSMutableDictionary(contentsOfFile: configCandidates[0]) ??
                   NSMutableDictionary(contentsOfFile: configCandidates[1]) ??
                   NSMutableDictionary(contentsOfFile: configCandidates[2]) ??
                   NSMutableDictionary(contentsOfFile: configCandidates[3]) ??
                   NSMutableDictionary()
        dict["IntervalMs"] = max(1, min(ms, 60_000))
        writeConfig(dict)
    }

    /// 读取点击位置（归一化 0~1），供 tweak 悬浮球定位（球心=点击点）
    static func loadClick() -> (Double, Double)? {
        guard let dict = readConfigDict(),
              let x = dict["ClickX"] as? NSNumber,
              let y = dict["ClickY"] as? NSNumber else { return nil }
        return (x.doubleValue, y.doubleValue)
    }

    /// 保存点击位置（归一化 0~1），tweak 悬浮球读此定位
    static func saveClick(x: Double, y: Double) {
        let dict = NSMutableDictionary(contentsOfFile: configCandidates[0]) ??
                   NSMutableDictionary(contentsOfFile: configCandidates[1]) ??
                   NSMutableDictionary(contentsOfFile: configCandidates[2]) ??
                   NSMutableDictionary(contentsOfFile: configCandidates[3]) ??
                   NSMutableDictionary()
        dict["ClickX"] = min(1, max(0, x))
        dict["ClickY"] = min(1, max(0, y))
        writeConfig(dict)
    }

    /// 写配置 + 通知 tweak（写第一个能写的候选路径，tweak 用同样的多路径探针读）
    private static func writeConfig(_ dict: NSDictionary) {
        _ = writeConfigDictAny(dict)
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let name = CFNotificationName(rawValue: notifyConfigUpdatedName as CFString)
        CFNotificationCenterPostNotification(center, name, nil, nil, true)
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
    /// 主方案：读 FloatingTap tweak（SpringBoard 特权进程）写入的 appsDumpPath。
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

    // MARK: - tweak 诊断（v1.0.50-fix3：多路径探针）

    /// 单条路径的探测结果
    struct PathProbe {
        let path: String
        let canStat: Bool       // FileManager.fileExists 成功
        let canRead: Bool       // NSDictionary(contentsOfFile:) 返回非 nil
        let canWrite: Bool      // dict.write(toFile:) 写入成功
        let hbLoaded: Bool?     // 仅心跳路径有效：_loaded=true
        let hbTime: TimeInterval?
    }

    /// 探测单条路径的所有能力（stat / read / write / 解析）
    /// canWrite 测试用一个并排的 .probe 文件，避免覆盖真正的 tweak.plist
    static func probePath(_ path: String, isHeartbeat: Bool) -> PathProbe {
        let fm = FileManager.default
        let canStat = fm.fileExists(atPath: path)
        var canRead = false
        var canWrite = false
        var hbLoaded: Bool? = nil
        var hbTime: TimeInterval? = nil
        if canStat {
            if isHeartbeat {
                if let hb = NSDictionary(contentsOfFile: path) {
                    canRead = true
                    hbLoaded = (hb["_loaded"] as? NSNumber)?.boolValue
                    hbTime = (hb["_time"] as? NSNumber)?.doubleValue
                }
            } else {
                canRead = NSDictionary(contentsOfFile: path) != nil
            }
        }
        // 写测试：用路径旁加 .probe 后缀做独立测试，不覆盖原文件
        let probe = path + ".probe"
        do {
            let d = NSMutableDictionary()
            d["_probe_ts"] = NSNumber(value: Date().timeIntervalSince1970 * 1000.0)
            d["_probe_src"] = "autotap"
            try d.write(toFile: probe, atomically: false)
            canWrite = true
            try? fm.removeItem(atPath: probe)
        } catch {
            canWrite = false
            try? fm.removeItem(atPath: probe)
        }
        return PathProbe(path: path, canStat: canStat, canRead: canRead,
                         canWrite: canWrite, hbLoaded: hbLoaded, hbTime: hbTime)
    }

    /// 探测全部心跳候选路径
    static func probeAllHeartbeatPaths() -> [PathProbe] {
        return heartbeatCandidates.map { probePath($0, isHeartbeat: true) }
    }

    /// 探测全部配置候选路径
    static func probeAllConfigPaths() -> [PathProbe] {
        return configCandidates.map { probePath($0, isHeartbeat: false) }
    }

    /// 拿到第一个能 stat+read 心跳且 _loaded=true 且 _time 新鲜（<120s）的结果
    static func bestHeartbeatProbe() -> PathProbe? {
        let now = Date().timeIntervalSince1970
        for p in probeAllHeartbeatPaths() {
            if p.canStat && p.canRead && p.hbLoaded == true,
               let t = p.hbTime, (now - t/1000) < 120 {
                return p
            }
        }
        return nil
    }

    /// 读取 tweak 状态，用于排查「选择应用列表为空」问题。
    /// v1.0.50-fix3：多路径探针——把所有候选的 stat/read/write/hb 都拿出来给 UI 看，方便定位问题。
    /// - tweakLoaded：任一候选路径能 stat+read 且 _loaded=true 且 <120s
    /// - hbProbes：每个候选路径的探测详情
    /// - cfgProbes：每个 config 候选的探测详情
    /// - workingPath：选中的、能读写的心跳路径
    struct TweakDiagnostic {
        let tweakLoaded: Bool
        let tweakTime: TimeInterval
        let hbExists: Bool                       // 向后兼容：是否至少 1 候选可 stat
        let hbReadDetail: String?                // 向后兼容
        let writeTest: String?                   // 向后兼容
        let dumpExists: Bool
        let dumpCount: Int
        let dumpError: String?
        let dumpTime: TimeInterval
        let hbProbes: [PathProbe]                // fix3 新增
        let cfgProbes: [PathProbe]               // fix3 新增
        let workingPath: String?                 // fix3 新增：实际选中的心跳路径
        /// 探测结果的人类可读总结
        var pathSummary: String {
            func line(_ p: PathProbe) -> String {
                let stat = p.canStat ? "✓stat" : "✗stat"
                let read = p.canRead ? "✓read" : "✗read"
                let write = p.canWrite ? "✓write" : "✗write"
                let loaded: String
                if let v = p.hbLoaded { loaded = v ? " _loaded=Y" : " _loaded=N" } else { loaded = "" }
                return "  [\(stat)/\(read)/\(write)]\(loaded) \(p.path)"
            }
            var s = "心跳候选探测："
            for p in hbProbes { s += "\n" + line(p) }
            s += "\n配置候选探测："
            for p in cfgProbes { s += "\n" + line(p) }
            if let wp = workingPath {
                s += "\n选中：\(wp)"
            } else {
                s += "\n无可用路径（两端都没法读)"
            }
            return s
        }
        /// 供 UI 展示的一行状态描述
        var message: String {
            if !tweakLoaded {
                var detail = "tweak 未加载："
                if workingPath == nil {
                    detail += "App 端所有心跳候选路径都不能 stat/读，tweak 写不到 App 能看见的地方"
                } else {
                    detail += "心跳存在但 _loaded/_time 判定为过期（tweak 可能没在写，或 App 没在轮询）"
                }
                if let wp = workingPath { detail += "；当前心跳路径：\(wp)" }
                if let wt = writeTest, !wt.isEmpty {
                    detail += "；写测试：\(wt)"
                }
                return detail + "。" + pathSummary
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
        // 心跳候选：每条路径独立探针
        let hbProbes = probeAllHeartbeatPaths()
        // 配置候选：每条路径独立探针（写测试=实际写入候选路径的话会清掉之前的内容，仅做能力测试）
        let cfgProbes = probeAllConfigPaths()
        // 选 working path：第一个 stat+read 成功的心跳候选
        var workingPath: String?
        var tweakLoaded = false
        var tweakTime: TimeInterval = 0
        var hbReadDetail: String?
        for p in hbProbes {
            if p.canStat && p.canRead {
                workingPath = p.path
                if p.hbLoaded == true, let t = p.hbTime, (now - t/1000) < 120 {
                    tweakLoaded = true
                    tweakTime = t
                } else if p.canRead && p.hbLoaded == nil {
                    hbReadDetail = "读到了文件但解析不出 _loaded/_time"
                }
                break
            }
        }
        let hbExists = hbProbes.contains { $0.canStat }
        // 写测试保留向后兼容：测 App 自己沙盒 Caches
        var writeTest: String?
        let testPath = appCachesDir + "/tweak.plist.apptest"
        do {
            try "ok".write(toFile: testPath, atomically: true, encoding: .utf8)
            writeTest = "可写（App 沙盒 Caches 写入成功）"
            try? FileManager.default.removeItem(atPath: testPath)
        } catch {
            writeTest = "不可写：\(error.localizedDescription)"
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
                               dumpError: dumpError, dumpTime: dumpTime,
                               hbProbes: hbProbes, cfgProbes: cfgProbes,
                               workingPath: workingPath)
    }

    // MARK: - 打开目标 App

    /// 通过 LSApplicationWorkspace 打开目标 App
    @discardableResult
    static func openApp(bundleID: String) -> Bool {
        return LSApplicationWorkspace.default()?.openApplication(withBundleID: bundleID) ?? false
    }
}
