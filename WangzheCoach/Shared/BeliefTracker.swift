//
//  BeliefTracker.swift
//  共享层：贝叶斯位置跟踪 + 可达域约束 + 行进环先验
//
//  Python 版 routepredict.py 的 Swift 移植。
//  Python 侧实测：判别力 AUC 0.981，召回 100%、误报 0%（消失 4~8 秒）。
//
//  ⚠️ Swift 移植版未经实机验证。
//

import Foundation
import simd

// MARK: - 视野模型

/// 视野 = 我方可见单位的半径并集。
///
/// 只做圆形不做锥形，是**故意保守**：宁可少消除一些区域，
/// 也不要错误地"清空"一块其实看不见的地方 —— 那会导致漏报。
public struct VisionModel {
    public static let heroR: Double = 0.105
    public static let towerR: Double = 0.100
    public static let minionR: Double = 0.060
    public static let wardR: Double = 0.080

    private let graph: MapGraph
    public init(graph: MapGraph) { self.graph = graph }

    /// 计算可见掩码
    public func compute(self selfPos: SIMD2<Double>?,
                        allies: [SIMD2<Double>] = [],
                        towers: [SIMD2<Double>] = [],
                        minions: [SIMD2<Double>] = [],
                        wards: [SIMD2<Double>] = []) -> [Bool] {
        let r = graph.res
        var mask = [Bool](repeating: false, count: r * r)

        func paint(_ p: SIMD2<Double>, _ rad: Double) {
            let r2 = rad * rad
            let (cx, cy) = graph.toCell(p)
            let span = Int(ceil(rad / graph.cell)) + 1
            let x0 = max(0, cx - span), x1 = min(r - 1, cx + span)
            let y0 = max(0, cy - span), y1 = min(r - 1, cy + span)
            for gy in y0...y1 {
                let py = Double(gy) * graph.cell
                for gx in x0...x1 {
                    let px = Double(gx) * graph.cell
                    let dx = px - p.x, dy = py - p.y
                    if dx * dx + dy * dy <= r2 { mask[gy * r + gx] = true }
                }
            }
        }

        if let sp = selfPos { paint(sp, VisionModel.heroR) }
        for p in allies { paint(p, VisionModel.heroR) }
        for p in towers { paint(p, VisionModel.towerR) }
        for p in minions { paint(p, VisionModel.minionR) }
        for p in wards { paint(p, VisionModel.wardR) }

        for i in 0..<(r * r) where !graph.walk[i] { mask[i] = false }
        return mask
    }
}

// MARK: - 单个敌方状态

public final class EnemyState {
    public let name: String
    public var belief: [Double]
    public var lastSeenT: Double
    public var lastSeenPos: SIMD2<Double>?
    public var missingSince: Double?

    init(name: String, belief: [Double], lastSeenT: Double,
         lastSeenPos: SIMD2<Double>?, missingSince: Double? = nil) {
        self.name = name
        self.belief = belief
        self.lastSeenT = lastSeenT
        self.lastSeenPos = lastSeenPos
        self.missingSince = missingSince
    }

    /// 最大后验位置（格）
    public func mapEstimate() -> (Int, Int) {
        var bi = 0
        var bv = -Double.infinity
        for i in 0..<belief.count where belief[i] > bv {
            bv = belief[i]; bi = i
        }
        return (bi % Int(sqrt(Double(belief.count))), bi / Int(sqrt(Double(belief.count))))
    }
}

// MARK: - 跟踪器

public final class BeliefTracker {

    public let graph: MapGraph
    public let vision: VisionModel

    /// 漏检率：可见区域内没看到敌方的概率
    public var pMiss: Double = 0.18
    /// 观测高斯核宽度（格）
    public var sigma: Double = 2.0
    /// 原地不动权重
    public var stay: Double = 0.12
    /// 草丛权重（英雄蹲草更可能）
    public var grassBoost: Double = 1.35
    /// 回城风险率
    public var recallHazard: Double = 0.015
    /// 位移技能预算
    public var dashBudget: Double = MapConst.dashNorm
    /// 关联容差（秒）
    public var gateTolerance: Double = 0.6
    /// 静止权重
    public var stationaryW: Double = 0.30
    /// 行进环宽度比例
    public var ringSigmaRatio: Double = 0.35
    /// 失联混合时间常数（秒）—— 越小越保守
    public var lostTrackTau: Double = 15.0
    /// 长期未见视为回家
    public var dropAfterMissing: Double = 40.0

