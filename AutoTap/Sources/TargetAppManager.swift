//
//  TargetAppManager.swift
//  AutoTap
//
//  v1.0.52：与 FloatingTap tweak 通过 CFMessagePort（CoreFoundation C API）通信，
//  RocketBootstrap 打通 iOS 沙盒 bootstrap namespace 隔离。
//  文件系统跨进程在 iOS 15.5 + Dopamine rootless 下彻底不通（App 被 sandbox 重定向，
//  /var/mobile/ 等系统路径 App 全部 stat 不到——v1.0.50-fix3 多路径探针实测 ✗stat），
//  故弃用文件方案，全部数据走 mach port。
//
//  协议（与 FloatingTap/Tweak.xm 一字不差）：
//    - App 端 server：com.floatingtap.autotap
//        msgid 1 = tweak→App 心跳 plist（_loaded/_time，_time 为毫秒）
//        msgid 3 = tweak→App 已装 App 列表 plist（dict: bundleID -> displayName）
//    - tweak 端 server：com.floatingtap.tweak
//        msgid 0 = App→tweak 配置 plist（Targets/IntervalMs/ClickX/ClickY）
//        msgid 2 = App→tweak 请求重新推送 App 列表
//    - Darwin 通知（appStarted / configUpdated）仅作唤醒信号，不承载数据
//
//  依赖：设备需装有 librocketbootstrap.dylib（Sileo 搜 com.rpetrich.rocketbootstrap）。
//

import UIKit
import CoreFoundation
import Darwin

// CFMessagePort 回调：@convention(c) 函数指针要求闭包**零捕获**，必须放文件顶层；
// 内部引用类型成员一律用全限定名 TargetAppManager.xxx（静态访问不算捕获）。
private let kAutoTapMsgPortCallback: CFMessagePortCallBack = { _, msgid, data, _ in
    guard let d = data else { return nil }
    TargetAppManager.handleMessage(msgid: msgid, data: d)
    return nil
}

enum TargetAppManager {

    // MARK: - IPC 基础设施（v1.0.52）

    private static var rbHandle: UnsafeMutableRawPointer?
    private static var rbExposeSym: UnsafeMutableRawPointer?
    private static var serverPort: CFMessagePort?
    private static var ipcReady = false            // RocketBootstrap 加载 + server 创建成功

    /// 心跳 / App 列表到达时的 UI 刷新回调
    private static var onTweakData: (() -> Void)?

    /// 最后一次收到 tweak 心跳的 epoch 秒
    static private(set) var lastHeartbeatTime: TimeInterval = 0

    /// tweak 是否已加载（心跳新鲜度 < 120s）
    static var tweakLoaded: Bool {
        return lastHeartbeatTime > 0 && (Date().timeIntervalSince1970 - lastHeartbeatTime) < 120
    }

    /// 最近一次从 tweak 收到的 App 列表（bundleID -> displayName）
    private static var ipcApps: [String: String] = [:]

    /// dlopen librocketbootstrap（多路径，Dopamine rootless 下可能在不同位置）
    private static func loadRocketBootstrap() {
        if rbHandle != nil { return }
        let paths = [
            "/usr/lib/librocketbootstrap.dylib",
            "/var/jb/usr/lib/librocketbootstrap.dylib",
            "/Library/MobileSubstrate/DynamicLibraries/librocketbootstrap.dylib",
        ]
        for p in paths {
            if let h = dlopen(p, RTLD_LAZY) { rbHandle = h; break }
        }
        if let h = rbHandle {
            rbExposeSym = dlsym(h, "rocketbootstrap_cfmessageportexposelocal")
        }
    }

    /// 把 local port 暴露到全局 bootstrap（否则跨进程查不到）
    private static func exposeToGlobalBootstrap(_ port: CFMessagePort?) {
        guard let sym = rbExposeSym, let port else { return }
        typealias ExposeFn = @convention(c) (CFMessagePort?) -> Void
        let fn = unsafeBitCast(sym, to: ExposeFn.self)
        fn(port)
    }

    /// 创建 App 端 IPC server（com.floatingtap.autotap），tweak 通过它推心跳 / App 列表
    static func setupIPCServer() {
        if serverPort != nil { return }
        loadRocketBootstrap()
        let name = "com.floatingtap.autotap" as CFString
        var ctx = CFMessagePortContext(version: 0, info: nil, retain: nil, release: nil, copyDescription: nil)
        guard let port = CFMessagePortCreateLocal(nil, name, kAutoTapMsgPortCallback, &ctx, nil) else {
            ipcReady = false
            return
        }
        serverPort = port
        exposeToGlobalBootstrap(port)
        if let src = CFMessagePortCreateRunLoopSource(nil, port, 0) {
            CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        }
        ipcReady = true
    }

    /// 解析 tweak 推来的消息（fileprivate：供文件顶层 kAutoTapMsgPortCallback 调用）
    fileprivate static func handleMessage(msgid: Int32, data: CFData) {
        guard let plist = CFPropertyListCreateWithData(nil, data, 0, nil, nil),
              let dict = plist.takeRetainedValue() as? [String: Any] else { return }
        if msgid == 1 {   // heartbeat
            if let t = dict["_time"] as? NSNumber {
                lastHeartbeatTime = t.doubleValue / 1000.0   // tweak 存毫秒
                DispatchQueue.main.async { onTweakData?() }
            }
        } else if msgid == 3 {   // apps list
            var apps: [String: String] = [:]
            for (k, v) in dict { apps[k] = "\(v)" }
            ipcApps = apps
            invalidateCache()
            DispatchQueue.main.async { onTweakData?() }
        }
    }

