//
//  SharedStore.swift
//  扩展 ↔ 主 App 通信 —— **socket 主路径**（面向全能签自签）
//
//  ## 为什么不用 App Groups
//
//  App Groups 必须在 Apple 开发者后台注册（Apple 文档原文：
//  "register the app group on the Apple Developer website"）。
//  全能签用的是别人的企业证书 + 固定通配 profile，
//  里面不可能有你注册的 group id → entitlement 对不上 → 签名失败。
//
//  ## 为什么 socket 可行
//
//  iOS 上 App 与自己的扩展**不需要任何 entitlement** 就能：
//    - 主 App bind 127.0.0.1:PORT  （监听）
//    - 扩展 connect 到该端口      （发送）
//  网络访问是默认能力，不涉及签名能力位。
//
//  ## 必须解决的隐患：主 App 被挂起
//
//  用户切到王者后，主 App 进后台。iOS 会在约 30 秒后挂起它，
//  socket 线程随之冻结 → 数据断流 → 提示失效。
//
//  解法：声明 UIBackgroundModes = audio，并持续播放静音音频。
//  这**本来也是 PiP 的前提条件**（AVPictureInPictureController 需要活跃音频会话），
//  所以一举两得：PiP 能起来 + App 不被挂起 + socket 持续可用。
//

import Foundation
import Darwin

public enum SharedStore {

    /// 通信端口。改这里要同步改扩展侧（同一常量）。
    public static let port: UInt16 = 8765

    public enum Mode: String {
        case socket = "socket"          // 主路径
        case appGroup = "appGroup"      // 若证书恰好支持
        case none = "none"
    }

    public private(set) static var mode: Mode = .none

    private static let lock = NSLock()
    private static var serverFD: Int32 = -1
    private static var clientFD: Int32 = -1
    private static var lastState: (ts: Double, threat: Double, markers: String)?
    private static var lastRecvAt: Date?

    /// 是否连上过扩展（用于诊断显示）
    public private(set) static var everConnected = false
    public private(set) static var recvCount = 0

    // MARK: - 启动（主 App 调用）

    /// 探测并启动通信。返回实际模式。
    @discardableResult
    public static func bootstrap() -> Mode {
        // 先试 App Group（如果证书支持，它更快）
        if let u = appGroupStateURL, writeFile(u, "probe") {
            mode = .appGroup
            log("bootstrap: appGroup 可用")
            return mode
        }
        // 主路径：socket
        if startServer() {
            mode = .socket
            log("bootstrap: socket 监听 \(port)")
            return mode
        }
        mode = .none
        log("bootstrap: 两条路都失败")
        return mode
    }

    // MARK: - socket 服务端

    @discardableResult
    public static func startServer(port overridePort: UInt16? = nil) -> Bool {
        if let p = overridePort { socketPort = p }
        if serverFD >= 0 { return true }

        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { log("socket() 失败"); return false }

        var yes: Int32 = 1
        Darwin.setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes,
                   socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)

        let bindOK = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindOK == 0 else {
            log("bind 失败 errno=\(Darwin.errno)（端口被占用？）")
            Darwin.close(fd); return false
        }
        guard Darwin.listen(fd, 8) == 0 else {
            log("listen 失败 errno=\(Darwin.errno)")
            Darwin.close(fd); return false
        }