    public private(set) var trackers: [EnemyState] = []
    public private(set) var t: Double?

    private var distCache: [Int: [Double]] = [:]
    private var fieldCache: [Int: [Double]] = [:]

    public init(graph: MapGraph, vision: VisionModel? = nil) {
        self.graph = graph
        self.vision = vision ?? VisionModel(graph: graph)
    }

    // MARK: 基础分布

    private func uniform(center: SIMD2<Double>, radius: Double) -> [Double] {
        let r = graph.res
        var b = [Double](repeating: 0, count: r * r)
        var sum = 0.0
        let rad2 = radius * radius
        for gy in 0..<r {
            let py = Double(gy) * graph.cell
            for gx in 0..<r {
                let px = Double(gx) * graph.cell
                let dx = px - center.x, dy = py - center.y
                if dx * dx + dy * dy <= rad2 && graph.walk[gy * r + gx] {
                    b[gy * r + gx] = 1; sum += 1
                }
            }
        }
        if sum == 0 { return graph.walk.map { $0 ? 1.0 : 0.0 } }
        return b.map { $0 / sum }
    }

    private func gauss(center: (Int, Int)) -> [Double] {
        let r = graph.res
        var k = [Double](repeating: 0, count: r * r)
        let rad = max(2, Int(ceil(sigma * 3)))
        let denom = 2 * sigma * sigma
        for gy in max(0, center.1 - rad)...min(r - 1, center.1 + rad) {
            for gx in max(0, center.0 - rad)...min(r - 1, center.0 + rad) {
                let dx = Double(gx - center.0), dy = Double(gy - center.1)
                let d2 = dx * dx + dy * dy
                if d2 <= Double(rad * rad) {
                    k[gy * r + gx] = exp(-d2 / denom)
                }
            }
        }
        return k
    }

    /// 测地距离（格），带缓存
    private func geodesic(_ cell: (Int, Int)) -> [Double] {
        let key = cell.1 * graph.res + cell.0
        if let c = distCache[key] { return c }
        let (cost, _) = graph.dijkstra(cell)
        if distCache.count > 64 { distCache.removeAll() }
        distCache[key] = cost
        return cost
    }

    // MARK: 可达域先验（含行进环）

    /// 可达域硬约束 + 行进环先验。
    ///
    /// 纯扩散先验是错的：随机游走 t 秒的标准差只有 √t 格，
    /// 而最大位移是 t 格 —— 概率质量堆在原地，等于在说"他还在原地"，
    /// 与抓人威胁恰好相反，会漏报。实测确认后改成行进环。
    private func applyReachablePrior(_ st: EnemyState, _ ts: Double) {
        guard let lastPos = st.lastSeenPos else { return }
        let dt = max(0, ts - st.lastSeenT)
        let r = graph.res
        let r0 = MapConst.speedNorm * dt
        let radius = r0 + dashBudget
        let src = graph.snap(graph.toCell(lastPos).0, graph.toCell(lastPos).1)
        let D = geodesic(src)
        let radiusCells = radius / graph.cell

        var prior = [Double](repeating: 0, count: r * r)
        if dt <= 1e-6 {
            for i in 0..<(r * r) { prior[i] = 1 }
        } else {
            let sigmaRing = max(0.06, ringSigmaRatio * r0)
            for i in 0..<(r * r) {
                let d = D[i]
                if !d.isFinite || d > radiusCells { continue }
                let dNorm = d * graph.cell
                let x = (dNorm - r0) / sigmaRing
                prior[i] = (1 - stationaryW) * exp(-x * x) + stationaryW
            }
        }

        var b = [Double](repeating: 0, count: r * r)
        var sum = 0.0
        for i in 0..<(r * r) {
            if !graph.walk[i] { continue }
            b[i] = st.belief[i] * prior[i]
            sum += b[i]
        }

        // 失联混合：无观测时不确定性应趋于可达域内均匀。
        // tau 越大越保守（越慢摊平）。实测 tau=10 会摧毁判别力（误报 100%），
        // 所以默认 15，并由 tune 脚本扫描确认。
        if lostTrackTau > 0 && dt > 0 {
            let alpha = 1 - exp(-dt / lostTrackTau)
            var uni = [Double](repeating: 0, count: r * r)
            var us = 0.0
            for i in 0..<(r * r) {
                if graph.walk[i] && D[i].isFinite && D[i] <= radiusCells {
                    uni[i] = 1; us += 1
                }
            }
            if us > 0 && sum > 0 {
                for i in 0..<(r * r) {
                    b[i] = (b[i] / sum) * (1 - alpha) + (uni[i] / us) * alpha
                }
                sum = 0
                for i in 0..<(r * r) { sum += b[i] }
            }
        }

        if sum <= 1e-12 {
            for i in 0..<(r * r) {
                b[i] = (graph.walk[i] && D[i].isFinite && D[i] <= radiusCells) ? 1 : 0
                sum += b[i]
            }
        }
        if sum > 0 { st.belief = b.map { $0 / sum } }
    }

