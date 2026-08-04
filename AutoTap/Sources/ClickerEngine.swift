//
//  ClickerEngine.swift
//  AutoTap
//
//  点击调度引擎：
//  - 专用线程 + mach_absolute_time 高精度计时（毫秒级间隔，抖动 < 1ms）
//  - 支持多个坐标点循环点击
//  - 线程安全启停，不阻塞主线程
//

import Foundation
import UIKit

/// 点击方向：屏幕方向（决定坐标如何换算到原生屏幕）
enum ScreenOrientation: Int, CaseIterable {
    case portrait = 0          // 竖屏（home 在下）
    case landscapeLeft = 1     // 横屏 home 在右
    case landscapeRight = 2    // 横屏 home 在左

    var title: String {
        switch self {
        case .portrait: return "竖屏"
        case .landscapeLeft: return "横屏(Home右)"
        case .landscapeRight: return "横屏(Home左)"
        }
    }
}

/// 一个点击点：以当前所选方向为基准的 0~1 归一化坐标
struct TapPoint {
    var x: CGFloat   // 0~1
    var y: CGFloat   // 0~1
}

/// 引擎状态
enum EngineState {
    case idle
    case running
}

/// 回调（主线程执行）
struct EngineCallbacks {
    var onStateChanged: (EngineState) -> Void = { _ in }
    var onTick: (Int) -> Void = { _ in }   // 每轮循环结束回调，参数为累计点击次数
}

final class ClickerEngine {

    static let shared = ClickerEngine()

    private var thread: Thread?
    private var stopFlag = false
    private var mutex = pthread_mutex_t()
    private let cond = NSCondition()

    private var points: [TapPoint] = []
    private var intervalMs: Int = 200

    // 实时状态
    private(set) var state: EngineState = .idle
    private(set) var tapCount: Int = 0
    private(set) var lastTapTime: TimeInterval = 0

    var callbacks = EngineCallbacks()

    /// 原生屏幕尺寸（竖屏基准）。旋转坐标系时用。
    private var nativeSize: CGSize {
        UIScreen.main.nativeBounds.size
    }

    init() {
        pthread_mutex_init(&mutex, nil)
    }

    deinit {
        stop()
        pthread_mutex_destroy(&mutex)
    }

    // MARK: - 控制

    func start(points: [TapPoint], intervalMs: Int) {
        pthread_mutex_lock(&mutex)
        defer { pthread_mutex_unlock(&mutex) }

        guard state == .idle, !points.isEmpty else { return }
        guard HIDBridge.shared.connect() else {
            NSLog("[Engine] HID 连接失败，无法启动")
            return
        }

        self.points = points
        self.intervalMs = max(1, intervalMs)
        self.tapCount = 0
        self.stopFlag = false
        state = .running

        thread = Thread { [weak self] in
            self?.runLoop()
        }
        thread?.name = "AutoTap.ClickThread"
        thread?.qualityOfService = .userInteractive
        thread?.start()

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.callbacks.onStateChanged(.running)
        }
    }

    func stop() {
        pthread_mutex_lock(&mutex)
        guard state == .running else {
            pthread_mutex_unlock(&mutex)
            return
        }
        stopFlag = true
        state = .idle
        pthread_mutex_unlock(&mutex)

        thread?.cancel()
        cond.signal()
        thread = nil

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.callbacks.onStateChanged(.idle)
        }
    }

    // MARK: - 工作线程

    private func runLoop() {
        let machNow = { () -> UInt64 in
            var tb = mach_timebase_info_data_t()
            if tb.denom == 0 { mach_timebase_info(&tb) }
            return mach_absolute_time() * UInt64(tb.numer) / UInt64(tb.denom)
        }

        // 预取 HIDTap 对象（避免循环内分配）
        let hidTaps = points.map { p -> HIDTap in
            let t = HIDTap()
            t.normalizedX = p.x
            t.normalizedY = p.y
            return t
        }

        let intervalNanos = UInt64(intervalMs) * 1_000_000

        while !stopFlag && !Thread.current.isCancelled {
            let roundStart = machNow()

            for tap in hidTaps {
                guard !stopFlag && !Thread.current.isCancelled else { break }
                HIDBridge.shared.tap(at: tap)

                pthread_mutex_lock(&mutex)
                tapCount += 1
                pthread_mutex_unlock(&mutex)
            }

            lastTapTime = Date.timeIntervalSinceReferenceDate

            // 高精度等待：忙等逼近目标时刻
            let elapsed = machNow() - roundStart
            var remain = intervalNanos
            if elapsed < remain { remain -= elapsed } else { remain = 0 }

            // 先让出 CPU，再在接近目标时忙等
            let sleepNanos = remain > 200_000 ? remain - 200_000 : 0
            if sleepNanos > 0 {
                var ts = timespec(tv_sec: Int(sleepNanos / 1_000_000_000),
                                  tv_nsec: Int(sleepNanos % 1_000_000_000))
                nanosleep(&ts, nil)
            }
            let target = machNow() + remain
            while machNow() < target && !stopFlag && !Thread.current.isCancelled {
                // busy wait（纳秒级精度）
            }

            let count = tapCount
            DispatchQueue.main.async { [weak self] in
                self?.callbacks.onTick(count)
            }
        }
    }

    // MARK: - 坐标换算

    /// 将"所选方向的屏幕可视坐标"换算为"原生竖屏归一化坐标"
    ///
    /// 可视坐标 (x, y)：x=0 左边 → 1 右边；y=0 上边 → 1 下边（按所选方向）。
    /// 原生坐标以竖屏 home 在下为基准，宽 W 高 H（W < H）。
    /// 旋转映射（与 iOS 旋转矩阵一致）：
    ///   竖屏:        native = (x, y)
    ///   横屏Home右:  native = (1 - y, x)
    ///   横屏Home左:  native = (y, 1 - x)
    static func nativeNormalized(x: CGFloat, y: CGFloat, orientation: ScreenOrientation) -> (nx: CGFloat, ny: CGFloat) {
        switch orientation {
        case .portrait:
            return (x, y)
        case .landscapeLeft:
            return (1 - y, x)
        case .landscapeRight:
            return (y, 1 - x)
        }
    }
}