    /// 把配置推给 tweak（msgid=0，plist payload）
    private static func sendConfig(_ dict: [String: Any]) {
        guard let data = try? PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0) else { return }
        guard let remote = CFMessagePortCreateRemote(nil, "com.floatingtap.tweak" as CFString) else { return }
        _ = CFMessagePortSendRequest(remote, 0, data as CFData, 5.0, 0.0, nil, nil)
    }

    /// 请求 tweak 重新推送 App 列表（msgid=2）
    static func requestAppsList() {
        guard let remote = CFMessagePortCreateRemote(nil, "com.floatingtap.tweak" as CFString) else { return }
        _ = CFMessagePortSendRequest(remote, 2, nil, 5.0, 0.0, nil, nil)
    }

    // MARK: - Darwin 通知名（跨进程 ABI，与 tweak 一字不差）

    static let notifyAppStartedName = "com.floatingtap.autotap.appStarted"
    static let notifyConfigUpdatedName = "com.floatingtap.autotap.configUpdated"

    // MARK: - 启动与监听

    /// App 启动：注册 IPC server + 发 Darwin 唤醒（tweak 收到后推心跳 + App 列表）
    static func notifyAppStarted() {
        setupIPCServer()
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterPostNotification(center,
            CFNotificationName(rawValue: notifyAppStartedName as CFString), nil, nil, true)
        // 立即主动请求一次（tweak 在跑的话会回推心跳 + 列表）
        requestAppsList()
    }

    /// 监听 tweak 数据更新（心跳 / App 列表到达时回调）
    static func startListeningForTweakUpdates(handler: @escaping () -> Void) {
        onTweakData = handler
    }

    // MARK: - 配置（内存缓存 + IPC 推送）

    private static var configCache: [String: Any] = [:]

    private static func pushConfig() {
        sendConfig(configCache)
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
    /// 主方案：tweak（SB 特权进程）通过 IPC 枚举回传的清单。
    /// 兜底：文件系统扫描安装目录（越狱环境可读）。
    static func installedApps(includeSystem: Bool = false) -> [AppInfo] {
        if let cached = cachedApps { return cached }
        var found: [String: AppInfo] = [:]

        // 方式 1（主）：IPC 收到的 tweak 枚举清单
        if !ipcApps.isEmpty {
            for (bid, name) in ipcApps {
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

    // MARK: - tweak 诊断（v1.0.52：IPC 连通性）

    struct TweakDiagnostic {
        let ipcReady: Bool          // RocketBootstrap 加载 + App server 创建成功
        let rbLoaded: Bool          // dlopen librocketbootstrap 成功
        let tweakLoaded: Bool       // 心跳新鲜（<120s）
        let hbAge: TimeInterval     // 心跳年龄（秒；-1 = 从未收到）
        let appsCount: Int          // IPC 收到 App 数
        let serverName: String

        /// 诊断详情（替代旧版路径探针矩阵；现为 IPC 状态）
        var pathSummary: String {
            var s = "IPC 诊断："
            s += "\n  RocketBootstrap: \(rbLoaded ? "已加载 ✓" : "未加载 ✗")"
            s += "\n  App server \(serverName): \(ipcReady ? "已创建 ✓" : "失败 ✗")"
            if hbAge < 0 {
                s += "\n  心跳: 从未收到 ✗"
            } else {
                s += String(format: "\n  心跳: %.0fs 前 ✓", hbAge)
            }
            s += "\n  App 列表: \(appsCount) 个"
            if !rbLoaded {
                s += "\n  → Sileo 安装 com.rpetrich.rocketbootstrap 后重启"
            }
            return s
        }

        /// 供 UI 展示的一行状态描述
        var message: String {
            if !rbLoaded {
                return "IPC 未就绪：设备缺 librocketbootstrap.dylib（Sileo 装 com.rpetrich.rocketbootstrap）。"
            }
            if !ipcReady {
                return "IPC server 创建失败（CFMessagePortCreateLocal 返回 nil）。"
            }
            if !tweakLoaded {
                if hbAge < 0 {
                    return "tweak 未加载：尚未收到心跳（server \(serverName) 已就绪，请确认 FloatingTap.deb 已装并完整重启）。"
                }
                return "tweak 心跳过期：\(Int(hbAge))s 前最后一次，请确认 tweak 在运行。"
            }
            if appsCount == 0 {
                return "tweak 已加载（心跳正常），但 App 列表为空，请求中…"
            }
            return "tweak 已加载 ✓ 心跳正常，已收到 \(appsCount) 个 App。"
        }
    }

    static func tweakDiagnostic() -> TweakDiagnostic {
        let age = lastHeartbeatTime > 0 ? Date().timeIntervalSince1970 - lastHeartbeatTime : -1
        return TweakDiagnostic(ipcReady: ipcReady && serverPort != nil,
                               rbLoaded: rbHandle != nil,
                               tweakLoaded: tweakLoaded,
                               hbAge: age,
                               appsCount: ipcApps.count,
                               serverName: "com.floatingtap.autotap")
    }

    // MARK: - 打开目标 App

    @discardableResult
    static func openApp(bundleID: String) -> Bool {
        return LSApplicationWorkspace.default()?.openApplication(withBundleID: bundleID) ?? false
    }
}
