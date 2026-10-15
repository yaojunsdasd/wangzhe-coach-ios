//
//  GhostRenderer.swift
//  共享层：三态绘制决策（SOLID / GHOST / HIDDEN）
//
//  Python 版 ghost_overlay.py 的 Swift 移植。
//  核心需求：**真实漏视野时不绘制**。
//
//  判据全部做成尺度无关的 —— 绝对概率阈值不可移植（实测踩过）。
//

import Foundation
import simd

public enum RenderMode: Int {
    case solid = 0   // 当前可见，实心
    case ghost = 1   // 推断中，幽灵
    case hidden = 2  // 信息不足，不绘制
}

public struct GhostMarker {
    public let unit: String
    public let mode: RenderMode
    public let pos: SIMD2<Double>?
    public let uncertainty: Double     // 不确定性半径（归一化）
    public let peakRatio: Double       // 信念浓缩倍数（尺度无关）
    public let areaRatio: Double       // 可信区占可通行面积比
    public let age: Double?            // 距上次可见秒数
    public let reason: String

    public var drawable: Bool { mode != .hidden }
}

public final class GhostRenderer {

    public let graph: MapGraph

    /// 信念浓缩倍数下限（1.0 = 完全均匀 = 无信息）
    public var peakRatioMin: Double = 5.0
    /// 可信区面积占比上限
    public var areaMax: Double = 0.30
    /// 消失时长上限（秒）
    public var ageMax: Double = 40.0
    /// 可信区质量
    public var credibleMass: Double = 0.80

    private let walkable: Int

    public init(graph: MapGraph) {
        self.graph = graph
        self.walkable = max(graph.walk.filter { $0 }.count, 1)
    }

    /// 对每个跟踪目标给出绘制决策。
    public func evaluate(_ tracker: BeliefTracker, ts: Double) -> [GhostMarker] {
        var out: [GhostMarker] = []
        for st in tracker.trackers {
            // SOLID：当前可见
            if st.missingSince == nil {
                let (mx, my) = st.mapEstimate()
                out.append(GhostMarker(unit: st.name, mode: .solid,
                                       pos: graph.toNorm(mx, my),
                                       uncertainty: 0.02, peakRatio: Double(walkable),
                                       areaRatio: 0, age: nil, reason: "可见"))
                continue
            }

            let age = ts - st.missingSince!
            let peak = st.belief.max() ?? 0
            let peakRatio = peak * Double(walkable)

            // 可信区：取概率最高的若干格直到累计质量达标
            var order = (0..<st.belief.count).sorted { st.belief[$0] > st.belief[$1] }
            var cum = 0.0
            var regionCount = 0
            for idx in order {
                cum += st.belief[idx]
                regionCount += 1
                if cum >= credibleMass { break }
            }
            order.removeAll(keepingCapacity: false)

            let areaRatio = Double(regionCount) / Double(walkable)
            let cellArea = graph.cell * graph.cell
            let radius = (Double(regionCount) * cellArea / Double.pi).squareRoot()

            var mode = RenderMode.ghost
            var reason = ""
            if age > ageMax {
                mode = .hidden; reason = String(format: "消失%.0fs>%.0fs", age, ageMax)
            } else if peakRatio < peakRatioMin {
                mode = .hidden
                reason = String(format: "浓缩%.1fx<%.0fx", peakRatio, peakRatioMin)
            } else if areaRatio > areaMax {
                mode = .hidden
                reason = String(format: "可信区%.0f%%>%.0f%%", areaRatio * 100, areaMax * 100)
            }

            let (mx, my) = st.mapEstimate()
            out.append(GhostMarker(unit: st.name, mode: mode,
                                   pos: graph.toNorm(mx, my),
                                   uncertainty: radius, peakRatio: peakRatio,
                                   areaRatio: areaRatio, age: age, reason: reason))
        }
        return out
    }

    /// 生成给 PiP 显示的紧凑指令串。
    ///
    /// 只传"画什么"，不传栅格 —— 扩展内存受限，PiP 在扩展里跑。
    public func encode(_ markers: [GhostMarker]) -> String {
        var parts: [String] = []
        for m in markers where m.drawable {
            guard let p = m.pos else { continue }
            let tag = m.mode == .solid ? "S" : "G"
            let ageStr = m.age.map { String(format: "%.0f", $0) } ?? "-"
            parts.append(String(format: "%@,%.3f,%.3f,%.3f,%@",
                                tag, p.x, p.y, m.uncertainty, ageStr))
        }
        return parts.joined(separator: ";")
    }
}
