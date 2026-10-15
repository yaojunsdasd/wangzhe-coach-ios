//
//  AppDelegate.swift + MainViewController.swift
//  主 App —— 全能签自签版
//
//  启动顺序（每一步都影响成败）：
//    1. 启动后台保活（静音音频）—— 否则切到游戏后会被挂起
//    2. 启动 socket 监听        —— 接收扩展数据
//    3. 启动 PiP 悬浮层          —— 显示提示
//    4. 提供广播启动入口
//

import UIKit
import ReplayKit
import AVKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        let w = UIWindow(frame: UIScreen.main.bounds)
        w.rootViewController = UINavigationController(rootViewController: MainViewController())
        w.makeKeyAndVisible()
        self.window = w
        return true
    }
}

final class MainViewController: UIViewController {

    /// 全局只初始化一次。viewDidLoad 可能被重复调用
    /// （从 App 切换器返回等），重复 bind 端口会出问题。
    private static var bootstrapped = false

    private let pip = PiPOverlay()
    private var statusLabel: UILabel!
    private var logView: UITextView!
    private var pipButton: UIButton!
    private var refreshTimer: Timer?

    private var bootstrapMode: SharedStore.Mode = .none

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "发育路助手"
        view.backgroundColor = .systemBackground

        // ---- 1. 后台保活（最先启动，它决定后面能不能用）----
        let kept = BackgroundKeeper.shared.start()

        // ---- 2. socket 监听（只做一次）----
        if !MainViewController.bootstrapped {
            MainViewController.bootstrapped = true
            bootstrapMode = SharedStore.bootstrap()
        } else {
            bootstrapMode = SharedStore.mode
        }

        buildUI(keepAliveOK: kept)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // ---- 3. PiP 需要 view 已上屏 ----
        startPiPIfNeeded()
    }

    private var pipStarted = false
    private func startPiPIfNeeded() {
        guard !pipStarted else { return }
        pip.start(in: view)
        pipStarted = true
        pipButton?.setTitle("停止悬浮提示", for: .normal)
        pipButton?.backgroundColor = .systemRed
    }

    // MARK: - UI

    private func buildUI(keepAliveOK: Bool) {
        statusLabel = UILabel()
        statusLabel.numberOfLines = 0
        statusLabel.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(statusLabel)

        pipButton = UIButton(type: .system)
        pipButton.setTitle("启动悬浮提示", for: .normal)
        pipButton.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
        pipButton.backgroundColor = .systemBlue
        pipButton.setTitleColor(.white, for: .normal)
        pipButton.layer.cornerRadius = 10
        pipButton.translatesAutoresizingMaskIntoConstraints = false
        pipButton.addTarget(self, action: #selector(togglePiP), for: .touchUpInside)
        view.addSubview(pipButton)

        // ReplayKit 系统选择器 —— 全能签场景下这是启动广播的唯一入口
        let picker = RPSystemBroadcastPickerView(
            frame: CGRect(x: 0, y: 0, width: 260, height: 60))
        picker.preferredExtension = "com.wangzhe.coach.BroadcastExtension"
        picker.showsMicrophoneButton = false
        picker.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(picker)

        logView = UITextView()
        logView.isEditable = false
        logView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        logView.backgroundColor = .secondarySystemBackground
        logView.layer.cornerRadius = 8
        logView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(logView)

        NSLayoutConstraint.activate([
            statusLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),

            pipButton.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 12),
            pipButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            pipButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            pipButton.heightAnchor.constraint(equalToConstant: 46),

            picker.topAnchor.constraint(equalTo: pipButton.bottomAnchor, constant: 10),
            picker.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            picker.widthAnchor.constraint(equalToConstant: 260),
            picker.heightAnchor.constraint(equalToConstant: 56),

            logView.topAnchor.constraint(equalTo: picker.bottomAnchor, constant: 10),
            logView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            logView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            logView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),
        ])

        refreshTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.refresh(keepAliveOK: keepAliveOK)
        }
        refresh(keepAliveOK: keepAliveOK)
    }

    @objc private func togglePiP() {
        if pipStarted {
            pip.stop(); pipStarted = false
            pipButton.setTitle("启动悬浮提示", for: .normal)
            pipButton.backgroundColor = .systemBlue
        } else {
            startPiPIfNeeded()
        }
    }

    // MARK: - 状态刷新（这是诊断的关键）

    private func refresh(keepAliveOK: Bool) {
        var lines: [String] = []

        // 保活状态 —— 最重要的诊断项
        let keep = BackgroundKeeper.shared.active
        lines.append(keep ? "✅ 保活：运行中" : "❌ 保活：未启动（切到游戏后会断流）")

        // 通信模式
        switch bootstrapMode {
        case .socket:   lines.append("✅ 通信：socket :\(SharedStore.port)")
        case .appGroup: lines.append("✅ 通信：App Group")
        case .none:     lines.append("❌ 通信：不可用")
        }

        // 连接状态
        lines.append(SharedStore.isConnected() ? "✅ 扩展：已连接" : "⏳ 扩展：等待连接")

        // 数据新鲜度
        if let age = SharedStore.dataAge() {
            let mark = age < 2 ? "✅" : (age < 10 ? "⚠️" : "❌")
            lines.append("\(mark) 数据：\(String(format: "%.1f", age))s 前  (共 \(SharedStore.recvCount) 帧)")
        } else {
            lines.append("⏳ 数据：尚未收到")
        }

        if let s = SharedStore.readState() {
            lines.append("   威胁：\(String(format: "%.0f%%", s.threat * 100))")
            lines.append("   标记：\(s.markers.isEmpty ? "(无)" : String(s.markers.prefix(40)))")
        }

        lines.append("")
        lines.append("使用步骤：")
        lines.append("1. 点下方按钮 → 选本 App 开始广播")
        lines.append("2. 切到王者荣耀")
        lines.append("3. PiP 悬浮窗会显示预警")

        statusLabel.text = lines.joined(separator: "\n")
        logView.text = SharedStore.readLog(maxLines: 25)
        logView.scrollRangeToVisible(NSRange(location: logView.text.count - 1, length: 0))
    }
}