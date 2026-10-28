import Foundation

// MARK: - DNS 记录类型

enum DNSRecordType: String, CaseIterable {
    case A, AAAA, CNAME, MX, TXT, NS, SOA

    /// DNS wire format 中的 QTYPE 码
    var wireCode: UInt16 {
        switch self {
        case .A: return 1
        case .NS: return 2
        case .CNAME: return 5
        case .SOA: return 6
        case .MX: return 15
        case .TXT: return 16
        case .AAAA: return 28
        }
    }

    static func name(forWireCode code: UInt16) -> String {
        for t in allCases where t.wireCode == code { return t.rawValue }
        return "TYPE\(code)"
    }
}

// MARK: - 结果模型

struct DNSAnswer {
    let name: String
    let type: String
    let ttl: UInt32
    let data: String
}

struct DNSResult {
    let answers: [DNSAnswer]
    let serverUsed: String
    let lines: [String]
}

// MARK: - DNSClient

/// 自拼 DNS wire 报文、直查指定解析器的客户端。
/// - server 只支持 IPv4 字面量（如 223.5.5.5），预置解析器均为 IPv4；IPv6 解析器暂不支持。
/// - 域名按 UTF-8 标签直接编码，不做 punycode 转换（中文域名请传已转好的 xn-- 形式）。
enum DNSClient {

    static func query(name: String, server: String, type: DNSRecordType) async -> DNSResult {
        var lines: [String] = []

        // 校验 server 为 IPv4 字面量
        var serverAddr = in_addr()
        guard inet_pton(AF_INET, server, &serverAddr) == 1 else {
            lines.append("解析器地址无效（仅支持 IPv4 字面量）：\(server)")
            return DNSResult(answers: [], serverUsed: server, lines: lines)
        }

        let packet = buildQuery(name: name, type: type)
        let queryID = UInt16(packet[0]) << 8 | UInt16(packet[1])
        lines.append("向 \(server) 查询 \(name) 的 \(type.rawValue) 记录…")

        guard let response = exchange(packet: packet, server: server, serverAddr: serverAddr) else {
            if Task.isCancelled {
                lines.append("已取消")
            } else {
                lines.append("查询超时（5 秒无响应）")
            }
            return DNSResult(answers: [], serverUsed: server, lines: lines)
        }

        let answers = parse(response: response, queryID: queryID, type: type, lines: &lines)
        return DNSResult(answers: answers, serverUsed: server, lines: lines)
    }

    // MARK: 报文构建

