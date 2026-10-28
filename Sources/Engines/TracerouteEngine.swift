// TracerouteEngine.swift
// UDP 探测 + ICMP 错误回收的路由轨迹引擎（iOS 沙盒内方案）：
// - 发送端：普通 UDP socket，setsockopt(IP_TTL) 逐跳抬 TTL，目的端口从 33434 起逐探针递增做唯一标识。
// - 接收端：SOCK_DGRAM / IPPROTO_ICMP 的 ping 式 socket 收 ICMP Time Exceeded / Destination Unreachable。
//   响应方 IP 取 recvfrom 的来源地址（不依赖 IP 头是否随报文返回）；
//   报文内嵌的原始 IP 头 + UDP 头用来校验「目的 IP == 目标、目的端口 == 本跳探针」，防止串包误认。
// 这是 iOS 上已上架网络工具通用的 traceroute 路径（沙盒禁止 SOCK_RAW，只能走 dgram ICMP）。

import Foundation
import Darwin

/// 一跳的结果：samples 固定 3 个，nil 表示该探针超时
struct TraceHop {
    var ttl: Int
    var ip: String?
    var samplesMs: [Double?]
    var reachedTarget: Bool
}

enum TracerouteEngine {

    /// 探针目的端口基址（经典 traceroute 约定），逐探针 +1，整轮唯一
    private static let basePort: UInt16 = 33434
    /// 单个探针的等待超时（秒）
    private static let probeTimeoutSeconds: Double = 1.0

    /// 对 host 做路由轨迹，最多 maxHops 跳；每跳 3 个探针。
    /// - emit: 每完成一跳回调一行（引擎不切线程，调用方负责回主线程）
    /// - Returns: 已探测到的跳列表；解析失败返回空数组（原因已 emit）
    static func run(host: String,
                    maxHops: Int = 30,
                    emit: @escaping (String) -> Void) async -> [TraceHop] {
        if host.contains(":") {
            emit("traceroute: 暂不支持 IPv6 目标：\(host)")
            return []
        }
        guard let ip = HostResolver.resolveIPv4(host) else {
            emit("traceroute: 无法解析主机：\(host)")
            return []
        }
        guard let targetBytes = ipv4Bytes(ip) else {
            emit("traceroute: 目标地址非法：\(ip)")
            return []
        }

        let sendFD = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard sendFD >= 0 else {
            emit("traceroute: 创建 UDP socket 失败：\(String(cString: strerror(errno)))")
            return []
        }
        defer { close(sendFD) }
        let recvFD = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)
        guard recvFD >= 0 else {
            emit("traceroute: 创建 ICMP socket 失败：\(String(cString: strerror(errno)))")
            return []
        }
        defer { close(recvFD) }

        emit("traceroute to \(host) (\(ip))，最大 \(maxHops) 跳")

        let payload: [UInt8] = [0x4E, 0x54, 0x42, 0x58, // "NTBX"
                                0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
        var hops: [TraceHop] = []
        var recvBuffer = [UInt8](repeating: 0, count: 2048)

        hopLoop:
        for ttl in 1...maxHops {
            if Task.isCancelled { break }
            setTTL(fd: sendFD, ttl: ttl)

            var samples: [Double?] = [nil, nil, nil]
            var portToIdx: [UInt16: Int] = [:]
            var portSendNs: [UInt16: UInt64] = [:]
            var hopIP: String?
            var hopReached = false

            for probe in 0..<3 {
                if Task.isCancelled { break hopLoop }
                let port = basePort &+ UInt16((ttl - 1) * 3 + probe)
                portToIdx[port] = probe
                let dest = makeSockaddrIn(ip: ip, port: port)
                let sendNs = nowNs()
                guard sendPacket(fd: sendFD, bytes: payload, to: dest) >= 0 else { continue }
                portSendNs[port] = sendNs

                // 等当前探针的 ICMP 回应；同跳其他探针的迟到回应顺手一并收割进 samples
                let deadlineNs = sendNs &+ UInt64(probeTimeoutSeconds * 1_000_000_000)
                while samples[probe] == nil {
                    if Task.isCancelled { break hopLoop }
                    let now = nowNs()
                    if now >= deadlineNs { break }
                    let remainMs = Int((deadlineNs - now) / 1_000_000)
                    let sliceMs = Int32(max(1, min(100, remainMs)))
                    guard waitReadable(fd: recvFD, timeoutMs: sliceMs) else { continue }
                    let (n, srcIP) = recvPacket(fd: recvFD, buffer: &recvBuffer)
                    guard n > 0, let srcIP else { continue }
                    guard let info = parseICMPError(recvBuffer, length: n),
                          info.embeddedDstIP == targetBytes,
                          let idx = portToIdx[info.embeddedDstPort],
                          samples[idx] == nil,
                          let sentAt = portSendNs[info.embeddedDstPort] else { continue }
                    samples[idx] = Double(nowNs() &- sentAt) / 1_000_000
                    hopIP = srcIP
                    if info.type == 3 && info.code == 3 && srcIP == ip {
                        hopReached = true // port unreachable 且来源就是目标：到达
                    }
                }
            }

            let hop = TraceHop(ttl: ttl, ip: hopIP, samplesMs: samples, reachedTarget: hopReached)
            hops.append(hop)
            emit(formatHopLine(hop))
            if hopReached { break }
        }

        return hops
    }

