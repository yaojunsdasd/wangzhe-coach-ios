//
//  SelfHeroLocator.swift
//  我方英雄定位 —— 从画面识别自己在小地图上的位置
//
//  为什么需要：可达域推断的**目标点**必须是"我方真实位置"，
//  写死 (0.62, 0.88) 会让所有概率算偏。
//
//  识别策略（按可靠性排序，可配置）：
//    1. 手动锚定：用户在小地图上点一次，之后靠跟踪维持（最可靠）
//    2. 白环标记：王者给自己英雄加了**独立标记**（多数皮肤如此）
//    3. 位置稳定法：友方图标中位移最小的那个（自己通常不频繁切屏）
//

import Foundation
import simd

public final class SelfHeroLocator {

    public enum Strategy: String {
        case manual      // 手动锚定 + 跟踪
        case ring        // 白环/亮圈标记
        case stability   // 位移最小
    }

    public var strategy: Strategy = .manual
    /// 手动锚定的初始位置（归一化）
    public var anchor: SIMD2<Double>?
    /// 跟踪时的最大允许位移（归一化/帧）
    public var maxStep: Double = 0.06

    private var last: SIMD2<Double>?

    /// 白色/亮色环的 HSV 阈值
    public var ringSatMax: UInt8 = 40      // 低饱和
    public var ringValMin: UInt8 = 220     // 高亮度

    public init() {}

    /// 手动锚定（用户点一下小地图）
    public func setAnchor(_ p: SIMD2<Double>) {
        anchor = p
        last = p
    }

    /// 更新并返回我方位置估计
    public func update(allyObs: [HeroObservation],
                       hsv: UnsafePointer<UInt8>?,
                       width: Int, height: Int) -> SIMD2<Double>? {

        switch strategy {
        case .manual:
            return trackManual(allyObs)
        case .ring:
            if let p = findRing(hsv: hsv, width: width, height: height) {
                last = p
                return p
            }
            return trackManual(allyObs)
        case .stability:
            return trackStability(allyObs)
        }
    }

    // MARK: 策略 1：手动锚定 + 最近邻跟踪

    private func trackManual(_ obs: [HeroObservation]) -> SIMD2<Double>? {
        guard let ref = last ?? anchor else { return nil }
        var best: SIMD2<Double>?
        var bestD = Double.greatestFiniteMagnitude
        for o in obs where o.side == "ally" {
            let d = simd_distance(o.pos, ref)
            if d < bestD && d <= maxStep * 6 {
                bestD = d; best = o.pos
            }
        }
        if let b = best { last = b; return b }
        return ref   // 没找到就保持上次位置
    }

    // MARK: 策略 2：找白色亮环

    private func findRing(hsv: UnsafePointer<UInt8>?, width: Int, height: Int) -> SIMD2<Double>? {
        guard let hsv = hsv, width > 8, height > 8 else { return nil }
        var sumX = 0, sumY = 0, count = 0
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 3
                let s = hsv[i + 1], v = hsv[i + 2]
                if s <= ringSatMax && v >= ringValMin {
                    sumX += x; sumY += y; count += 1
                }
            }
        }
        guard count >= 8 else { return nil }
        return SIMD2(Double(sumX) / Double(count) / Double(width),
                     Double(sumY) / Double(count) / Double(height))
    }

    // MARK: 策略 3：位移最小

    private func trackStability(_ obs: [HeroObservation]) -> SIMD2<Double>? {
        // 没有历史时无法判断，返回最靠近地图下路的友方图标
        // （发育路玩家开局在下路，这是个合理的先验）
        guard !obs.isEmpty else { return nil }
        if last == nil {
            let guess = obs.filter { $0.side == "ally" }
                .min { abs($0.pos.y - 0.88) < abs($1.pos.y - 0.88) }
            last = guess?.pos ?? obs.first?.pos
            return last
        }
        return trackManual(obs)
    }
}
