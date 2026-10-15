//
//  BackgroundKeeper.swift
//  保持主 App 存活 —— 这是 socket 方案成败的关键
//
//  ## 问题
//
//  用户切到王者荣耀后，主 App 进后台。iOS 会在约 30 秒内挂起它。
//  挂起意味着：
//    - socket 监听线程冻结 → 扩展连不上
//    - PiP 渲染循环停止 → 提示不再更新
//  结果：切进游戏后提示就死了，整个方案失效。
//
//  ## 解法
//
//  声明 UIBackgroundModes = audio，并持续播放**静音音频**。
//  iOS 会认为这个 App 正在播放音频，从而**不挂起它**。
//
//  ## 为什么这是"正当"的
//
//  这不是钻空子 —— PiP 本身就要求活跃音频会话
//  （AVPictureInPictureController 在无音频会话时不会启动）。
//  所以音频会话是 PiP 的**必要前提**，保持存活是它的自然副产品。
//
//  ## 代价
//
//  - 状态栏会显示"正在播放"（或音频图标）
//  - 有一定耗电（静音音频解码开销很小）
//

import AVFoundation
import UIKit

public final class BackgroundKeeper {

    public static let shared = BackgroundKeeper()

    private var player: AVAudioPlayer?
    private var silentURL: URL?
    private var observer: NSObjectProtocol?

    /// 当前是否处于"保活"状态
    public private(set) var active = false

    /// 后台任务标识（额外兜底）
    private var bgTask: UIBackgroundTaskIdentifier = .invalid

    private init() {}

    // MARK: - 启动保活

    /// 在主 App 启动时调用。
    /// - Returns: 是否成功启动保活
    @discardableResult
    public func start() -> Bool {
        guard !active else { return true }

        // 1. 配置音频会话
        let session = AVAudioSession.sharedInstance()
        do {
            // .playback 允许后台播放；.mixWithOthers 不打断游戏音效
            try session.setCategory(.playback, mode: .default,
                                    options: [.mixWithOthers])
            try session.setActive(true)
        } catch {
            SharedStore.log("音频会话配置失败: \(error.localizedDescription)")
            return false
        }

        // 2. 准备静音音频
        guard let url = silentAudioURL() else {
            SharedStore.log("静音音频生成失败")
            return false
        }
        silentURL = url

        do {
            let p = try AVAudioPlayer(contentsOf: url)
            p.numberOfLoops = -1          // 无限循环
            p.volume = 0.0                // 完全静音
            p.prepareToPlay()
            guard p.play() else {
                SharedStore.log("静音音频播放失败")
                return false
            }
            player = p
        } catch {
            SharedStore.log("AVAudioPlayer 创建失败: \(error.localizedDescription)")
            return false
        }

        // 3. 监听中断（来电等），中断结束后恢复播放
        observer = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: session, queue: .main) { [weak self] note in
                self?.handleInterruption(note)
            }

        // 4. 额外兜底：申请后台任务时间，给 socket 一点缓冲
        renewBackgroundTask()

        active = true
        SharedStore.log("保活已启动（静音音频循环）")
        return true
    }

    public func stop() {
        player?.stop(); player = nil
        if let o = observer { NotificationCenter.default.removeObserver(o); observer = nil }
        try? AVAudioSession.sharedInstance().setActive(false,
            options: .notifyOthersOnDeactivation)
        if bgTask != .invalid {
            UIApplication.shared.endBackgroundTask(bgTask)
            bgTask = .invalid
        }
        active = false
        SharedStore.log("保活已停止")
    }

    // MARK: - 中断处理

    private func handleInterruption(_ note: Notification) {
        guard let info = note.userInfo,
              let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }

        switch type {
        case .began:
            SharedStore.log("音频被中断（来电？）")
        case .ended:
            // 中断结束，恢复播放，否则保活会断
            do {
                try AVAudioSession.sharedInstance().setActive(true)
                player?.play()
                SharedStore.log("中断结束，已恢复保活")
            } catch {
                SharedStore.log("恢复保活失败: \(error.localizedDescription)")
            }
        @unknown default:
            break
        }
    }

    // MARK: - 后台任务兜底

    /// 申请一个后台任务，让 App 在被挂起前多撑一会儿。
    /// 到期会自动续期 —— 这是保活的第二道防线。
    private func renewBackgroundTask() {
        if bgTask != .invalid {
            UIApplication.shared.endBackgroundTask(bgTask)
        }
        bgTask = UIApplication.shared.beginBackgroundTask(withName: "socket-keepalive") {
            // 到期回调：立刻续期
            self.bgTask = .invalid
            self.renewBackgroundTask()
        }
    }

    // MARK: - 静音音频生成

    /// 生成 1 秒静音 WAV。
    /// 用 8kHz 单声道 16bit —— 数据量最小，解码开销可忽略。
    private func silentAudioURL() -> URL? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("silent_loop.wav")
        if FileManager.default.fileExists(atPath: url.path) { return url }

        let sampleRate: UInt32 = 8000
        let duration: Double = 1.0
        let frames = Int(Double(sampleRate) * duration)
        let dataSize = UInt32(frames * 2)

        var d = Data()
        func append(_ s: String) { d.append(s.data(using: .ascii)!) }
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }

        append("RIFF"); u32(36 + dataSize)
        append("WAVE")
        append("fmt "); u32(16); u16(1); u16(1)
        u32(sampleRate); u32(sampleRate * 2); u16(2); u16(16)
        append("data"); u32(dataSize)
        d.append(Data(count: frames * 2))    // 全零 = 静音

        do { try d.write(to: url); return url }
        catch {
            SharedStore.log("静音 WAV 写入失败: \(error.localizedDescription)")
            return nil
        }
    }
}
