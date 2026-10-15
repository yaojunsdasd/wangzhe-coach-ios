//
//  PiPOverlay.swift
//  PiP 画中画悬浮提示 —— iOS 上唯一能覆盖游戏的合法途径
//
//  为什么用 PiP：
//    普通 App 不能覆盖其他 App（iOS 单前台模型），
//    但 PiP 是**系统级窗口**，浮在所有 App 之上，且内容可完全自定义。
//
//  实测注意点：
//    1. AVPictureInPictureController 需要**活跃音频会话**，否则不显示。
//       标准做法是播一段静音音频维持会话。
//    2. PiP 内容是 AVSampleBufferDisplayLayer 渲染的，需要自己画帧。
//

import AVKit
import AVFoundation
import UIKit
import CoreVideo

final class PiPOverlay: NSObject {

    private var pipController: AVPictureInPictureController?
    private let displayLayer = AVSampleBufferDisplayLayer()
    private var audioPlayer: AVAudioPlayer?
    private var renderTimer: Timer?

    /// 当前状态（来自扩展）
    private var latestThreat: Double = 0
    private var latestMarkers: String = ""
    private var latestTS: Double = 0

    private let canvasSize = CGSize(width: 320, height: 180)

    // MARK: - 启动

    func start(in view: UIView) {
        configureAudioSession()
        configureDisplayLayer(in: view)
        startPiP()
        startRenderLoop()
    }

    func stop() {
        renderTimer?.invalidate(); renderTimer = nil
        pipController?.stopPictureInPicture()
        audioPlayer?.stop()
        displayLayer.flushAndRemoveImage()
    }

    /// 配置音频会话 —— PiP 的前提条件。
    /// 用 .playback + 静音音频维持会话，否则 PiP 不会启动。
    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
            try session.setActive(true)
        } catch {
            NSLog("[PiP] audio session failed: \(error)")
        }
        // 生成一段静音音频循环播放
        if let url = makeSilentAudio(duration: 1.0) {
            audioPlayer = try? AVAudioPlayer(contentsOf: url)
            audioPlayer?.numberOfLoops = -1
            audioPlayer?.volume = 0.0
            audioPlayer?.play()
        }
    }

    private func makeSilentAudio(duration: Double) -> URL? {
        let sr: Double = 8000
        let frames = Int(sr * duration)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("silent.wav")
        var data = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        let dataSize = UInt32(frames * 2)
        data.append("RIFF".data(using: .ascii)!); u32(36 + dataSize)
        data.append("WAVE".data(using: .ascii)!)
        data.append("fmt ".data(using: .ascii)!); u32(16); u16(1); u16(1)
        u32(UInt32(sr)); u32(UInt32(sr) * 2); u16(2); u16(16)
        data.append("data".data(using: .ascii)!); u32(dataSize)
        data.append(Data(count: frames * 2))
        try? data.write(to: url)
        return url
    }

    private func configureDisplayLayer(in view: UIView) {
        displayLayer.frame = CGRect(origin: .zero, size: canvasSize)
        displayLayer.videoGravity = .resizeAspect
        view.layer.addSublayer(displayLayer)
    }

    private func startPiP() {
        guard AVPictureInPictureController.isPictureInPictureSupported() else {
            NSLog("[PiP] 设备不支持")
            return
        }
        let source = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: displayLayer,
            playbackDelegate: self)
        pipController = AVPictureInPictureController(contentSource: source)
        pipController?.delegate = self
        // 注意：canStartPictureInPictureAutomaticallyFromInline 是**只读**属性，
        // 赋值会编译失败。它只对 AVPlayerLayer 场景有效，且由系统根据
        // 内容类型自动决定。sampleBufferDisplayLayer 场景必须显式调用 start。
        pipController?.startPictureInPicture()
    }

    // MARK: - 渲染循环

    private func startRenderLoop() {
        renderTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.pullAndRender()
        }
    }

    private func pullAndRender() {
        if let s = SharedStore.readState() {
            latestTS = s.ts
            latestThreat = s.threat
            latestMarkers = s.markers
        }
        guard let buffer = renderFrame() else { return }
        // enqueue 前必须检查就绪状态，否则会丢帧并打印错误
        guard displayLayer.isReadyForMoreMediaData else { return }
        displayLayer.enqueue(buffer)
    }

    /// 把当前状态画成一帧。
    ///
    /// 设计原则：**不看文字，只看颜色**。
    /// 玩游戏时没空读字，但余光能看见整块变红。
    private func renderFrame() -> CMSampleBuffer? {
        let renderer = UIGraphicsImageRenderer(size: canvasSize)
        let image = renderer.image { ctx in
            let cg = ctx.cgContext
            let bg: UIColor
            let label: String
            if latestThreat >= 0.70 {
                bg = UIColor(red: 0.69, green: 0.0, blue: 0.13, alpha: 1)   // 紧急红
                label = "撤退"
            } else if latestThreat >= 0.45 {
                bg = UIColor(red: 0.76, green: 0.27, blue: 0.05, alpha: 1)  // 警告橙
                label = "注意"
            } else if latestThreat >= 0.25 {
                bg = UIColor(red: 0.72, green: 0.53, blue: 0.04, alpha: 1)  // 提示黄
                label = "留意"
            } else {
                bg = UIColor(red: 0.12, green: 0.44, blue: 0.23, alpha: 1)  // 安全绿
                label = "安全"
            }
            cg.setFillColor(bg.cgColor)
            cg.fill(CGRect(origin: .zero, size: canvasSize))

            // 威胁概率大字
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.monospacedDigitSystemFont(ofSize: 46, weight: .bold),
                .foregroundColor: UIColor.white,
            ]
            let pct = String(format: "%.0f%%", latestThreat * 100)
            let size = (pct as NSString).size(withAttributes: attrs)
            (pct as NSString).draw(at: CGPoint(x: 12, y: 10), withAttributes: attrs)

            // 动作词
            let attrs2: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 30, weight: .semibold),
                .foregroundColor: UIColor.white,
            ]
            (label as NSString).draw(at: CGPoint(x: canvasSize.width - 110, y: 20),
                                     withAttributes: attrs2)

            // 敌我标记（画成小地图示意）
            drawMarkers(cg)
        }
        return image.toSampleBuffer(size: canvasSize)
    }

    /// 画幽灵标记 —— SOLID 实心，GHOST 空心+不确定圈，HIDDEN 不画
    private func drawMarkers(_ cg: CGContext) {
        let box = CGRect(x: 8, y: 74, width: canvasSize.width - 16,
                         height: canvasSize.height - 82)
        cg.setFillColor(UIColor(white: 0.1, alpha: 0.55).cgColor)
        cg.fill(box)

        guard !latestMarkers.isEmpty else { return }
        for part in latestMarkers.split(separator: ";") {
            let f = part.split(separator: ",")
            guard f.count >= 4 else { continue }
            let tag = String(f[0])
            guard let x = Double(f[1]), let y = Double(f[2]),
                  let unc = Double(f[3]) else { continue }
            let px = box.minX + CGFloat(x) * box.width
            let py = box.minY + CGFloat(y) * box.height

            if tag == "S" {
                cg.setFillColor(UIColor(red: 1, green: 0.25, blue: 0.25, alpha: 1).cgColor)
                cg.fillEllipse(in: CGRect(x: px - 5, y: py - 5, width: 10, height: 10))
            } else {
                // GHOST：空心 + 不确定性圈
                cg.setStrokeColor(UIColor(red: 1, green: 0.78, blue: 0, alpha: 1).cgColor)
                cg.setLineWidth(2)
                let r = max(6, CGFloat(unc) * box.width)
                cg.strokeEllipse(in: CGRect(x: px - r, y: py - r, width: r * 2, height: r * 2))
                cg.strokeEllipse(in: CGRect(x: px - 4, y: py - 4, width: 8, height: 8))
            }
        }
    }
}

