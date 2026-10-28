import Foundation
import Network

// MARK: - 结果模型

struct LANDevice {
    let ip: String
    var hostname: String?
    var services: [String]
    var isGateway: Bool
}

// MARK: - LANScanner

/// 局域网扫描：取 en0 网段 → ICMP ping sweep 找存活 → 反查主机名 → Bonjour 服务发现。
/// iOS 限制：读不到 ARP 表、拿不到其他设备 MAC，本实现不做 MAC/厂商识别（系统铁墙）。
/// 默认网关没有低成本可靠读法（要解析 sysctl 路由表），这里把网段 .1 标为网关候选（isGateway）。
enum LANScanner {

    private static let bonjourTypes: [(type: String, label: String)] = [
        ("_http._tcp", "HTTP"),
        ("_ssh._tcp", "SSH"),
        ("_smb._tcp", "SMB"),
        ("_airplay._tcp", "AirPlay"),
        ("_raop._tcp", "AirPlay 音频"),
        ("_ipp._tcp", "打印")
    ]

    static func scan(emit: @escaping (String) -> Void) async -> [LANDevice] {
        guard let (localIP, mask) = wifiIPv4() else {
            emit("未获取到 WiFi IPv4 地址（en0），请确认已连 WiFi")
            return []
        }
        let ipInt = ipv4ToInt(localIP)
        let maskInt = ipv4ToInt(mask)
        let prefix = maskInt.nonzeroBitCount

        let hosts: [UInt32]
        if prefix < 16 {
            // 网段大于 /16：只扫本机所在 /24，避免几万地址扫到天荒地老
            let base = ipInt & 0xFFFF_FF00
            hosts = Array((base + 1)...(base + 254))
            emit("网段过大（/\(prefix)），只扫本机所在 /24：\(intToIPv4(base))/24")
        } else {
            let network = ipInt & maskInt
            let broadcast = network | ~maskInt
            hosts = Array((network + 1)..<broadcast)
            emit("扫描网段 \(intToIPv4(network))/\(prefix)，共 \(hosts.count) 个地址")
        }
        emit("本机地址：\(localIP)")

        let gatewayCandidate = (hosts.first ?? 0) // 网段第一个地址（通常 .1）

        // 并发 ping sweep：分块发送 + 收回复，按源 IP 匹配存活
        var devices: [LANDevice] = []
        let chunkSize = 256
        var index = 0
        var chunkNumber = 0
        while index < hosts.count {
            if Task.isCancelled {
                emit("已取消")
                break
            }
            let chunk = Array(hosts[index..<min(index + chunkSize, hosts.count)])
            let aliveInts = batchPing(chunk.map(intToIPv4))
            // 反查主机名并发做（本地 PTR 通常很快；慢 DNS 是已知风险点）
            let chunkDevices = await withTaskGroup(of: LANDevice.self) { group in
                for value in aliveInts {
                    let ip = intToIPv4(value)
                    group.addTask {
                        LANDevice(ip: ip,
                                  hostname: reverseHostname(ip),
                                  services: [],
                                  isGateway: value == gatewayCandidate)
                    }
                }
                var list: [LANDevice] = []
                for await d in group { list.append(d) }
                return list
            }
            for device in chunkDevices.sorted(by: { ipv4ToInt($0.ip) < ipv4ToInt($1.ip) }) {
                devices.append(device)
                var line = "发现 \(device.ip)"
                if let h = device.hostname { line += "（\(h)）" }
                if device.isGateway { line += "［网关候选］" }
                emit(line)
            }
            index += chunk.count
            chunkNumber += 1
            if chunkNumber % 16 == 0 {
                emit("进度：已扫 \(index)/\(hosts.count)，存活 \(devices.count)")
            }
        }

        // Bonjour 服务发现（与 sweep 结果尽力按实例名≈主机名匹配，匹配不上单独 emit 汇总）
        if !Task.isCancelled {
            let found = await discoverBonjour(seconds: 3)
            var totalServices = 0
            for (type, label) in bonjourTypes {
                guard let names = found[type], !names.isEmpty else { continue }
                totalServices += names.count
                // 尽力匹配：实例名与设备主机名（或其首段）不分大小写相等
                for i in devices.indices {
                    guard let host = devices[i].hostname?.lowercased() else { continue }
                    let short = host.split(separator: ".").first.map(String.init) ?? host
                    if names.contains(where: { $0.lowercased() == host || $0.lowercased() == short }) {
                        if !devices[i].services.contains(label) { devices[i].services.append(label) }
                    }
                }
                let sample = names.sorted().prefix(5).joined(separator: "、")
                emit("Bonjour 发现 \(type)：\(names.count) 个（\(sample)\(names.count > 5 ? "…" : "")）")
            }
            if totalServices == 0 {
                emit("Bonjour 未发现常见服务")
            }
        }

        devices.sort { ipv4ToInt($0.ip) < ipv4ToInt($1.ip) }
        emit("扫描完成：存活设备 \(devices.count) 台")
        return devices
    }

    // MARK: - en0 地址

