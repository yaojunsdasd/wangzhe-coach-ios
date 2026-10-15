//
//  MinimapParser.swift
//  共享层：小地图解析（HSV 阈值 + 连通域）
//
//  Python 版 minimap.py 的 Swift 移植。
//  用 Accelerate/vImage 做加速 —— 这是扩展内存受限时的关键。
//
//  ⚠️ HSV 阈值是模板值，需用真实截图校准。
//

import Foundation
import CoreGraphics
import simd

public struct HeroObservation {
    public let pos: SIMD2<Double>   // 归一化坐标
    public let area: Double         // 连通域面积占比
    public let side: String         // "ally" | "enemy"
}

public struct MinimapState {
    public var allies: [HeroObservation] = []
    public var enemies: [HeroObservation] = []
    public var ok: Bool = false
    public var note: String = ""
}

public final class MinimapParser {

    // HSV 阈值（H: 0-179, S/V: 0-255）
    // 红方（我方，发育路在下路）：色相 ~0-10 或 170-179
    // 蓝方：色相 ~100-130
    public var allyHueLow: UInt8 = 168
    public var allyHueHigh: UInt8 = 179
    public var enemyHueLow: UInt8 = 100
    public var enemyHueHigh: UInt8 = 130
    public var satMin: UInt8 = 90
    public var valMin: UInt8 = 110

    public var minAreaRatio: Double = 0.0006
    public var maxAreaRatio: Double = 0.02
    public var maxIcons: Int = 5
    public var sideFlip: Bool = false

    public init() {}

    /// 解析小地图区域。
    /// - Parameter pixelBuffer: BGRA 格式的原始像素
    public func parse(bgra: UnsafePointer<UInt8>, width: Int, height: Int,
                      bytesPerRow: Int) -> MinimapState {
        var st = MinimapState()
        guard width > 8, height > 8 else {
            st.note = "区域过小"; return st
        }

        // BGRA -> HSV（用 vImage 加速）
        guard let hsv = bgraToHSV(bgra: bgra, width: width, height: height,
                                  bytesPerRow: bytesPerRow) else {
            st.note = "色彩空间转换失败"; return st
        }
        defer { hsv.deallocate() }

        let total = Double(width * height)
        let allies = components(hsv: hsv, width: width, height: height,
                                hLow: allyHueLow, hHigh: allyHueHigh,
                                total: total, side: "ally")
        let enemies = components(hsv: hsv, width: width, height: height,
                                 hLow: enemyHueLow, hHigh: enemyHueHigh,
                                 total: total, side: "enemy")

        st.allies = Array(allies.sorted { $0.area > $1.area }.prefix(maxIcons))
        st.enemies = Array(enemies.sorted { $0.area > $1.area }.prefix(maxIcons))
        st.ok = true
        if st.allies.isEmpty && st.enemies.isEmpty {
            st.note = "未识别到色块，检查 crop 是否对准小地图"
        }
        return st
    }

    // MARK: - BGRA -> HSV

    /// BGRA -> HSV。
    ///
    /// **不用 vImage**：Accelerate 没有 RGB 转 HSV 的转换函数
    /// （只有 RGB<->YUV/CMYK 等，没有 HSV 目标格式），
    /// 硬用会编译失败。
    /// 手写反而更快 —— 省掉一次格式转换和内存拷贝，
    /// 而且能在同一次遍历里直接做阈值判断。
    ///
    /// 输出布局与输入一致（每像素 3 字节），只写 H/S/V 三通道。
    private func bgraToHSV(bgra: UnsafePointer<UInt8>, width: Int, height: Int,
                           bytesPerRow: Int) -> UnsafeMutablePointer<UInt8>? {
        let count = width * height
        guard count > 0 else { return nil }
        let hsv = UnsafeMutablePointer<UInt8>.allocate(capacity: count * 3)

        for y in 0..<height {
            let src = bgra + y * bytesPerRow
            let dst = hsv + y * width * 3
            for x in 0..<width {
                let b = Double(src[x * 4 + 0])
                let g = Double(src[x * 4 + 1])
                let r = Double(src[x * 4 + 2])

                let mx = max(r, g, b)
                let mn = min(r, g, b)
                let delta = mx - mn

                // V: 0-255
                let v = mx

                // S: 0-255
                var s: Double = 0
                if mx > 0 { s = delta / mx * 255.0 }

                // H: 0-179（OpenCV 约定，与 Python 版一致）
                var h: Double = 0
                if delta > 0 {
                    if mx == r {
                        h = 60.0 * (((g - b) / delta).truncatingRemainder(dividingBy: 6.0))
                    } else if mx == g {
                        h = 60.0 * (((b - r) / delta) + 2.0)
                    } else {
                        h = 60.0 * (((r - g) / delta) + 4.0)
                    }
                    if h < 0 { h += 360.0 }
                    h = h / 2.0        // 0-360 -> 0-179
                }

                dst[x * 3 + 0] = UInt8(max(0, min(179, h)))
                dst[x * 3 + 1] = UInt8(max(0, min(255, s)))
                dst[x * 3 + 2] = UInt8(max(0, min(255, v)))
            }
        }
        return hsv
    }

    // MARK: - 连通域

    private func components(hsv: UnsafePointer<UInt8>, width: Int, height: Int,
                            hLow: UInt8, hHigh: UInt8,
                            total: Double, side: String) -> [HeroObservation] {
        // 二值化
        var mask = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 3
                let h = hsv[i], s = hsv[i + 1], v = hsv[i + 2]
                if h >= hLow && h <= hHigh && s >= satMin && v >= valMin {
                    mask[y * width + x] = 1
                }
            }
        }

        // 连通域标记（迭代式 flood fill，避免递归爆栈）
        var labels = [Int](repeating: 0, count: width * height)
        var current = 0
        var results: [HeroObservation] = []
        var stack: [Int] = []

        for start in 0..<(width * height) {
            guard mask[start] == 1, labels[start] == 0 else { continue }
            current += 1
            stack.removeAll(keepingCapacity: true)
            stack.append(start)
            labels[start] = current
            var sumX = 0, sumY = 0, count = 0

            while let idx = stack.popLast() {
                let x = idx % width, y = idx / width
                sumX += x; sumY += y; count += 1
                // 8 邻域
                for dy in -1...1 {
                    for dx in -1...1 {
                        if dx == 0 && dy == 0 { continue }
                        let nx = x + dx, ny = y + dy
                        guard nx >= 0, ny >= 0, nx < width, ny < height else { continue }
                        let ni = ny * width + nx
                        if mask[ni] == 1 && labels[ni] == 0 {
                            labels[ni] = current
                            stack.append(ni)
                        }
                    }
                }
            }

            let areaRatio = Double(count) / total
            guard areaRatio >= minAreaRatio, areaRatio <= maxAreaRatio else { continue }
            var cx = Double(sumX) / Double(count) / Double(width)
            let cy = Double(sumY) / Double(count) / Double(height)
            if sideFlip { cx = 1.0 - cx }
            results.append(HeroObservation(pos: SIMD2(cx, cy),
                                           area: areaRatio, side: side))
        }
        return results
    }
}