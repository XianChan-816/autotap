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
    }
}
