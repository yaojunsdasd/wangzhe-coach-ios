//
//  PiPOverlay.swift
//  PiP 画中画悬浮提示
//
//  保守实现：只用 iOS 15 确定存在的 API，避免可选 API。
//  每次 API 误用都会导致编译失败，所以这里刻意选择最保守的路径。
//

import AVKit
import AVFoundation
import UIKit
import CoreVideo
import CoreMedia

final class PiPOverlay: NSObject {

    private var pipController: AVPictureInPictureController?
    private let displayLayer = AVSampleBufferDisplayLayer()
    private var audioPlayer: AVAudioPlayer?
    private var renderTimer: Timer?

    private var latestThreat: Double = 0
    private var latestMarkers: String = ""

    private let canvasSize = CGSize(width: 320, height: 180)

    // MARK: - 启动

    func start(in view: UIView) {
        configureAudioSession()
        configureDisplayLayer(in: view)
        startPiP()
        startRenderLoop()
    }

    func stop() {
        renderTimer?.invalidate()
        renderTimer = nil
        pipController?.stopPictureInPicture()
        audioPlayer?.stop()
    }

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .moviePlayback,
                                    options: [.mixWithOthers])
            try session.setActive(true)
        } catch {
            NSLog("[PiP] audio session error")
        }
        if let url = makeSilentAudio(duration: 1.0) {
            audioPlayer = try? AVAudioPlayer(contentsOf: url)
            audioPlayer?.numberOfLoops = -1
            audioPlayer?.volume = 0.0
            audioPlayer?.play()
        }
    }

    private func makeSilentAudio(duration: Double) -> URL? {
        let sr: UInt32 = 8000
        let frames = Int(Double(sr) * duration)
        let dataSize = UInt32(frames * 2)
        var d = Data()

        func put(_ s: String) { d.append(s.data(using: .ascii) ?? Data()) }
        func u32(_ v: UInt32) {
            d.append(UInt8(v & 0xFF))
            d.append(UInt8((v >> 8) & 0xFF))
            d.append(UInt8((v >> 16) & 0xFF))
            d.append(UInt8((v >> 24) & 0xFF))
        }
        func u16(_ v: UInt16) {
            d.append(UInt8(v & 0xFF))
            d.append(UInt8((v >> 8) & 0xFF))
        }

        put("RIFF"); u32(36 + dataSize)
        put("WAVE")
        put("fmt "); u32(16); u16(1); u16(1)
        u32(sr); u32(sr * 2); u16(2); u16(16)
        put("data"); u32(dataSize)
        d.append(Data(count: frames * 2))

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("silent_loop.wav")
        do { try d.write(to: url); return url } catch { return nil }
    }

    private func configureDisplayLayer(in view: UIView) {
        displayLayer.frame = CGRect(x: 0, y: 0,
                                    width: canvasSize.width,
                                    height: canvasSize.height)
        displayLayer.videoGravity = .resizeAspect
        view.layer.addSublayer(displayLayer)
    }

    private func startPiP() {
        if !AVPictureInPictureController.isPictureInPictureSupported() {
            NSLog("[PiP] not supported")
            return
        }
        let source = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: displayLayer,
            playbackDelegate: self)
        let c = AVPictureInPictureController(contentSource: source)
        c.delegate = self
        pipController = c
        c.startPictureInPicture()
    }

    private func startRenderLoop() {
        renderTimer = Timer.scheduledTimer(timeInterval: 0.1,
                                           target: self,
                                           selector: #selector(tick),
                                           userInfo: nil,
                                           repeats: true)
    }

    @objc private func tick() {
        if let s = SharedStore.readState() {
            latestThreat = s.threat
            latestMarkers = s.markers
        }
        if let buf = renderFrame() {
            if displayLayer.isReadyForMoreMediaData {
                displayLayer.enqueue(buf)
            }
        }
    }

    // MARK: - 渲染

    private func renderFrame() -> CMSampleBuffer? {
        let renderer = UIGraphicsImageRenderer(size: canvasSize)
        let img = renderer.image { ctx in
            let cg = ctx.cgContext
            var bg = UIColor(red: 0.12, green: 0.44, blue: 0.23, alpha: 1)
            if latestThreat >= 0.70 {
                bg = UIColor(red: 0.69, green: 0.0, blue: 0.13, alpha: 1)
            } else if latestThreat >= 0.45 {
                bg = UIColor(red: 0.76, green: 0.27, blue: 0.05, alpha: 1)
            } else if latestThreat >= 0.25 {
                bg = UIColor(red: 0.72, green: 0.53, blue: 0.04, alpha: 1)
            }
            cg.setFillColor(bg.cgColor)
            cg.fill(CGRect(x: 0, y: 0, width: canvasSize.width, height: canvasSize.height))

            let pct = String(format: "%.0f%%", latestThreat * 100)
            let a1: [NSAttributedString.Key: Any] = [
                .font: UIFont.monospacedDigitSystemFont(ofSize: 44, weight: .bold),
                .foregroundColor: UIColor.white,
            ]
            (pct as NSString).draw(at: CGPoint(x: 12, y: 8), withAttributes: a1)

            drawMarkers(cg)
        }
        return img.toSampleBuffer(size: canvasSize)
    }

    private func drawMarkers(_ cg: CGContext) {
        let box = CGRect(x: 8, y: 70,
                         width: canvasSize.width - 16,
                         height: canvasSize.height - 78)
        cg.setFillColor(UIColor(white: 0.1, alpha: 0.55).cgColor)
        cg.fill(box)

        if latestMarkers.isEmpty { return }
        for part in latestMarkers.split(separator: ";") {
            let f = part.split(separator: ",")
            if f.count < 4 { continue }
            let tag = String(f[0])
            guard let x = Double(f[1]), let y = Double(f[2]),
                  let unc = Double(f[3]) else { continue }
            let px = box.minX + CGFloat(x) * box.width
            let py = box.minY + CGFloat(y) * box.height

            if tag == "S" {
                cg.setFillColor(UIColor(red: 1, green: 0.25, blue: 0.25, alpha: 1).cgColor)
                cg.fillEllipse(in: CGRect(x: px - 5, y: py - 5, width: 10, height: 10))
            } else {
                cg.setStrokeColor(UIColor(red: 1, green: 0.78, blue: 0, alpha: 1).cgColor)
                cg.setLineWidth(2)
                let r = max(6, CGFloat(unc) * box.width)
                cg.strokeEllipse(in: CGRect(x: px - r, y: py - r,
                                            width: r * 2, height: r * 2))
                cg.strokeEllipse(in: CGRect(x: px - 4, y: py - 4, width: 8, height: 8))
            }
        }
    }
}

