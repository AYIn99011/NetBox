// Models.swift
// NetBox 共享数据模型（其他模块按此契约引用，勿改名）

import Foundation

/// 工具种类：六个诊断工具页共用同一套历史与导航契约
enum ToolKind: String, Codable, CaseIterable {
    case ping
    case traceroute
    case dns
    case ports
    case whois
    case lan

    /// 首页与二级页显示的中文标题
    var title: String {
        switch self {
        case .ping: return "Ping"
        case .traceroute: return "路由轨迹"
        case .dns: return "DNS 扫描"
        case .ports: return "服务器端口查看"
        case .whois: return "Whois 查询"
        case .lan: return "局域网扫描"
        }
    }

    /// SF Symbol 名（均为真实存在的系统符号，适配 iOS 18）
    var symbol: String {
        switch self {
        case .ping: return "antenna.radiowaves.left.and.right"
        case .traceroute: return "point.3.connected.trianglepath.dotted"
        case .dns: return "server.rack"
        case .ports: return "door.left.hand.open"
        case .whois: return "text.magnifyingglass"
        case .lan: return "network"
        }
    }
}

/// Ping 汇总统计；复制结果时只复制这四项
struct PingStats: Codable {
    var minMs: Double
    var avgMs: Double
    var maxMs: Double
    var lossPercent: Double
    /// 发送次数；可选是为了兼容没有这个字段的旧存档记录
    var sent: Int? = nil

    func summaryText() -> String {
        String(format: "最低 %.1fms · 平均 %.1fms · 最高 %.1fms · 丢包 %.0f%%",
               minMs, avgMs, maxMs, lossPercent)
    }
}

/// 一条历史记录：运行结束自动写入，点开先看详情而非直接重跑
struct HistoryRecord: Identifiable, Codable {
    var id: UUID
    var tool: ToolKind
    var target: String
    var date: Date
    var summary: String
    var fullOutput: String
    var pingStats: PingStats?

    init(id: UUID = UUID(),
         tool: ToolKind,
         target: String,
         date: Date = Date(),
         summary: String,
         fullOutput: String,
         pingStats: PingStats? = nil) {
        self.id = id
        self.tool = tool
        self.target = target
        self.date = date
        self.summary = summary
        self.fullOutput = fullOutput
        self.pingStats = pingStats
    }
}

/// 服务器列表中的一台服务器
struct ServerItem: Identifiable, Codable {
    var id: UUID
    var name: String
    var host: String
    var note: String
    var ports: [Int]

    init(id: UUID = UUID(),
         name: String,
         host: String,
         note: String = "",
         ports: [Int] = []) {
        self.id = id
        self.name = name
        self.host = host
        self.note = note
        self.ports = ports
    }
}