    private func applyRecall(_ st: EnemyState, _ dt: Double, base: SIMD2<Double>) {
        guard recallHazard > 0, dt > 0 else { return }
        let p = 1 - exp(-recallHazard * dt)
        let home = uniform(center: base, radius: 0.13)
        var sum = 0.0
        for i in 0..<st.belief.count {
            st.belief[i] = st.belief[i] * (1 - p) + home[i] * p
            sum += st.belief[i]
        }
        if sum > 0 { st.belief = st.belief.map { $0 / sum } }
    }

    // MARK: 观测更新

    private func update(_ st: EnemyState, visible: [Bool], det: (Int, Int)?) {
        let n = st.belief.count
        var b = st.belief
        if let d = det {
            let g = gauss(center: d)
            for i in 0..<n { b[i] *= (1 - pMiss) * g[i] + pMiss * (1 - g[i]) }
        } else {
            for i in 0..<n where visible[i] { b[i] *= pMiss }
        }
        var sum = 0.0
        for i in 0..<n {
            if !graph.walk[i] { b[i] = 0 }
            sum += b[i]
        }
        if sum <= 1e-12 {
            if let d = det {
                b = gauss(center: d)
            } else {
                b = graph.walk.map { $0 ? 1.0 : 0.0 }
            }
            sum = b.reduce(0, +)
        }
        if sum > 0 { st.belief = b.map { $0 / sum } }
    }

    // MARK: 观测关联（测地时间门限）

    /// 用**测地行程时间**做门限，而不是固定欧氏距离。
    ///
    /// 为什么不能用固定距离：敌方消失 6 秒后可以合法走出 0.27 的距离。
    /// 固定门限会把他重新出现的位置判成"不可能是同一人" → 新建轨迹 → 幽灵轨迹。
    private func assign(_ dets: [SIMD2<Double>], ts: Double) -> ([Int: SIMD2<Double>], [SIMD2<Double>]) {
        guard !trackers.isEmpty else { return ([:], dets) }
        let n = trackers.count, m = dets.count
        var cost = [[Double]](repeating: [Double](repeating: .infinity, count: m), count: n)
        let detCells = dets.map { graph.snap(graph.toCell($0).0, graph.toCell($0).1) }

        for (i, st) in trackers.enumerated() {
            if let lastPos = st.lastSeenPos {
                let elapsed = max(0, ts - st.lastSeenT)
                let budget = elapsed + gateTolerance + dashBudget / MapConst.speedNorm
                let src = graph.snap(graph.toCell(lastPos).0, graph.toCell(lastPos).1)
                let D = geodesic(src)
                for j in 0..<m {
                    let cells = D[graph.index(detCells[j].0, detCells[j].1)]
                    guard cells.isFinite else { continue }
                    let secs = cells * graph.cell / MapConst.speedNorm
                    if secs <= budget { cost[i][j] = secs }
                }
            } else {
                let (mx, my) = st.mapEstimate()
                let mp = graph.toNorm(mx, my)
                for j in 0..<m {
                    let d = simd_distance(mp, dets[j])
                    if d <= 0.16 { cost[i][j] = d / MapConst.speedNorm }
                }
            }
        }

        var out: [Int: SIMD2<Double>] = [:]
        var usedT = Set<Int>(), usedD = Set<Int>()
        while true {
            var best: (Double, Int, Int)?
            for i in 0..<n where !usedT.contains(i) {
                for j in 0..<m where !usedD.contains(j) {
                    if cost[i][j].isFinite {
                        if best == nil || cost[i][j] < best!.0 { best = (cost[i][j], i, j) }
                    }
                }
            }
            guard let (_, i, j) = best else { break }
            usedT.insert(i); usedD.insert(j); out[i] = dets[j]
        }
        let leftover = (0..<m).filter { !usedD.contains($0) }.map { dets[$0] }
        return (out, leftover)
    }

