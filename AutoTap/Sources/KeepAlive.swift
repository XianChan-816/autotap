//
//  KeepAlive.swift
//  AutoTap
//
//  后台保活 + 音量键急停：
//  - 播放内存生成的 3 秒静音 PCM 循环，将 App 转为"后台音频"状态，
//    避免切到游戏后点击线程被挂起（iOS 对无理由后台会冻结应用）。
//  - 监听系统音量（KVO），连续模式下在后台用音量键快速停止。
//

import Foundation
import AVFoundation

final class KeepAlive: NSObject {

    static let shared = KeepAlive()

    private var player: AVAudioPlayer?
    private var volumeObservation: NSKeyValueObservation?
    private var lastVolume: Float = 0
    private var monitoringVolume = false
    private var onVolumeTrigger: (() -> Void)?

    private override init() {
        super.init()
    }

    // MARK: - 静音音频保活

    /// 生成 3 秒静音 PCM 数据（16kHz 16bit 单声道）
    private func makeSilenceData() -> Data? {
        let rate = 16000
        let seconds = 3
        let dataSize = rate * seconds * 2
        var data = Data(count: dataSize)
        data.resetBytes(in: 0..<data.count)

        var header = Data()
        func str(_ s: String) { header.append(s.data(using: .ascii)!) }
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { header.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { header.append(contentsOf: $0) } }

        str("RIFF")
        u32(UInt32(36 + dataSize))
        str("WAVE")
        str("fmt ")
        u32(16)
        u16(1)             // PCM
        u16(1)             // mono
        u32(UInt32(rate))
        u32(UInt32(rate * 2))
        u16(2)             // block align
        u16(16)            // bits
        str("data")
        u32(UInt32(dataSize))

        return header + data
    }

    /// 开始静音保活（可重复调用）
    func startSilentLoop() {
        guard player == nil else { return }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)

            guard let data = makeSilenceData() else { return }
            let p = try AVAudioPlayer(data: data)
            p.volume = 0.001
            p.numberOfLoops = -1
            p.prepareToPlay()
            p.play()
            player = p
            NSLog("[KeepAlive] 静音保活已启动")
        } catch {
            NSLog("[KeepAlive] 启动失败: \(error)")
        }
    }

    /// 停止保活（回到前台时可调用，也可不调用：混音模式不影响他人）
    func stopSilentLoop() {
        player?.stop()
        player = nil
    }

    // MARK: - 音量键急停（后台）

    /// 开启音量键监听：首次开始时会记录当前音量，之后音量变化即触发 onTrigger
    func startVolumeMonitor(_ onTrigger: @escaping () -> Void) {
        guard !monitoringVolume else { return }
        monitoringVolume = true
        onVolumeTrigger = onTrigger
        lastVolume = AVAudioSession.sharedInstance().outputVolume
        volumeObservation = AVAudioSession.sharedInstance().observe(\.outputVolume, options: [.new]) { [weak self] _, change in
            guard let self, self.monitoringVolume else { return }
            let new = change.newValue ?? self.lastVolume
            // 音量按键每次按压会产生 +0.0625 或 -0.0625 的变化
            if abs(new - self.lastVolume) > 0.0001 {
                self.lastVolume = new
                DispatchQueue.main.async {
                    self.onVolumeTrigger?()
                }
            }
        }
    }

    func stopVolumeMonitor() {
        monitoringVolume = false
        volumeObservation?.invalidate()
        volumeObservation = nil
        onVolumeTrigger = nil
    }
}
