import Foundation

// MARK: - WhoisClient

/// Whois 查询：优先 RDAP（结构化、稳定），失败兜底 43 端口原始 whois。
enum WhoisClient {

    static func lookup(_ query: String) async -> String {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return "查询为空" }

        if let rdap = await rdapLookup(q) {
            return rdap
        }
        if Task.isCancelled { return "已取消" }
        return rawWhoisFallback(q)
    }

    // MARK: - RDAP

    private static func isIPLiteral(_ s: String) -> Bool {
        var v4 = in_addr()
        if inet_pton(AF_INET, s, &v4) == 1 { return true }
        var v6 = in6_addr()
        return inet_pton(AF_INET6, s, &v6) == 1
    }

    private static func rdapLookup(_ q: String) async -> String? {
        let kind = isIPLiteral(q) ? "ip" : "domain"
        guard let url = URL(string: "https://rdap.org/\(kind)/\(q)") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("application/rdap+json", forHTTPHeaderField: "Accept")
        do {
            // URLSession 默认跟随重定向（rdap.org 会 302 到注册局的 RDAP 服务）
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            return kind == "ip" ? formatIP(json) : formatDomain(json, query: q)
        } catch {
            return nil
        }
    }

    private static func formatDomain(_ json: [String: Any], query: String) -> String {
        var lines: [String] = ["来源：RDAP"]
        let domain = (json["ldhName"] as? String) ?? query
        lines.append("域名：\(domain)")
        if let status = json["status"] as? [String], !status.isEmpty {
            lines.append("状态：\(status.joined(separator: ", "))")
        }
        if let events = json["events"] as? [[String: Any]] {
            for e in events {
                guard let action = e["eventAction"] as? String,
                      let date = e["eventDate"] as? String else { continue }
                switch action {
                case "registration": lines.append("注册时间：\(date)")
                case "expiration": lines.append("到期时间：\(date)")
                case "last changed": lines.append("最后修改：\(date)")
                default: break
                }
            }
        }
        if let entities = json["entities"] as? [[String: Any]] {
            for entity in entities {
                let roles = (entity["roles"] as? [String]) ?? []
                let name = vcardValue(entity, field: "fn") ?? vcardValue(entity, field: "org")
                guard let display = name else { continue }
                if roles.contains("registrar") {
                    lines.append("注册商：\(display)")
                } else if roles.contains("registrant") {
                    lines.append("注册人/组织：\(display)")
                }
            }
        }
        if let ns = json["nameservers"] as? [[String: Any]], !ns.isEmpty {
            let names = ns.compactMap { $0["ldhName"] as? String }
            if !names.isEmpty { lines.append("DNS 服务器：\(names.joined(separator: ", "))") }
        }
        return lines.joined(separator: "\n")
    }

    private static func formatIP(_ json: [String: Any]) -> String {
        var lines: [String] = ["来源：RDAP"]
        if let name = json["name"] as? String { lines.append("网络名称：\(name)") }
        if let handle = json["handle"] as? String { lines.append("句柄：\(handle)") }
        if let cidrs = json["cidr0_cidrs"] as? [[String: Any]], !cidrs.isEmpty {
            var parts: [String] = []
            for c in cidrs {
                if let prefix = c["v4prefix"] as? String, let len = c["length"] as? Int {
                    parts.append("\(prefix)/\(len)")
                } else if let prefix = c["v6prefix"] as? String, let len = c["length"] as? Int {
                    parts.append("\(prefix)/\(len)")
                }
            }
            if !parts.isEmpty { lines.append("CIDR：\(parts.joined(separator: ", "))") }
        } else if let start = json["startAddress"] as? String, let end = json["endAddress"] as? String {
            lines.append("范围：\(start) - \(end)")
        }
        if let country = json["country"] as? String { lines.append("国家/地区：\(country)") }
        if let entities = json["entities"] as? [[String: Any]] {
            for entity in entities {
                let roles = (entity["roles"] as? [String]) ?? []
                guard let display = vcardValue(entity, field: "fn") ?? vcardValue(entity, field: "org") else { continue }
                lines.append("持有方（\(roles.joined(separator: "/"))）：\(display)")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// 从 RDAP entity 的 vcardArray 里取字段值。结构：["vcard", [[名称, 参数, 类型, 值], ...]]
    private static func vcardValue(_ entity: [String: Any], field: String) -> String? {
        guard let vcard = entity["vcardArray"] as? [Any],
              vcard.count >= 2,
              let entries = vcard[1] as? [[Any]] else { return nil }
        for entry in entries where (entry.first as? String) == field {
            if entry.count >= 4, let value = entry[3] as? String, !value.isEmpty {
                return value
            }
        }
        return nil
    }

    // MARK: - 原始 Whois 兜底（TCP 43）

    private static func rawWhoisFallback(_ q: String) -> String {
        let isIP = isIPLiteral(q)
        let tld = q.split(separator: ".").last.map(String.init)?.lowercased() ?? ""

        let firstServer: String
        if isIP {
            firstServer = "whois.arin.net"
        } else if tld == "com" || tld == "net" {
            firstServer = "whois.verisign-grs.com"
        } else if tld == "cn" {
            firstServer = "whois.cnnic.cn"
        } else {
            // 其他 TLD：先查 IANA 拿到该 TLD 的 whois 服务器，再查一跳（只跟一跳 referral）
            guard let ianaText = rawQuery(server: "whois.iana.org", query: tld) else {
                return "查询失败：RDAP 无结果且 whois.iana.org 不可达"
            }
            guard let referred = parseReferral(ianaText) else {
                return "来源：whois.iana.org\n\(ianaText)"
            }
            guard let text = rawQuery(server: referred, query: q) else {
                return "查询失败：\(referred) 不可达（IANA 指路结果）"
            }
            return "来源：\(referred)（经 IANA 指路）\n\(text)"
        }

        // ARIN 对 IP 查询习惯带 "n " 前缀拿网络信息；其余直接查原串
        let wireQuery = (firstServer == "whois.arin.net") ? "n \(q)" : q
        guard let text = rawQuery(server: firstServer, query: wireQuery) else {
            return "查询失败：RDAP 无结果且 \(firstServer) 不可达"
        }
        return "来源：\(firstServer)\n\(text)"
    }

    private static func parseReferral(_ text: String) -> String? {
        for line in text.split(separator: "\n") {
            let lower = line.lowercased()
            if lower.hasPrefix("refer:") || lower.hasPrefix("whois:") {
                let value = line.split(separator: ":", maxSplits: 1).last?
                    .trimmingCharacters(in: .whitespaces) ?? ""
                if !value.isEmpty { return value }
            }
        }
        return nil
    }

    /// 阻塞式 TCP 43 查询：非阻塞 connect + poll 读写，超时 10 秒，全文上限 64KB。
    private static func rawQuery(server: String, query: String) -> String? {
        // 解析服务器（whois 服务器名一般可解析；用 getaddrinfo）
        var hints = addrinfo(ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM,
                             ai_protocol: 0, ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(server, "43", &hints, &res) == 0, let first = res else { return nil }
        defer { freeaddrinfo(res) }

        let fd = socket(first.pointee.ai_family, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        // 非阻塞 connect + poll 等可写
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        let rc = connect(fd, first.pointee.ai_addr, first.pointee.ai_addrlen)
        if rc != 0 {
            guard errno == EINPROGRESS else { return nil }
            var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            guard poll(&pfd, 1, 10_000) > 0 else { return nil }
            var err: Int32 = 0
            var errLen = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &errLen) == 0, err == 0 else { return nil }
        }
        _ = fcntl(fd, F_SETFL, flags) // 恢复阻塞，读写靠 poll 控制节奏

        let payload = Array((query + "\r\n").utf8)
        var sentTotal = 0
        while sentTotal < payload.count {
            var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            guard poll(&pfd, 1, 10_000) > 0 else { return nil }
            let n = payload.withUnsafeBufferPointer { buf in
                send(fd, buf.baseAddress! + sentTotal, buf.count - sentTotal, 0)
            }
            if n <= 0 { return nil }
            sentTotal += n
        }

        var data = Data()
        let deadline = Date().addingTimeInterval(10)
        var chunk = [UInt8](repeating: 0, count: 8192)
        while Date() < deadline, data.count < 65536 {
            if Task.isCancelled { return nil }
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pfd, 1, 500)
            if ready < 0 {
                if errno == EINTR { continue }
                return nil
            }
            guard ready > 0 else { continue }
            let n = recv(fd, &chunk, chunk.count, 0)
            if n == 0 { break } // 对端关闭，读完
            if n < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                return nil
            }
            data.append(contentsOf: chunk[0..<n])
        }
        guard !data.isEmpty else { return nil }
        let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? ""
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