    // MARK: - 报文解析

    private struct ICMPErrorInfo {
        var type: UInt8
        var code: UInt8
        var embeddedDstIP: [UInt8]
        var embeddedDstPort: UInt16
    }

    /// 解析 ICMP 差错报文：外层 type/code + 内嵌原始 IP 头 + 内嵌 UDP 头的目的端口。
    /// 兼容纯 ICMP 报文与带外层 IP 头的完整包两种形态（按首字节版本位与 protocol 字段嗅探偏移）。
    /// 内嵌偏移：ICMP 头 8 字节 → 原始 IP 头（ihl 可变长）→ 原始 UDP 头（目的端口在 +2 处）。
    /// 收入包不验校验和（内核已筛过一轮，校验对象是内嵌字段而非完整性）。
    private static func parseICMPError(_ buf: [UInt8], length: Int) -> ICMPErrorInfo? {
        var off = 0
        if length >= 20, (buf[0] >> 4) == 4, buf[9] == UInt8(IPPROTO_ICMP) {
            off = Int(buf[0] & 0x0F) * 4
            guard off >= 20 else { return nil }
        }
        guard length >= off + 8 + 20 + 4 else { return nil }
        let type = buf[off]
        let code = buf[off + 1]
        guard type == 11 || type == 3 else { return nil } // 只认 Time Exceeded / Destination Unreachable

        let emb = off + 8
        guard (buf[emb] >> 4) == 4 else { return nil }
        let ihl = Int(buf[emb] & 0x0F) * 4
        guard ihl >= 20, length >= emb + ihl + 4 else { return nil }
        guard buf[emb + 9] == UInt8(IPPROTO_UDP) else { return nil } // 内嵌原包必须是我们的 UDP 探针
        let dstIP = [buf[emb + 16], buf[emb + 17], buf[emb + 18], buf[emb + 19]]
        let udpOff = emb + ihl
        let dstPort = (UInt16(buf[udpOff + 2]) << 8) | UInt16(buf[udpOff + 3])
        return ICMPErrorInfo(type: type, code: code, embeddedDstIP: dstIP, embeddedDstPort: dstPort)
    }

    /// 一跳一行的展示格式，如「 1  192.168.1.1  1.2 ms  1.1 ms  1.3 ms」；全超时为「 2  * * *」
    private static func formatHopLine(_ hop: TraceHop) -> String {
        let ttlStr = String(format: "%2d", hop.ttl)
        if hop.ip == nil && hop.samplesMs.allSatisfy({ $0 == nil }) {
            return "\(ttlStr)  * * *"
        }
        var line = "\(ttlStr)  \(hop.ip ?? "*")"
        for sample in hop.samplesMs {
            if let ms = sample {
                line += "  \(String(format: "%.1f", ms)) ms"
            } else {
                line += "  *"
            }
        }
        return line
    }

    // MARK: - socket 小工具（文件内私有，避免与其他引擎重名冲突）

    private static func nowNs() -> UInt64 {
        var ts = timespec()
        clock_gettime(CLOCK_MONOTONIC, &ts)
        return UInt64(ts.tv_sec) &* 1_000_000_000 &+ UInt64(ts.tv_nsec)
    }

    private static func ipv4Bytes(_ ip: String) -> [UInt8]? {
        var addr = in_addr()
        guard inet_pton(AF_INET, ip, &addr) == 1 else { return nil }
        let raw = withUnsafeBytes(of: &addr) { Array($0) } // in_addr.s_addr 本就是网络字节序
        return raw.count == 4 ? raw : nil
    }

    private static func setTTL(fd: Int32, ttl: Int) {
        var value = Int32(ttl)
        setsockopt(fd, IPPROTO_IP, IP_TTL, &value, socklen_t(MemoryLayout<Int32>.size))
    }

    private static func makeSockaddrIn(ip: String, port: UInt16) -> sockaddr_in {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        inet_pton(AF_INET, ip, &addr.sin_addr)
        return addr
    }

    private static func sendPacket(fd: Int32, bytes: [UInt8], to addr: sockaddr_in) -> Int {
        var a = addr
        return bytes.withUnsafeBufferPointer { bufPtr in
            withUnsafePointer(to: &a) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    Darwin.sendto(fd, bufPtr.baseAddress, bufPtr.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    private static func recvPacket(fd: Int32, buffer: inout [UInt8]) -> (count: Int, srcIP: String?) {
        var src = sockaddr_in()
        var srcLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        let n = buffer.withUnsafeMutableBufferPointer { bufPtr in
            withUnsafeMutablePointer(to: &src) { ptr -> Int in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    Darwin.recvfrom(fd, bufPtr.baseAddress, bufPtr.count, 0, sa, &srcLen)
                }
            }
        }
        guard n > 0 else { return (n, nil) }
        var text = [CChar](repeating: 0, count: 46)
        inet_ntop(AF_INET, &src.sin_addr, &text, socklen_t(text.count))
        return (n, String(cString: text))
    }

    private static func waitReadable(fd: Int32, timeoutMs: Int32) -> Bool {
        var pfd = pollfd(fd: fd, events: Int16(0x0001), revents: 0) // POLLIN
        let r = Darwin.poll(&pfd, 1, timeoutMs)
        return r > 0 && (pfd.revents & Int16(0x0001) != 0 || pfd.revents & Int16(0x0008) != 0) // POLLIN | POLLERR
    }
}
