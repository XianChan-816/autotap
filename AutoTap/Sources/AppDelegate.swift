//
//  AppDelegate.swift
//  AutoTap
//

import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {

    var window: UIWindow?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {

        let window = UIWindow(frame: UIScreen.main.bounds)
        window.backgroundColor = .systemBackground
        window.rootViewController = ViewController()
        window.makeKeyAndVisible()
        self.window = window

        // 通知 FloatingTap tweak：App 已启动（Darwin notification）
        // tweak 在 SB 启动 8s 后才注册监听，故重复广播 30 次（每 1s），
        // 确保 tweak 无论何时注册都能收到 appStarted
        var broadcastCount = 0
        TargetAppManager.notifyAppStarted()
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { timer in
            broadcastCount += 1
            TargetAppManager.notifyAppStarted()
            if broadcastCount >= 30 { timer.invalidate() }
        }

        // 监听 tweak 写完数据后的通知（Darwin notification）
        TargetAppManager.startListeningForTweakUpdates {
            // tweak 写完心跳/枚举,UI 收到通知需要 reload 状态与 App 列表
            NotificationCenter.default.post(name: .floatingTapTweakDataUpdated, object: nil)
        }

        // v1.0.53：前台定时轮询共享偏好（CFPreferences），持续刷新心跳/App 列表状态
        Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { _ in
            TargetAppManager.pollTweakData()
        }

        return true
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        // 切后台时启动静音保活，保证点击线程不被挂起
        if ClickerEngine.shared.state == .running {
            KeepAlive.shared.startSilentLoop()
        }
    }

    func applicationWillEnterForeground(_ application: UIApplication) {
        KeepAlive.shared.stopSilentLoop()
        // 重新广播 appStarted，确保 tweak 拿到 App 沙盒路径
        TargetAppManager.notifyAppStarted()
    }
}

extension Notification.Name {
    /// FloatingTap tweak 写完心跳/枚举后发出；UI 收到后 reload 状态/列表
    static let floatingTapTweakDataUpdated = Notification.Name("floatingTapTweakDataUpdated")
}