// MARK: - 代理

extension PiPOverlay: AVPictureInPictureControllerDelegate {
    func pictureInPictureControllerDidStartPictureInPicture(_ c: AVPictureInPictureController) {
        NSLog("[PiP] started")
    }
    func pictureInPictureController(_ c: AVPictureInPictureController,
                                   failedToStartPictureInPictureWithError error: Error) {
        NSLog("[PiP] failed: \(error)")
    }
}

extension PiPOverlay: AVPictureInPictureSampleBufferPlaybackDelegate {
    func pictureInPictureController(_ c: AVPictureInPictureController,
                                   setPlaying playing: Bool) {}
    func pictureInPictureControllerTimeRangeForPlayback(
        _ c: AVPictureInPictureController) -> CMTimeRange {
        // 无限时长：直播式内容
        CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
    }
    func pictureInPictureControllerIsPlaybackPaused(
        _ c: AVPictureInPictureController) -> Bool { false }
    func pictureInPictureController(_ c: AVPictureInPictureController,
                                   didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}
    func pictureInPictureController(_ c: AVPictureInPictureController,
                                   skipByInterval skipInterval: CMTime,
                                   completion completionHandler: @escaping () -> Void) {
        completionHandler()
    }
}

// MARK: - UIImage -> CMSampleBuffer

extension UIImage {
    /// 把 UIImage 转成 CMSampleBuffer 供 AVSampleBufferDisplayLayer 显示。
    ///
    /// **必须传 formatDescription**：CMSampleBufferCreateReadyWithImageBuffer
    /// 传 nil 会返回错误，画面不显示。这里从像素缓冲区的格式描述创建。
    func toSampleBuffer(size: CGSize) -> CMSampleBuffer? {
        guard let cg = self.cgImage else { return nil }

        var pixelBuffer: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, Int(size.width), Int(size.height),
            kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pixelBuffer)
        guard status == kCVReturnSuccess, let pb = pixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }

        guard let base = CVPixelBufferGetBaseAddress(pb),
              let ctx = CGContext(
                data: base,
                width: Int(size.width), height: Int(size.height),
                bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        ctx.draw(cg, in: CGRect(origin: .zero, size: size))

        // 从像素缓冲区取格式描述（关键：不能传 nil）
        guard let format = CVPixelBufferGetFormatDescription(pb) else { return nil }

        var sampleBuffer: CMSampleBuffer?
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 10),
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: .invalid)
        let err = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pb,
            formatDescription: format,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer)
        guard err == noErr else { return nil }
        return sampleBuffer
    }
}