    // MARK: 主步进

    @discardableResult
    public func step(ts: Double,
                     selfPos: SIMD2<Double>,
                     allyPositions: [SIMD2<Double>] = [],
                     enemyPositions: [SIMD2<Double>] = [],
                     towerPositions: [SIMD2<Double>] = [],
                     minionPositions: [SIMD2<Double>] = [],
                     wardPositions: [SIMD2<Double>] = [],
                     ourSide: String = "red") -> Int {
        let dt = t == nil ? 0 : max(0, ts - t!)
        t = ts
        let enemyBase = ourSide == "red" ? MapConst.baseBlue : MapConst.baseRed

        if dt > 0 {
            for st in trackers {
                applyRecall(st, dt, base: enemyBase)
                applyReachablePrior(st, ts)
            }
        }

        let visible = vision.compute(self: selfPos, allies: allyPositions,
                                     towers: towerPositions,
                                     minions: minionPositions, wards: wardPositions)

        let (assigned, leftover) = assign(enemyPositions, ts: ts)

        for (i, st) in trackers.enumerated() {
            if let det = assigned[i] {
                let c = graph.snap(graph.toCell(det).0, graph.toCell(det).1)
                update(st, visible: visible, det: c)
                st.lastSeenPos = det
                st.lastSeenT = ts
                st.missingSince = nil
            } else {
                update(st, visible: visible, det: nil)
                if st.missingSince == nil { st.missingSince = ts }
            }
        }

        for d in leftover where trackers.count < 5 {
            let c = graph.snap(graph.toCell(d).0, graph.toCell(d).1)
            var b = gauss(center: c)
            let s = b.reduce(0, +)
            if s > 0 { b = b.map { $0 / s } }
            trackers.append(EnemyState(name: "enemy\(trackers.count + 1)",
                                       belief: b, lastSeenT: ts, lastSeenPos: d))
        }

        trackers.removeAll { st in
            if let ms = st.missingSince, ts - ms > dropAfterMissing { return true }
            return false
        }
        return trackers.count
    }

    // MARK: 到达时间场

    public func arrivalField(target: SIMD2<Double>) -> [Double] {
        let tc = graph.snap(graph.toCell(target).0, graph.toCell(target).1)
        let key = tc.1 * graph.res + tc.0
        if let f = fieldCache[key] { return f }
        let (cost, _) = graph.dijkstra(tc)
        let f = cost.map { $0 * graph.cell / MapConst.speedNorm }
        if fieldCache.count > 16 { fieldCache.removeAll() }
        fieldCache[key] = f
        return f
    }

    /// 每个敌方在 h 秒内到达 target 的概率
    public func threat(_ target: SIMD2<Double>, horizons: [Double] = [5, 10, 15, 20]) -> [[String: Any]] {
        let T = arrivalField(target: target)
        var out: [[String: Any]] = []
        for st in trackers {
            var row: [String: Any] = [
                "name": st.name,
                "missing_s": st.missingSince as Any,
                "last_seen": st.lastSeenPos as Any,
            ]
            for h in horizons {
                var mass = 0.0
                for i in 0..<T.count where T[i].isFinite && T[i] <= h && graph.walk[i] {
                    mass += st.belief[i]
                }
                row["p\(Int(h))s"] = mass
            }
            out.append(row)
        }
        return out
    }
}