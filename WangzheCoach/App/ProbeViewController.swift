//
//  ProbeViewController.swift
//  最小验证 App —— 用于确认「全能签能否签出带扩展的包」+「localhost 能否通信」
//
//  这是**第一步**：不接算法，只验证架构成立性。
//  屏幕上显示一个每秒自增的数字（来自扩展的帧计数）。
//  数字会动 = 架构成立；不会动 = 立刻换方案，不要继续投入。
//

import UIKit

final class ProbeViewController: UIViewController {

    private var label: UILabel!
    private var timer: Timer?
    private var startCount = 0

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "架构验证"
        view.backgroundColor = .black

        label = UILabel()
        label.numberOfLines = 0
        label.textColor = .white
        label.font = .monospacedSystemFont(ofSize: 17, weight: .regular)
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)

        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 24),
            label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            label.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
        ])

        // 启动 localhost 服务端（验证通信路径）
        let serverOK = SharedStore.startServer(port: 8765)

        label.text = """
        架构验证工具

        localhost 服务端：\(serverOK ? "启动成功" : "启动失败")

        等待扩展数据…

        步骤：
        1. 打开控制中心 → 屏幕录制 → 长按 → 选本 App
        2. 看下面是否出现数字
        """

        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    private func refresh() {
        if let s = SharedStore.readState() {
            let age = Date().timeIntervalSince1970 - s.ts
            label.text = """
            架构验证工具

            ✅ 收到扩展数据
            时间戳：\(String(format: "%.2f", s.ts))
            数据年龄：\(String(format: "%.1f", age))s
            威胁值：\(String(format: "%.3f", s.threat))
            标记串：\(s.markers.isEmpty ? "(空)" : s.markers)

            通信路径：\(modeText())
            """

        }
    }

    /// 通信路径文字（三元不能嵌套在插值里，拆出来）
    private func modeText() -> String {
        switch SharedStore.mode {
        case .socket:
            return "localhost socket"
        case .appGroup:
            return "App Group"
        case .none:
            return "不可用"
        }
    }
}