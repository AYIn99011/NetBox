// PingEngine.swift
// ICMP Echo 探测引擎：走 iOS ping socket（SOCK_DGRAM / IPPROTO_ICMP），沙盒内可用、无需特权。
// ping socket 的约定：内核改写 echo 的 identifier 并代为分发回包，收到的报文已剥掉 IP 头，
// 因此回包匹配不依赖 identifier，而用 payload 内嵌的 magic + seq 校验（自描述，防串包）。
// RTT 用 payload/本地记录的单调时钟发送时刻计算，不受系统时间调整影响。

import Foundation
import Darwin

/// 一次 Ping 运行的汇总；lines 为全部输出行（含统计块），与 emit 上报的内容一致
struct PingSummary {
    var sent: Int
    var received: Int
    var minMs: Double?
    var avgMs: Double?
    var maxMs: Double?
    var lossPercent: Double
    var resolvedIP: String
    var lines: [String]

    /// received > 0 时才有统计意义；字段顺序与 Models.PingStats 的成员wise init 对齐
    var stats: PingStats? {
        guard received > 0, let minMs, let avgMs, let maxMs else { return nil }
        return PingStats(minMs: minMs, avgMs: avgMs, maxMs: maxMs, lossPercent: lossPercent, sent: sent)
    }
}

enum PingEngine {

    /// payload 魔数 "NTBX"，回包先验魔数再认 seq，避免把别人的回包/迟到包算到当前 seq 上
    private static let magic: [UInt8] = [0x4E, 0x54, 0x42, 0x58]

    /// 对 host 连续 ping count 次。
    /// - host: 域名或 IPv4 字面量（IPv6 本期不支持，含 ":" 的字面量会直接报错返回 nil）
    /// - emit: 每产生一行输出即回调（引擎不切线程，调用方负责回主线程）
    /// - Returns: 汇总；解析失败/socket 创建失败等硬错误返回 nil（错误原因已 emit）
    static func run(host: String,
                    count: Int,
                    payloadSize: Int = 56,
                    timeoutSeconds: Double = 1.5,
                    intervalSeconds: Double = 1.0,
                    emit: @escaping (String) -> Void) async -> PingSummary? {
        // payload 钳制：下限 16（要装得下 magic+seq+时刻共 16 字节的内嵌头），
        // 上限 1472（1500 MTU 减 IP/ICMP 头，避免本机先分片）；+8 字节 ICMP 头即为线上包长
        let size = min(max(payloadSize, 16), 1472)
        var lines: [String] = []
        let out: (String) -> Void = { line in
            lines.append(line)
            emit(line)
        }

        if host.contains(":") {
            out("ping: 暂不支持 IPv6 目标：\(host)")
            return nil
        }
        guard count > 0 else {
            out("ping: 次数必须大于 0")
            return nil
        }
        guard let ip = HostResolver.resolveIPv4(host) else {
            out("ping: 无法解析主机：\(host)")
            return nil
        }

        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)
        guard fd >= 0 else {
            out("ping: 创建 ICMP socket 失败：\(String(cString: strerror(errno)))")
            return nil
        }
        defer { close(fd) }

        let dest = makeSockaddrIn(ip: ip, port: 0)

        var sent = 0
        var received = 0
        var rtts: [Double] = []
        var recvBuffer = [UInt8](repeating: 0, count: 2048)

        out("PING \(host) (\(ip))：\(size) data bytes")

        for seq in 1...count {
            if Task.isCancelled { break }
            let packet = buildEchoRequest(seq: seq, sendNs: nowNs(), payloadSize: size)
            let sendNs = nowNs()
            guard sendPacket(fd: fd, bytes: packet, to: dest) >= 0 else {
                out("ping: 发送失败：\(String(cString: strerror(errno)))")
                continue
            }
            sent += 1

            // 等本 seq 的回包：100ms 粒度 poll 轮询，保证取消能及时生效；
            // 迟到的旧 seq 回包会被 parse 认出并丢弃，继续等当前 seq 直到 deadline。
            let deadlineNs = sendNs &+ UInt64(timeoutSeconds * 1_000_000_000)
            var got = false
            while !got {
                if Task.isCancelled { break }
                let now = nowNs()
                if now >= deadlineNs { break }
                let remainMs = Int((deadlineNs - now) / 1_000_000)
                let sliceMs = Int32(max(1, min(100, remainMs)))
                guard waitReadable(fd: fd, timeoutMs: sliceMs) else { continue }
                let (n, srcIP) = recvPacket(fd: fd, buffer: &recvBuffer)
                guard n > 0 else { continue }
                guard let replySeq = parseEchoReplySeq(recvBuffer, length: n), replySeq == seq else { continue }
                let rttMs = Double(nowNs() &- sendNs) / 1_000_000
                received += 1
                rtts.append(rttMs)
                got = true
                out("\(8 + size) bytes from \(srcIP ?? ip): icmp_seq=\(seq) time=\(String(format: "%.1f", rttMs)) ms")
            }
            if !got && !Task.isCancelled {
                out("Request timeout for icmp_seq \(seq)")
            }

            // 包间隔：以发送时刻为基准扣除本轮已耗时；取消感知的小步睡眠
            if seq < count && !Task.isCancelled {
                let elapsed = Double(nowNs() &- sendNs) / 1_000_000_000
                let wait = intervalSeconds - elapsed
                if wait > 0 {
                    await cancellableSleep(seconds: wait)
                }
            }
        }

