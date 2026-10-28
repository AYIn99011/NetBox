// Common.swift
// 主机名解析、ICMP 校验和、时间格式化等共用小工具

import Foundation
import Network
import CoreTelephony

/// 基于 getaddrinfo 的主机名解析
enum HostResolver {

    /// 解析出全部地址（IPv4 + IPv6），去重保序；失败返回空数组
    static func resolve(_ host: String) -> [String] {
        collectAddresses(host: host, family: AF_UNSPEC)
    }

    /// 解析出第一个 IPv4 地址；失败返回 nil
    static func resolveIPv4(_ host: String) -> String? {
        collectAddresses(host: host, family: AF_INET).first
    }

    private static func collectAddresses(host: String, family: Int32) -> [String] {
        // IP 字面量直接返回，避免无谓的 DNS 查询
        var literal = in_addr()
        if inet_pton(AF_INET, host, &literal) == 1 {
            return family == AF_INET6 ? [] : [host]
        }
        var literal6 = in6_addr()
        if inet_pton(AF_INET6, host, &literal6) == 1 {
            return family == AF_INET ? [] : [host]
        }

        var hints = addrinfo()
        hints.ai_family = family
        hints.ai_socktype = SOCK_STREAM

        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let head = result else {
            return []
        }
        defer { freeaddrinfo(head) }

        var addresses: [String] = []
        var node: UnsafeMutablePointer<addrinfo>? = head
        while let current = node {
            defer { node = current.pointee.ai_next }
            guard let sockaddr = current.pointee.ai_addr else { continue }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let status = getnameinfo(sockaddr, current.pointee.ai_addrlen,
                                     &buffer, socklen_t(buffer.count),
                                     nil, 0, NI_NUMERICHOST)
            if status == 0 {
                let text = String(cString: buffer)
                if !addresses.contains(text) {
                    addresses.append(text)
                }
            }
        }
        return addresses
    }
}

/// ICMP 报文校验和（RFC 1071）：16 位字求和取反
func icmpChecksum(_ data: [UInt8]) -> UInt16 {
    var sum: UInt32 = 0
    var index = 0
    while index + 1 < data.count {
        sum &+= (UInt32(data[index]) << 8) | UInt32(data[index + 1])
        index += 2
    }
    if index < data.count {
        sum &+= UInt32(data[index]) << 8
    }
    while (sum >> 16) != 0 {
        sum = (sum & 0xFFFF) + (sum >> 16)
    }
    return ~UInt16(sum & 0xFFFF)
}

/// 毫秒数格式化："18.3ms"
func formatMs(_ ms: Double) -> String {
    String(format: "%.1fms", ms)
}

/// 秒数（耗时）格式化："1.2s" / "350ms"
func formatDuration(_ seconds: Double) -> String {
    if seconds < 1 {
        return String(format: "%.0fms", seconds * 1000)
    }
    return String(format: "%.1fs", seconds)
}

/// 全 App 统一时间显示：yyyy-MM-dd HH:mm:ss，固定东八区，不随系统地区格式变样
private let dateTimeFormatter: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(secondsFromGMT: 8 * 3600)
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return f
}()

func formatDateTime(_ date: Date) -> String {
    dateTimeFormatter.string(from: date)
}

/// 当前网络状态：抓系统默认路径判断 WiFi/有线/蜂窝，蜂窝再分 5G/4G。
/// 注意：这反映的是系统默认路径，开着 TUN 代理时和实际出口可能对不上，只能当参考。
enum NetworkState {
    static func currentLabel() async -> String {
        guard let path = await probePath(), path.status == .satisfied else { return "未知" }
        if path.usesInterfaceType(.wifi) { return "WiFi" }
        if path.usesInterfaceType(.wiredEthernet) { return "有线" }
        if path.usesInterfaceType(.cellular) { return cellularLabel() }
        return "未知"
    }

    /// NWPathMonitor 拿一次当前路径就关；1.5 秒没回调就用 currentPath 兜底，保证不挂死
    private static func probePath() async -> NWPath? {
        await withCheckedContinuation { (cont: CheckedContinuation<NWPath?, Never>) in
            let monitor = NWPathMonitor()
            let gate = ResumeGate { p in cont.resume(returning: p) }
            monitor.pathUpdateHandler = { p in
                gate.fire(p)
                monitor.cancel()
            }
            monitor.start(queue: DispatchQueue(label: "netbox.pathprobe"))
            DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) {
                gate.fire(monitor.currentPath)
                monitor.cancel()
            }
        }
    }

    private static func cellularLabel() -> String {
        let info = CTTelephonyNetworkInfo()
        guard let tech = info.serviceCurrentRadioAccessTechnology?.values.first else { return "蜂窝" }
        if tech == CTRadioAccessTechnologyNR || tech == CTRadioAccessTechnologyNRNSA { return "5G" }
        if tech == CTRadioAccessTechnologyLTE { return "4G" }
        return "蜂窝"
    }
}

/// 只允许 resume 一次的小闸门（monitor 回调和超时兜底赛跑时用）
private final class ResumeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    private let body: (NWPath?) -> Void
    init(_ body: @escaping (NWPath?) -> Void) { self.body = body }
    func fire(_ path: NWPath?) {
        lock.lock(); defer { lock.unlock() }
        if fired { return }
        fired = true
        body(path)
    }
}