    private static func wifiIPv4() -> (ip: String, mask: String)? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            let entry = current.pointee
            cursor = entry.ifa_next
            guard let addrPtr = entry.ifa_addr,
                  addrPtr.pointee.sa_family == sa_family_t(AF_INET),
                  String(cString: entry.ifa_name) == "en0",
                  let maskPtr = entry.ifa_netmask else { continue }
            let ip = ipv4String(from: addrPtr)
            let mask = ipv4String(from: maskPtr)
            if let ip, let mask { return (ip, mask) }
        }
        return nil
    }

    private static func ipv4String(from sockaddrPtr: UnsafeMutablePointer<sockaddr>) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        let ok = sockaddrPtr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { sin in
            var addr = sin.pointee.sin_addr
            return inet_ntop(AF_INET, &addr, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil
        }
        return ok ? String(cString: buffer) : nil
    }

    private static func ipv4ToInt(_ s: String) -> UInt32 {
        var addr = in_addr()
        guard inet_pton(AF_INET, s, &addr) == 1 else { return 0 }
        return UInt32(bigEndian: addr.s_addr)
    }

    private static func intToIPv4(_ v: UInt32) -> String {
        "\((v >> 24) & 0xFF).\((v >> 16) & 0xFF).\((v >> 8) & 0xFF).\(v & 0xFF)"
    }

    // MARK: - 批量 Ping（本文件内轻量实现，不依赖 PingEngine 对外 API）

    /// 对一批地址各发一个 ICMP echo，短窗口内按回复源 IP 收集存活集合。
    private static func batchPing(_ addresses: [String], timeoutMs: Int32 = 400) -> Set<UInt32> {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)
        guard fd >= 0 else { return [] }
        defer { close(fd) }

        // 组包：echo request，identifier 交由内核 ping socket 分配/修正，seq 用下标
        for (i, ip) in addresses.enumerated() {
            var dest = sockaddr_in()
            dest.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            dest.sin_family = sa_family_t(AF_INET)
            dest.sin_port = 0
            inet_pton(AF_INET, ip, &dest.sin_addr)
            let packet = icmpEchoPacket(identifier: 0x4E54, sequence: UInt16(truncatingIfNeeded: i))
            _ = packet.withUnsafeBufferPointer { buf in
                withUnsafePointer(to: &dest) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                        sendto(fd, buf.baseAddress, buf.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
        }

        var alive = Set<UInt32>()
        let expected = Set(addresses.map(ipv4ToInt))
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
        var buffer = [UInt8](repeating: 0, count: 2048)
        while Date() < deadline, alive.count < expected.count {
            if Task.isCancelled { break }
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pfd, 1, 50)
            if ready < 0 {
                if errno == EINTR { continue }
                break
            }
            guard ready > 0, (pfd.revents & Int16(POLLIN)) != 0 else { continue }
            var from = sockaddr_in()
            var fromLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to: &from) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    recvfrom(fd, &buffer, buffer.count, 0, sa, &fromLen)
                }
            }
            guard n > 0 else { continue }
            let source = UInt32(bigEndian: from.sin_addr.s_addr)
            if expected.contains(source) { alive.insert(source) }
        }
        return alive
    }

    private static func icmpEchoPacket(identifier: UInt16, sequence: UInt16) -> [UInt8] {
        // 8 字节 ICMP 头 + 8 字节载荷
        var packet = [UInt8](repeating: 0, count: 16)
        packet[0] = 8 // echo request
        packet[1] = 0
        packet[4] = UInt8(identifier >> 8)
        packet[5] = UInt8(identifier & 0xFF)
        packet[6] = UInt8(sequence >> 8)
        packet[7] = UInt8(sequence & 0xFF)
        for i in 8..<16 { packet[i] = UInt8(i) }
        let checksum = icmpChecksum(packet)
        packet[2] = UInt8(checksum >> 8)
        packet[3] = UInt8(checksum & 0xFF)
        return packet
    }

    // 校验和复用 Common.swift 的全局 icmpChecksum(_:)，不重复实现

    // MARK: - 主机名反查

    private static func reverseHostname(_ ip: String) -> String? {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        inet_pton(AF_INET, ip, &addr.sin_addr)
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let rc = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                getnameinfo(sa, socklen_t(MemoryLayout<sockaddr_in>.size),
                            &host, socklen_t(host.count), nil, 0, NI_NAMEREQD)
            }
        }
        guard rc == 0 else { return nil }
        let name = String(cString: host)
        return (name.isEmpty || name == ip) ? nil : name
    }

    // MARK: - Bonjour

    private static func discoverBonjour(seconds: Double) async -> [String: Set<String>] {
        let collector = BonjourCollector()
        collector.start(types: bonjourTypes.map { $0.type })
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        collector.stop()
        return collector.snapshot()
    }

    /// 并发浏览多个 Bonjour 类型的收集器（结果回调在浏览器队列上，用锁保护）。
    private final class BonjourCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var browsers: [NWBrowser] = []
        private var found: [String: Set<String>] = [:]

        func start(types: [String]) {
            for type in types {
                let browser = NWBrowser(for: .bonjour(type: type, domain: nil), using: NWParameters())
                browser.browseResultsChangedHandler = { [weak self] results, _ in
                    guard let self else { return }
                    var names = Set<String>()
                    for result in results {
                        if case .service(let name, _, _, _) = result.endpoint {
                            names.insert(name)
                        }
                    }
                    self.lock.lock()
                    self.found[type] = names
                    self.lock.unlock()
                }
                browser.start(queue: .global(qos: .utility))
                lock.lock()
                browsers.append(browser)
                lock.unlock()
            }
        }

        func stop() {
            lock.lock()
            let all = browsers
            browsers.removeAll()
            lock.unlock()
            all.forEach { $0.cancel() }
        }

        func snapshot() -> [String: Set<String>] {
            lock.lock()
            defer { lock.unlock() }
            return found
        }
    }
}