        let lossPercent = sent > 0 ? Double(sent - received) / Double(sent) * 100 : 0
        out("--- \(host) ping 统计 ---")
        out("\(sent) 个已发送，\(received) 个已接收，\(String(format: "%.1f", lossPercent))% 丢包")
        var minMs: Double?
        var avgMs: Double?
        var maxMs: Double?
        if !rtts.isEmpty {
            let lo = rtts.min()!
            let hi = rtts.max()!
            let avg = rtts.reduce(0, +) / Double(rtts.count)
            minMs = lo; avgMs = avg; maxMs = hi
            out("往返时间 最低 = \(String(format: "%.1f", lo)) ms，平均 = \(String(format: "%.1f", avg)) ms，最高 = \(String(format: "%.1f", hi)) ms")
        }

        return PingSummary(sent: sent,
                           received: received,
                           minMs: minMs,
                           avgMs: avgMs,
                           maxMs: maxMs,
                           lossPercent: lossPercent,
                           resolvedIP: ip,
                           lines: lines)
    }

    // MARK: - 报文构造与解析

    /// 组 echo request：type 8 / code 0 / id（内核会改写，填 pid 低 16 位）/ seq，
    /// payload = magic(4) + seq BE(2) + 保留(2) + 发送单调时刻 BE(8) + 填充字母
    private static func buildEchoRequest(seq: Int, sendNs: UInt64, payloadSize: Int) -> [UInt8] {
        var pkt = [UInt8](repeating: 0, count: 8 + payloadSize)
        pkt[0] = 8 // ICMP echo request
        pkt[1] = 0
        putBE16(UInt16(getpid() & 0xFFFF), into: &pkt, at: 4)
        putBE16(UInt16(seq & 0xFFFF), into: &pkt, at: 6)
        let p = 8
        pkt.replaceSubrange(p..<(p + 4), with: magic)
        putBE16(UInt16(seq & 0xFFFF), into: &pkt, at: p + 4)
        putBE64(sendNs, into: &pkt, at: p + 8)
        for i in (p + 16)..<(8 + payloadSize) {
            pkt[i] = UInt8((i - p - 16) % 26) &+ 97 // 'a'...'z' 循环填充
        }
        putBE16(icmpChecksum(pkt), into: &pkt, at: 2)
        return pkt
    }

    /// 解析 echo reply 并返回其内嵌 seq；不是本引擎的回包返回 nil。
    /// 兼容两种收包形态：纯 ICMP 报文（ping socket 正常形态）与带 IP 头的完整包（防御式嗅探）。
    private static func parseEchoReplySeq(_ buf: [UInt8], length: Int) -> Int? {
        var off = 0
        if length >= 20, (buf[0] >> 4) == 4, buf[9] == UInt8(IPPROTO_ICMP) {
            off = Int(buf[0] & 0x0F) * 4
            guard off >= 20 else { return nil }
        }
        guard length >= off + 8 + 16 else { return nil }
        guard buf[off] == 0 else { return nil } // type 0 = echo reply
        let p = off + 8
        guard buf[p] == magic[0], buf[p + 1] == magic[1], buf[p + 2] == magic[2], buf[p + 3] == magic[3] else {
            return nil
        }
        return Int(getBE16(buf, at: p + 4))
    }

    // MARK: - socket 小工具（文件内私有，避免与其他引擎重名冲突）

    private static func nowNs() -> UInt64 {
        var ts = timespec()
        clock_gettime(CLOCK_MONOTONIC, &ts)
        return UInt64(ts.tv_sec) &* 1_000_000_000 &+ UInt64(ts.tv_nsec)
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

    /// 收一包并带回来源 IP（recvfrom 的 from 地址，不依赖 IP 头是否存在）
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

    private static func cancellableSleep(seconds: Double) async {
        var remaining = seconds
        while remaining > 0 {
            if Task.isCancelled { return }
            let step = min(remaining, 0.05)
            try? await Task.sleep(nanoseconds: UInt64(step * 1_000_000_000))
            remaining -= step
        }
    }

    private static func putBE16(_ v: UInt16, into buf: inout [UInt8], at off: Int) {
        buf[off] = UInt8(v >> 8)
        buf[off + 1] = UInt8(v & 0xFF)
    }

    private static func putBE64(_ v: UInt64, into buf: inout [UInt8], at off: Int) {
        for i in 0..<8 {
            buf[off + i] = UInt8((v >> UInt64(56 - 8 * i)) & 0xFF)
        }
    }

    private static func getBE16(_ buf: [UInt8], at off: Int) -> UInt16 {
        (UInt16(buf[off]) << 8) | UInt16(buf[off + 1])
    }
}