    private static func buildQuery(name: String, type: DNSRecordType) -> [UInt8] {
        var packet: [UInt8] = []
        let id = UInt16.random(in: 0...UInt16.max)
        // Header: id, flags=0x0100 (RD=1), QDCOUNT=1, 其余 0
        packet += [UInt8(id >> 8), UInt8(id & 0xFF)]
        packet += [0x01, 0x00]
        packet += [0x00, 0x01]
        packet += [0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
        // QNAME：标签序列（UTF-8 字节，长度截到 63）
        let trimmed = name.hasSuffix(".") ? String(name.dropLast()) : name
        for label in trimmed.split(separator: ".", omittingEmptySubsequences: true) {
            let bytes = Array(label.utf8.prefix(63))
            packet.append(UInt8(bytes.count))
            packet += bytes
        }
        packet.append(0)
        // QTYPE + QCLASS(IN=1)
        packet += [UInt8(type.wireCode >> 8), UInt8(type.wireCode & 0xFF)]
        packet += [0x00, 0x01]
        return packet
    }

    // MARK: UDP 收发（poll 轮询，5 秒超时，支持取消）

    private static func exchange(packet: [UInt8], server: String, serverAddr: in_addr) -> [UInt8]? {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var dest = sockaddr_in()
        dest.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        dest.sin_family = sa_family_t(AF_INET)
        dest.sin_port = in_port_t(53).bigEndian
        dest.sin_addr = serverAddr

        let sent = packet.withUnsafeBufferPointer { buf -> Int in
            withUnsafePointer(to: &dest) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    sendto(fd, buf.baseAddress, buf.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        guard sent == packet.count else { return nil }

        let deadline = Date().addingTimeInterval(5)
        var buffer = [UInt8](repeating: 0, count: 65535)
        while Date() < deadline {
            if Task.isCancelled { return nil }
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pfd, 1, 100)
            if ready < 0 {
                if errno == EINTR { continue }
                return nil
            }
            guard ready > 0, (pfd.revents & Int16(POLLIN)) != 0 else { continue }
            let n = recvfrom(fd, &buffer, buffer.count, 0, nil, nil)
            if n > 0 { return Array(buffer[0..<n]) }
        }
        return nil
    }

    // MARK: 响应解析

    private static func parse(response: [UInt8], queryID: UInt16, type: DNSRecordType, lines: inout [String]) -> [DNSAnswer] {
        guard response.count >= 12 else {
            lines.append("响应过短（\(response.count) 字节），无法解析")
            return []
        }
        let respID = UInt16(response[0]) << 8 | UInt16(response[1])
        guard respID == queryID else {
            lines.append("响应 ID 不匹配，忽略")
            return []
        }
        let flags = UInt16(response[2]) << 8 | UInt16(response[3])
        if (flags & 0x0200) != 0 {
            lines.append("注意：响应被截断（TC 位），结果可能不完整")
        }
        let rcode = flags & 0x000F
        guard rcode == 0 else {
            let msg: String
            switch rcode {
            case 1: msg = "格式错误（FORMERR）"
            case 2: msg = "服务器失败（SERVFAIL）"
            case 3: msg = "域名不存在（NXDOMAIN）"
            case 4: msg = "未实现（NOTIMP）"
            case 5: msg = "拒绝（REFUSED）"
            default: msg = "错误码 \(rcode)"
            }
            lines.append("查询失败：\(msg)")
            return []
        }

        let qd = Int(UInt16(response[4]) << 8 | UInt16(response[5]))
        let an = Int(UInt16(response[6]) << 8 | UInt16(response[7]))
        lines.append("收到 \(an) 条应答")

        var offset = 12
        // 跳过 question 区
        for _ in 0..<qd {
            guard let (_, next) = readName(response, offset) else { return [] }
            offset = next + 4 // QTYPE + QCLASS
        }

        var answers: [DNSAnswer] = []
        for _ in 0..<an {
            guard let (owner, afterName) = readName(response, offset) else { break }
            guard afterName + 10 <= response.count else { break }
            let rtype = UInt16(response[afterName]) << 8 | UInt16(response[afterName + 1])
            let ttl = UInt32(response[afterName + 4]) << 24
                | UInt32(response[afterName + 5]) << 16
                | UInt32(response[afterName + 6]) << 8
                | UInt32(response[afterName + 7])
            let rdlen = Int(UInt16(response[afterName + 8]) << 8 | UInt16(response[afterName + 9]))
            let rdataStart = afterName + 10
            guard rdataStart + rdlen <= response.count else { break }
            let data = formatRdata(response, typeCode: rtype, start: rdataStart, length: rdlen)
            let ans = DNSAnswer(name: owner, type: DNSRecordType.name(forWireCode: rtype), ttl: ttl, data: data)
            answers.append(ans)
            lines.append("\(ans.name) \(ans.type) \(ans.data)（TTL \(ans.ttl)）")
            offset = rdataStart + rdlen
        }
        if answers.isEmpty {
            lines.append("无 \(type.rawValue) 记录")
        }
        return answers
    }

    /// 读取（可能带压缩指针的）域名。返回 (域名, 该字段在原位置之后第一个字节的偏移)。
    private static func readName(_ data: [UInt8], _ start: Int) -> (String, Int)? {
        var labels: [String] = []
        var pos = start
        var nextAfter = -1
        var jumps = 0
        while pos < data.count {
            let len = Int(data[pos])
            if len == 0 {
                if nextAfter < 0 { nextAfter = pos + 1 }
                return (labels.joined(separator: "."), nextAfter)
            }
            if (len & 0xC0) == 0xC0 {
                guard pos + 1 < data.count else { return nil }
                let ptr = ((len & 0x3F) << 8) | Int(data[pos + 1])
                if nextAfter < 0 { nextAfter = pos + 2 }
                jumps += 1
                guard jumps <= 10, ptr < data.count else { return nil } // 防指针环
                pos = ptr
                continue
            }
            guard len <= 63, pos + 1 + len <= data.count else { return nil }
            let slice = data[(pos + 1)..<(pos + 1 + len)]
            labels.append(String(bytes: slice, encoding: .utf8) ?? "")
            pos += 1 + len
        }
        return nil
    }

    private static func formatRdata(_ data: [UInt8], typeCode: UInt16, start: Int, length: Int) -> String {
        let end = start + length
        switch typeCode {
        case 1: // A
            guard length == 4 else { return "<无效 A 记录>" }
            return data[start..<end].map(String.init).joined(separator: ".")
        case 28: // AAAA（全展开，不做零压缩）
            guard length == 16 else { return "<无效 AAAA 记录>" }
            var groups: [String] = []
            for i in stride(from: start, to: end, by: 2) {
                let v = UInt16(data[i]) << 8 | UInt16(data[i + 1])
                groups.append(String(v, radix: 16))
            }
            return groups.joined(separator: ":")
        case 2, 5: // NS / CNAME
            return readName(data, start)?.0 ?? "<域名解析失败>"
        case 15: // MX
            guard length >= 3 else { return "<无效 MX 记录>" }
            let pref = UInt16(data[start]) << 8 | UInt16(data[start + 1])
            let host = readName(data, start + 2)?.0 ?? "<域名解析失败>"
            return "\(pref) \(host)"
        case 16: // TXT：长度前缀字符串序列拼接
            var result = ""
            var pos = start
            while pos < end {
                let l = Int(data[pos])
                guard pos + 1 + l <= end else { break }
                result += String(bytes: data[(pos + 1)..<(pos + 1 + l)], encoding: .utf8) ?? ""
                pos += 1 + l
            }
            return result
        case 6: // SOA 主字段
            guard let (mname, afterM) = readName(data, start),
                  let (rname, afterR) = readName(data, afterM),
                  afterR + 4 <= end else { return "<无效 SOA 记录>" }
            var serial: UInt32 = 0
            for i in 0..<4 { serial = serial << 8 | UInt32(data[afterR + i]) }
            return "主 DNS \(mname)，管理员 \(rname)，序列号 \(serial)"
        default:
            return "<\(length) 字节原始数据>"
        }
    }
}
