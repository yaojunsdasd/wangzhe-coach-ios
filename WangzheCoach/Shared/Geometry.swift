//
//  Geometry.swift
//  共享层：地图图结构 + 测地距离 + 视野模型
//
//  这是 Python 版 mapgraph.py / routepredict.py 的 Swift 移植。
//  算法已在 Python 侧实测（几何标定 7/7 通过，判别力 AUC 0.981）。
//
//  ⚠️ 未经 iOS 实机验证。Python 侧验证的是算法正确性，
//     不等于 Swift 移植版在 iOS 上的行为一致 —— 需要实机跑通才算数。
//

import Foundation
import simd

// MARK: - 基础常量

public enum MapConst {
    /// 归一化移速（地图宽度 = 1.0）
    public static let speedNorm: Double = 0.045
    /// 位移技能一次性额外位移预算
    public static let dashNorm: Double = 0.055
    /// 红方基地
    public static let baseRed = SIMD2<Double>(0.10, 0.90)
    /// 蓝方基地
    public static let baseBlue = SIMD2<Double>(0.90, 0.10)
}

// MARK: - 地图几何

/// 一条折线路径（三路 / 河道 / 野区通道）
public struct Polyline {
    public let points: [SIMD2<Double>]
    public init(_ pts: [(Double, Double)]) {
        self.points = pts.map { SIMD2($0.0, $0.1) }
    }
}

public enum MapGeometry {
    /// 三路（与 Python 版一致）
    public static let lanes: [String: Polyline] = [
        "mid": Polyline([(0.10, 0.90), (0.50, 0.50), (0.90, 0.10)]),
        "bot": Polyline([(0.10, 0.90), (0.86, 0.88), (0.90, 0.72), (0.90, 0.10)]),
        "top": Polyline([(0.10, 0.90), (0.12, 0.28), (0.28, 0.12), (0.90, 0.10)]),
    ]

    public static let river = Polyline([(0.16, 0.16), (0.50, 0.50), (0.84, 0.84)])

    /// 野区通道 —— 缺了这些，河道→下路的行程会被高估一倍
    public static let jungle: [String: Polyline] = [
        "red_j_bot_inner": Polyline([(0.38, 0.38), (0.34, 0.60), (0.30, 0.86)]),
        "red_j_bot_outer": Polyline([(0.58, 0.58), (0.62, 0.70), (0.62, 0.86)]),
        "red_j_mid": Polyline([(0.34, 0.60), (0.42, 0.46)]),
        "red_j_ring": Polyline([(0.30, 0.86), (0.20, 0.74), (0.30, 0.62),
                                (0.44, 0.70), (0.62, 0.86)]),
        "blue_j_top_inner": Polyline([(0.62, 0.62), (0.66, 0.40), (0.70, 0.14)]),
        "blue_j_top_outer": Polyline([(0.42, 0.42), (0.38, 0.30), (0.38, 0.14)]),
        "blue_j_mid": Polyline([(0.66, 0.40), (0.58, 0.54)]),
        "blue_j_ring": Polyline([(0.70, 0.14), (0.80, 0.26), (0.70, 0.38),
                                 (0.56, 0.30), (0.38, 0.14)]),
    ]

    /// 障碍（圆形）
    public static let obstacles: [(x: Double, y: Double, r: Double)] = [
        (0.46, 0.46, 0.045), (0.54, 0.54, 0.045),
        (0.50, 0.32, 0.032), (0.50, 0.68, 0.032),
        (0.32, 0.50, 0.032), (0.68, 0.50, 0.032),
    ]

    /// 草丛（圆形）
    public static let grass: [(x: Double, y: Double, r: Double)] = [
        (0.30, 0.86, 0.048), (0.62, 0.86, 0.048),
        (0.22, 0.22, 0.045), (0.78, 0.78, 0.045),
        (0.42, 0.42, 0.040), (0.58, 0.58, 0.040),
        (0.30, 0.62, 0.040), (0.62, 0.70, 0.040),
        (0.20, 0.74, 0.038), (0.80, 0.26, 0.038),
    ]
}

// MARK: - 点到线段距离