// MARK: - 代理

extension PiPOverlay: AVPictureInPictureControllerDelegate {
}

extension PiPOverlay: AVPictureInPictureSampleBufferPlaybackDelegate {
    func pictureInPictureController(_ c: AVPictureInPictureController,
                                    setPlaying playing: Bool) {}

    func pictureInPictureControllerTimeRangeForPlayback(
        _ c: AVPictureInPictureController) -> CMTimeRange {
        return CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
    }

    func pictureInPictureControllerIsPlaybackPaused(
        _ c: AVPictureInPictureController) -> Bool {
        return false
    }

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
    func toSampleBuffer(size: CGSize) -> CMSampleBuffer? {
        guard let cg = self.cgImage else { return nil }

        var pb: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
        ]
        let st = CVPixelBufferCreate(kCFAllocatorDefault,
                                     Int(size.width), Int(size.height),
                                     kCVPixelFormatType_32BGRA,
                                     attrs as CFDictionary, &pb)
        guard st == kCVReturnSuccess, let pixelBuffer = pb else { return nil }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let bpr = CVPixelBufferGetBytesPerRow(pixelBuffer)

        let info = CGImageAlphaInfo.premultipliedFirst.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue
        guard let ctx = CGContext(data: base,
                                  width: Int(size.width),
                                  height: Int(size.height),
                                  bitsPerComponent: 8,
                                  bytesPerRow: bpr,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: info) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: size.width, height: size.height))

        var format: CMFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
                                                     imageBuffer: pixelBuffer,
                                                     formatDescriptionOut: &format)
        guard let fmt = format else { return nil }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 10),
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: CMTime.invalid)
        var sb: CMSampleBuffer?
        let err = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: fmt,
            sampleTiming: &timing,
            sampleBufferOut: &sb)
        guard err == noErr else { return nil }
        return sb
    }
}
