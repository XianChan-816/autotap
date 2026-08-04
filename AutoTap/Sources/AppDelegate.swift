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
        // tweak 收到后用 proc_listpids + sandbox_get_container_for_pid 找到 App 沙盒 Caches 路径，
        // 之后心跳/枚举状态都直接写到 App 沙盒，App 100% 可读
        TargetAppManager.notifyAppStarted()

        // 监听 tweak 写完数据后的通知（Darwin notification）
        TargetAppManager.startListeningForTweakUpdates {
            // tweak 写完心跳/枚举,UI 收到通知需要 reload 状态与 App 列表
            NotificationCenter.default.post(name: .floatingTapTweakDataUpdated, object: nil)
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
        // 重新通知 tweak，前台时 App 沙盒路径重新被发现（如果 tweak 之前没找到）
        TargetAppManager.notifyAppStarted()
    }
}

extension Notification.Name {
    /// FloatingTap tweak 写完心跳/枚举后发出；UI 收到后 reload 状态/列表
    static let floatingTapTweakDataUpdated = Notification.Name("floatingTapTweakDataUpdated")
}
