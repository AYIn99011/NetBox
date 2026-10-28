import Foundation
import Network

// MARK: - PortScanner

/// TCP connect 端口扫描：NWConnection 并发分批探测，只回报开放端口。
enum PortScanner {

    // MARK: 预设端口组

    /// 常用端口集合
    static let commonPorts: [Int] = [
        21, 22, 23, 25, 53, 80, 110, 111, 135, 139, 143, 443, 445,
        465, 587, 993, 995, 1723, 3306, 3389, 5432, 5900, 6379,
        8000, 8080, 8443, 8888, 9090, 27017
    ]

    /// Web 相关端口
    static let webPorts: [Int] = [80, 443, 8000, 8080, 8443, 8888, 9090, 9443]

    /// 1–1024 全段
    static let top1024: [Int] = Array(1...1024)

    /// 常见服务名映射（开放端口展示用）
    static let serviceNames: [Int: String] = [
        21: "FTP", 22: "SSH", 23: "Telnet", 25: "SMTP", 53: "DNS",
        80: "HTTP", 110: "POP3", 111: "RPCbind", 135: "MS-RPC",
        139: "NetBIOS", 143: "IMAP", 443: "HTTPS", 445: "SMB",
        465: "SMTPS", 587: "SMTP-Submission", 993: "IMAPS", 995: "POP3S",
        1723: "PPTP", 3306: "MySQL", 3389: "RDP", 5432: "PostgreSQL",
        5900: "VNC", 6379: "Redis", 8000: "HTTP-Alt", 8080: "HTTP-Proxy",
        8443: "HTTPS-Alt", 8888: "HTTP-Alt", 9090: "Admin", 9443: "HTTPS-Alt",
        27017: "MongoDB"
    ]

    // MARK: 扫描

    /// - Returns: 开放端口（升序）
    static func scan(host: String,
                     ports: [Int],
                     concurrency: Int = 50,
                     timeoutSeconds: Double = 1.2,
                     emit: @escaping (String) -> Void) async -> [Int] {
        let validPorts = Array(Set(ports.filter { (1...65535).contains($0) })).sorted()
        guard !validPorts.isEmpty else {
            emit("没有有效的端口可扫描")
            return []
        }
        // 解析目标（契约：Common.swift 的 HostResolver）
        let resolvedIP = HostResolver.resolveIPv4(host) ?? HostResolver.resolve(host).first
        guard let targetIP = resolvedIP else {
            emit("无法解析主机：\(host)")
            return []
        }
        emit("目标 \(host)（\(targetIP)），共 \(validPorts.count) 个端口，并发 \(concurrency)")

        var openPorts: [Int] = []
        var completed = 0
        var lastProgressMark = 0

        // 分批：每批 concurrency 个连接同时跑，避免几千连接同时爆
        var index = 0
        while index < validPorts.count {
            if Task.isCancelled {
                emit("已取消（完成 \(completed)/\(validPorts.count)）")
                break
            }
            let batch = Array(validPorts[index..<min(index + concurrency, validPorts.count)])
            let batchResults = await withTaskGroup(of: (Int, Bool).self) { group in
                for port in batch {
                    group.addTask {
                        let open = await probe(host: targetIP, port: port, timeout: timeoutSeconds)
                        return (port, open)
                    }
                }
                var collected: [(Int, Bool)] = []
                for await r in group { collected.append(r) }
                return collected
            }
            for (port, open) in batchResults.sorted(by: { $0.0 < $1.0 }) where open {
                openPorts.append(port)
                if let svc = serviceNames[port] {
                    emit("端口 \(port) 开放（\(svc)）")
                } else {
                    emit("端口 \(port) 开放")
                }
            }
            completed += batch.count
            index += batch.count
            // 进度：每完成 200 个报一行，避免刷屏
            if completed - lastProgressMark >= 200 {
                lastProgressMark = completed
                emit("进度 \(completed)/\(validPorts.count)，已发现开放 \(openPorts.count) 个")
            }
        }

        openPorts.sort()
        emit("扫描完成：开放 \(openPorts.count) 个端口\(openPorts.isEmpty ? "" : "：" + openPorts.map(String.init).joined(separator: ", "))")
        return openPorts
    }

    // MARK: 单端口探测

    /// NWConnection 状态机：.ready = 开放；.failed = 关闭；超时未 ready 视为关闭/被过滤。
    private static func probe(host: String, port: Int, timeout: Double) async -> Bool {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else { return false }
        let connection = NWConnection(to: .hostPort(host: NWEndpoint.Host(host), port: nwPort), using: .tcp)
        let gate = ResumeGate()
        return await withCheckedContinuation { continuation in
            gate.install(continuation: continuation, connection: connection)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    gate.finish(true)
                case .failed:
                    gate.finish(false)
                default:
                    break // .waiting/.preparing 继续等超时判定
                }
            }
            connection.start(queue: .global(qos: .utility))
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                gate.finish(false)
            }
        }
    }

    /// 保证 continuation 只 resume 一次，并负责关连接。
    private final class ResumeGate: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Bool, Never>?
        private var connection: NWConnection?
        private var done = false

        func install(continuation: CheckedContinuation<Bool, Never>, connection: NWConnection) {
            lock.lock()
            self.continuation = continuation
            self.connection = connection
            lock.unlock()
        }

        func finish(_ value: Bool) {
            lock.lock()
            guard !done, let cont = continuation else { lock.unlock(); return }
            done = true
            continuation = nil
            let conn = connection
            connection = nil
            lock.unlock()
            conn?.cancel()
            cont.resume(returning: value)
        }
    }
}
