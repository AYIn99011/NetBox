// HomeView.swift
// 首页：iOS 现代分组卡片风——「网络诊断」六工具 + 「服务器」两入口

import SwiftUI

struct HomeView: View {
    private let diagnosticTools: [ToolKind] = [.ping, .traceroute, .dns, .ports, .whois, .lan]

    var body: some View {
        NavigationStack {
            List {
                Section("网络诊断") {
                    ForEach(diagnosticTools, id: \.self) { tool in
                        NavigationLink(destination: destination(for: tool)) {
                            HStack(spacing: 12) {
                                IconTile(symbol: tool.symbol, color: tool.tintColor)
                                Text(tool.title)
                            }
                        }
                    }
                }

                Section("服务器") {
                    NavigationLink(destination: ServerMonitorView()) {
                        HStack(spacing: 12) {
                            IconTile(symbol: "waveform.path.ecg", color: .green)
                            Text("服务器监测")
                        }
                    }
                    NavigationLink(destination: ServerListView()) {
                        HStack(spacing: 12) {
                            IconTile(symbol: "list.bullet.rectangle", color: .indigo)
                            Text("服务器列表")
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("NetBox")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    @ViewBuilder
    private func destination(for tool: ToolKind) -> some View {
        switch tool {
        case .ping: PingView()
        case .traceroute: TracerouteView()
        case .dns: DNSView()
        case .ports: PortsView()
        case .whois: WhoisView()
        case .lan: LANView()
        }
    }
}