@inline(__always)
func pointSegmentDistance(_ p: SIMD2<Double>, _ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double {
    let ab = b - a
    let l2 = simd_length_squared(ab)
    if l2 <= 1e-12 { return simd_distance(p, a) }
    var t = simd_dot(p - a, ab) / l2
    t = min(max(t, 0.0), 1.0)
    return simd_distance(p, a + t * ab)
}

// MARK: - 地图图结构

/// 可通行网格 + Dijkstra 测地距离。
///
/// 网格用扁平数组存，索引 = y * res + x，与 Python 版一致。
public final class MapGraph {

    public let res: Int
    public let cell: Double
    public private(set) var walk: [Bool]
    public private(set) var grassMask: [Bool]

    private let corridor: Double
    private let baseRadius: Double
    private let grassDiscount: Double

    public init(res: Int = 96, corridor: Double = 0.042,
                baseRadius: Double = 0.11, grassDiscount: Double = 0.90) {
        self.res = res
        self.corridor = corridor
        self.baseRadius = baseRadius
        self.grassDiscount = grassDiscount
        self.cell = 1.0 / Double(res - 1)
        self.walk = [Bool](repeating: false, count: res * res)
        self.grassMask = [Bool](repeating: false, count: res * res)
        build()
    }

    // MARK: 构建

    private func build() {
        var dist = [Double](repeating: 1e9, count: res * res)

        func paint(_ poly: Polyline, _ width: Double) {
            for i in 0..<(poly.points.count - 1) {
                let a = poly.points[i], b = poly.points[i + 1]
                for gy in 0..<res {
                    let py = Double(gy) * cell
                    for gx in 0..<res {
                        let px = Double(gx) * cell
                        let d = pointSegmentDistance(SIMD2(px, py), a, b)
                        let idx = gy * res + gx
                        if d < dist[idx] { dist[idx] = d }
                    }
                }
            }
        }

        for (_, poly) in MapGeometry.lanes { paint(poly, corridor) }
        for (_, poly) in MapGeometry.jungle { paint(poly, corridor * 0.85) }
        paint(MapGeometry.river, corridor * 0.8)

        for gy in 0..<res {
            let py = Double(gy) * cell
            for gx in 0..<res {
                let px = Double(gx) * cell
                let idx = gy * res + gx
                var ok = dist[idx] < corridor

                if simd_distance(SIMD2(px, py), MapConst.baseRed) < baseRadius { ok = true }
                if simd_distance(SIMD2(px, py), MapConst.baseBlue) < baseRadius { ok = true }

                for ob in MapGeometry.obstacles {
                    if simd_distance(SIMD2(px, py), SIMD2(ob.x, ob.y)) < ob.r { ok = false; break }
                }
                walk[idx] = ok
            }
        }

        for gy in 0..<res {
            let py = Double(gy) * cell
            for gx in 0..<res {
                let px = Double(gx) * cell
                let idx = gy * res + gx
                var inGrass = false
                for g in MapGeometry.grass {
                    if simd_distance(SIMD2(px, py), SIMD2(g.x, g.y)) < g.r { inGrass = true; break }
                }
                grassMask[idx] = inGrass && walk[idx]
            }
        }
    }

    // MARK: 坐标转换

    @inline(__always)
    public func toCell(_ p: SIMD2<Double>) -> (Int, Int) {
        let gx = min(max(Int((p.x / cell).rounded()), 0), res - 1)
        let gy = min(max(Int((p.y / cell).rounded()), 0), res - 1)
        return (gx, gy)
    }

    @inline(__always)
    public func toNorm(_ gx: Int, _ gy: Int) -> SIMD2<Double> {
        return SIMD2(Double(gx) * cell, Double(gy) * cell)
    }

    @inline(__always)
    public func index(_ gx: Int, _ gy: Int) -> Int { gy * res + gx }

    public func isWalk(_ gx: Int, _ gy: Int) -> Bool {
        guard gx >= 0, gy >= 0, gx < res, gy < res else { return false }
        return walk[gy * res + gx]
    }

    /// 把不可通行格吸附到最近可通行格
    public func snap(_ gx: Int, _ gy: Int) -> (Int, Int) {
        if isWalk(gx, gy) { return (gx, gy) }
        var best = (0, 0)
        var bestD = Double.greatestFiniteMagnitude
        for y in 0..<res {
            for x in 0..<res where walk[y * res + x] {
                let dx = Double(x - gx), dy = Double(y - gy)
                let d = dx * dx + dy * dy
                if d < bestD { bestD = d; best = (x, y) }
            }
        }
        return best
    }

    // MARK: Dijkstra

    private static let neighbors: [(Int, Int, Double)] = [
        (1, 0, 1.0), (-1, 0, 1.0), (0, 1, 1.0), (0, -1, 1.0),
        (1, 1, 1.41421356), (1, -1, 1.41421356),
        (-1, 1, 1.41421356), (-1, -1, 1.41421356),
    ]

    /// 单源最短路（单位：格）。返回 (cost, prev)。
    public func dijkstra(_ start: (Int, Int)) -> (cost: [Double], prev: [Int]) {
        let n = res * res
        var cost = [Double](repeating: .infinity, count: n)
        var prev = [Int](repeating: -1, count: n)
        let (sx, sy) = snap(start.0, start.1)
        let s = sy * res + sx
        cost[s] = 0

        // 简单二叉堆
        var heap = MinHeap()
        heap.push(0, s)

        while let (c, idx) = heap.pop() {
            if c > cost[idx] + 1e-12 { continue }
            let x = idx % res, y = idx / res
            for (dx, dy, w) in MapGraph.neighbors {
                let nx = x + dx, ny = y + dy
                guard nx >= 0, ny >= 0, nx < res, ny < res else { continue }
                let ni = ny * res + nx
                guard walk[ni] else { continue }
                var step = w
                if grassDiscount < 1.0 && grassMask[ni] { step *= grassDiscount }
                let nc = c + step
                if nc < cost[ni] - 1e-12 {
                    cost[ni] = nc
                    prev[ni] = idx
                    heap.push(nc, ni)
                }
            }
        }
        return (cost, prev)
    }

    /// 行程时间（秒）
    public func travelSeconds(from a: SIMD2<Double>, to b: SIMD2<Double>) -> Double {
        let ca = snap(toCell(a).0, toCell(a).1)
        let cb = snap(toCell(b).0, toCell(b).1)
        let (cost, _) = dijkstra(ca)
        let c = cost[index(cb.0, cb.1)]
        guard c.isFinite else { return .infinity }
        return c * cell / MapConst.speedNorm
    }

    /// 从 target 反向的行程时间场（秒）
    public func timeField(target: SIMD2<Double>) -> [Double] {
        let tc = snap(toCell(target).0, toCell(target).1)
        let (cost, _) = dijkstra(tc)
        return cost.map { $0 * cell / MapConst.speedNorm }
    }

    /// 可达域掩码（seconds 秒内）
    public func reachableMask(from start: SIMD2<Double>, seconds: Double) -> [Bool] {
        let sc = snap(toCell(start).0, toCell(start).1)
        let (cost, _) = dijkstra(sc)
        let limit = MapConst.speedNorm * seconds
        return cost.map { $0.isFinite && $0 * cell <= limit }
    }
}

// MARK: - 最小堆

struct MinHeap {
    private var keys: [Double] = []
    private var vals: [Int] = []

    var isEmpty: Bool { keys.isEmpty }

    mutating func push(_ k: Double, _ v: Int) {
        keys.append(k); vals.append(v)
        var i = keys.count - 1
        while i > 0 {
            let p = (i - 1) / 2
            if keys[p] <= keys[i] { break }
            keys.swapAt(p, i); vals.swapAt(p, i)
            i = p
        }
    }

    mutating func pop() -> (Double, Int)? {
        guard !keys.isEmpty else { return nil }
        let rk = keys[0], rv = vals[0]
        let lk = keys.removeLast(), lv = vals.removeLast()
        if !keys.isEmpty {
            keys[0] = lk; vals[0] = lv
            var i = 0
            while true {
                let l = 2 * i + 1, r = 2 * i + 2
                var m = i
                if l < keys.count && keys[l] < keys[m] { m = l }
                if r < keys.count && keys[r] < keys[m] { m = r }
                if m == i { break }
                keys.swapAt(i, m); vals.swapAt(i, m)
                i = m
            }
        }
        return (rk, rv)
    }
}
