//
//  SampleHandler.swift
//  ReplayKit Broadcast Upload Extension —— 读屏的唯一合法途径
//
//  这是整个方案的入口：只有扩展能拿到屏幕帧（ReplayKit 设计如此）。
//
//  ⚠️ 关键约束：扩展内存受限（常被引用为 ~50MB），超出会被系统 kill
//     且**没有崩溃日志**。所以这里只做轻量解析，不做重计算。
//     内存上限未经实机验证，是必须实测的第一个数字。
//

import ReplayKit
import CoreVideo
import Foundation
import os.log

final class SampleHandler: RPBroadcastSampleHandler {

    private let parser = MinimapParser()
    private let graph = MapGraph(res: 96)
    private lazy var tracker = BeliefTracker(graph: graph)
    private let renderer: GhostRenderer

    private var startTime: Date?
    private var frameCount = 0
    private var lastProcessed = Date.distantPast
    /// 处理频率：10 FPS 足够（英雄移速 0.045/s，10Hz 分辨率 = 0.0045 地图/帧）
    private let minInterval: TimeInterval = 0.1
    /// 小地图裁剪区域（归一化）—— 需按真实画面校准
    private var minimapCrop = CGRect(x: 0.0, y: 0.62, width: 0.24, height: 0.38)

    override init() {
        self.renderer = GhostRenderer(graph: graph)
        super.init()
    }

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        startTime = Date()
        frameCount = 0
        SharedStore.reset()
        SharedStore.log("broadcast started")
    }

    override func broadcastFinished() {
        SharedStore.log("broadcast finished, frames=\(frameCount)")
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer,
                                      with sampleBufferType: RPSampleBufferType) {
        // 只处理视频帧
        guard sampleBufferType == .video else { return }

        let now = Date()
        guard now.timeIntervalSince(lastProcessed) >= minInterval else { return }
        lastProcessed = now
        frameCount += 1

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }
        let w = CVPixelBufferGetWidth(pixelBuffer)
        let h = CVPixelBufferGetHeight(pixelBuffer)
        let bpr = CVPixelBufferGetBytesPerRow(pixelBuffer)

        // 裁剪小地图区域（在原始像素上算偏移）
        let x0 = Int(Double(w) * minimapCrop.minX)
        let y0 = Int(Double(h) * minimapCrop.minY)
        let cw = Int(Double(w) * minimapCrop.width)
        let ch = Int(Double(h) * minimapCrop.height)
        guard cw > 8, ch > 8, x0 + cw <= w, y0 + ch <= h else { return }

        let ptr = base.assumingMemoryBound(to: UInt8.self)
        let offset = y0 * bpr + x0 * 4

        // ---- 轻量解析：只做 HSV + 连通域 ----
        let state = parser.parse(bgra: ptr + offset, width: cw, height: ch,
                                 bytesPerRow: bpr)

        // ---- 更新跟踪器 ----
        let t = now.timeIntervalSince(startTime ?? now)
        let selfPos = SIMD2<Double>(0.62, 0.88)   // TODO: 从画面识别我方位置
        let enemyPositions = state.enemies.map { $0.pos }
        let allyPositions = state.allies.map { $0.pos }

        _ = tracker.step(ts: t, selfPos: selfPos,
                         allyPositions: allyPositions,
                         enemyPositions: enemyPositions)

        // ---- 生成绘制指令 ----
        let markers = renderer.evaluate(tracker, ts: t)
        let encoded = renderer.encode(markers)

        // ---- 写出到共享存储（App Group 或 localhost）----
        SharedStore.send(ts: t, threat: topThreat(), markers: encoded)

        // 每 30 帧记录一次内存占用（用于实测扩展内存上限）
        if frameCount % 30 == 0 {
            SharedStore.log("frames=\(frameCount) mem=\(memoryFootprintMB())MB markers=\(markers.count)")
        }
    }

    /// 最高威胁（给 PiP 显示用）
    private func topThreat() -> Double {
        let target = SIMD2<Double>(0.62, 0.88)
        let rows = tracker.threat(target, horizons: [10])
        var best = 0.0
        for r in rows {
            if let p = r["p10s"] as? Double, p > best { best = p }
        }
        return best
    }

    /// 当前进程内存占用（MB）—— 用于实测扩展内存上限
    private func memoryFootprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return -1 }
        return Double(info.phys_footprint) / 1024.0 / 1024.0
    }
}