        serverFD = fd
        Thread.detachNewThread { acceptLoop(fd) }
        return true
    }

    private static func acceptLoop(_ fd: Int32) {
        while true {
            var addr = sockaddr()
            var len = socklen_t(MemoryLayout<sockaddr>.size)
            let client = Darwin.accept(fd, &addr, &len)
            guard client >= 0 else {
                if errno == EINTR { continue }
                Thread.sleep(forTimeInterval: 0.2)
                continue
            }
            lock.lock(); clientFD = client; everConnected = true; lock.unlock()
            log("扩展已连接")
            recvLoop(client)
            lock.lock(); clientFD = -1; lock.unlock()
            log("扩展断开")
        }
    }

    /// 换行分隔的文本协议：ts|threat|markers\n
    private static func recvLoop(_ fd: Int32) {
        var pending = Data()
        var buf = [UInt8](repeating: 0, count: 16384)
        while true {
            let n = buf.withUnsafeMutableBytes { raw -> Int in
                Darwin.recv(fd, raw.baseAddress, raw.count, 0)
            }
            if n <= 0 { break }
            pending.append(contentsOf: buf[0..<n])
            // 按换行切分
            while let nl = pending.firstIndex(of: 0x0A) {
                let lineData = pending.subdata(in: pending.startIndex..<nl)
                pending.removeSubrange(pending.startIndex...nl)
                if let line = String(data: lineData, encoding: .utf8) {
                    parse(line)
                }
            }
        }
        Darwin.close(fd)
    }

    private static func parse(_ line: String) {
        let parts = line.split(separator: "|", maxSplits: 2,
                               omittingEmptySubsequences: false)
        guard parts.count >= 3,
              let ts = Double(parts[0]),
              let th = Double(parts[1]) else { return }
        lock.lock()
        lastState = (ts, th, String(parts[2]))
        lastRecvAt = Date()
        recvCount += 1
        lock.unlock()
    }

    // MARK: - 发送（扩展侧）

    /// 扩展每帧调用。内部自动重连。
    public static func send(ts: Double, threat: Double, markers: String) {
        let payload = String(format: "%.3f|%.4f|%@\n", ts, threat, markers)
        transmit(payload)
    }

    private static func transmit(_ payload: String) {
        if clientFD < 0 { connectToServer() }
        guard clientFD >= 0 else { return }
        let bytes = Array(payload.utf8)
        let n = bytes.withUnsafeBufferPointer { buf -> Int in
            guard let b = buf.baseAddress else { return -1 }
            return Darwin.send(clientFD, b, buf.count, 0)
        }
        if n <= 0 {
            Darwin.close(clientFD); clientFD = -1      // 下一帧自动重连
        }
    }

    private static func connectToServer() {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        // 关闭 Nagle：小包即时发送，降低延迟
        var one: Int32 = 1
        Darwin.setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one,
                   socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)

        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if r != 0 { Darwin.close(fd); return }
        clientFD = fd
    }

    // MARK: - 读取（主 App 侧）

    public static func readState() -> (ts: Double, threat: Double, markers: String)? {
        lock.lock()
        let s = lastState
        lock.unlock()
        return s
    }

    /// 数据新鲜度（秒）。nil 表示从没收到过。
    public static func dataAge() -> Double? {
        lock.lock()
        let t = lastRecvAt
        lock.unlock()
        guard let t = t else { return nil }
        return Date().timeIntervalSince(t)
    }

    public static func isConnected() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return clientFD >= 0
    }

    // MARK: - 日志

    private static var logURL: URL? {
        (appGroupContainer ?? FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask).first)?
            .appendingPathComponent("ghost_log.txt")
    }

    public static func log(_ msg: String) {
        let line = String(format: "[%.2f] %@\n",
                          Date().timeIntervalSince1970, msg)
        guard let url = logURL else { return }
        lock.lock(); defer { lock.unlock() }
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(line.data(using: .utf8) ?? Data())
            try? h.close()
        } else {
            try? line.write(to: url, atomically: false, encoding: .utf8)
        }
    }

    public static func readLog(maxLines: Int = 60) -> String {
        guard let url = logURL,
              let txt = try? String(contentsOf: url, encoding: .utf8) else {
            return "(无日志)"
        }
        return txt.split(separator: "\n").suffix(maxLines).joined(separator: "\n")
    }

    public static func reset() {
        if let u = logURL { try? FileManager.default.removeItem(at: u) }
        lock.lock(); recvCount = 0; everConnected = false; lastState = nil
        lock.unlock()
    }

    // MARK: - App Group（可选增强，证书支持时才生效）

    public static var appGroupID: String = "group.com.wangzhe.coach"

    private static var appGroupContainer: URL? {
        guard !appGroupID.isEmpty else { return nil }
        return FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID)
    }

    private static var appGroupStateURL: URL? {
        appGroupContainer?.appendingPathComponent("ghost_state.txt")
    }

    @discardableResult
    private static func writeFile(_ url: URL, _ text: String) -> Bool {
        do { try text.write(to: url, atomically: false, encoding: .utf8); return true }
        catch { return false }
    }
}