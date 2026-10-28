// ServerDetailView.swift
// 服务器详情：信息卡 + 立即检测（Ping 4 次 + 端口逐测）+ 快捷操作 + 编辑入口。
// ServerChecker / ServerCheckResult 定义在本文件，供 ServerMonitorView 复用同一套测法。

import SwiftUI

// MARK: - 检测结果与检测器（详情页/监测页共用）

struct ServerCheckResult {
    var pingReceived: Int = 0
    var pingAvgMs: Double?
    var lossPercent: Double = 0
    /// 端口 → 是否开放；空字典表示未配置监测端口
    var portOpen: [Int: Bool] = [:]

    /// 在线判定：Ping 有回复，且（未配端口 或 至少一个监测端口开放）
    var isOnline: Bool {
        guard pingReceived > 0 else { return false }
        if portOpen.isEmpty { return true }
        return portOpen.values.contains(true)
    }
}

enum ServerChecker {
    static func check(_ server: ServerItem) async -> ServerCheckResult {
        var result = ServerCheckResult()
        if let summary = await PingEngine.run(host: server.host, count: 4, emit: { _ in }) {
            result.pingReceived = summary.received
            result.pingAvgMs = summary.avgMs
            result.lossPercent = summary.lossPercent
        }
        if !server.ports.isEmpty {
            let open = await PortScanner.scan(host: server.host, ports: server.ports, emit: { _ in })
            let openSet = Set(open)
            for port in server.ports {
                result.portOpen[port] = openSet.contains(port)
            }
        }
        return result
    }
}

// MARK: - 详情页入口（按 id 实时取最新值，删后有提示）

struct ServerDetailView: View {
    let serverID: UUID

    @EnvironmentObject private var serverStore: ServerStore

    init(serverID: UUID) {
        self.serverID = serverID
    }

    var body: some View {
        if let server = serverStore.server(id: serverID) {
            ServerDetailContentView(server: server)
        } else {
            ContentUnavailableView(
                "服务器已删除",
                systemImage: "trash",
                description: Text("这台服务器已不在列表中"))
            .navigationTitle("服务器详情")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

// MARK: - 详情内容

private struct ServerDetailContentView: View {
    let server: ServerItem

    @State private var result: ServerCheckResult?
    @State private var isChecking = false
    @State private var showingEdit = false

    var body: some View {
        List {
            Section("信息") {
                LabeledContent("名称", value: server.name)
                LabeledContent("地址") {
                    Text(server.host)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                }
                if !server.note.isEmpty {
                    LabeledContent("备注", value: server.note)
                }
                if server.ports.isEmpty {
                    LabeledContent("监测端口", value: "未设置")
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("监测端口")
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 54), spacing: 8)], alignment: .leading, spacing: 8) {
                            ForEach(server.ports, id: \.self) { port in
                                Text("\(port)")
                                    .font(.callout)
                                    .monospacedDigit()
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 4)
                                    .background(Color.secondary.opacity(0.12), in: Capsule())
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }

            Section("检测") {
                Button {
                    runCheck()
                } label: {
                    HStack {
                        Spacer()
                        if isChecking {
                            ProgressView()
                        }
                        Text(isChecking ? "检测中…" : "立即检测")
                            .fontWeight(.semibold)
                        Spacer()
                    }
                }
                .disabled(isChecking)

                if let result {
                    LabeledContent("状态") {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(result.isOnline ? Color.green : Color.red)
                                .frame(width: 10, height: 10)
                            Text(result.isOnline ? "在线" : "离线")
                        }
                    }
                    LabeledContent("Ping 平均延迟") {
                        if let avg = result.pingAvgMs {
                            Text(formatMs(avg))
                        } else {
                            Text("无回复")
                                .foregroundStyle(.secondary)
                        }
                    }
                    LabeledContent("丢包", value: String(format: "%.0f%%", result.lossPercent))
                    ForEach(server.ports, id: \.self) { port in
                        LabeledContent("端口 \(port)") {
                            let open = result.portOpen[port] ?? false
                            Text(open ? "开放" : "关闭")
                                .fontWeight(.medium)
                                .foregroundStyle(open ? .green : .red)
                        }
                    }
                } else if !isChecking {
                    Text("尚未检测，点「立即检测」测一次")
                        .foregroundStyle(.secondary)
                }
            }

            Section("快捷操作") {
                NavigationLink(destination: PingView(initialTarget: server.host)) {
                    Label("Ping 它", systemImage: ToolKind.ping.symbol)
                }
                NavigationLink(destination: PortsView(initialTarget: server.host)) {
                    Label("测端口", systemImage: ToolKind.ports.symbol)
                }
                NavigationLink(destination: TracerouteView(initialTarget: server.host)) {
                    Label("路由轨迹", systemImage: ToolKind.traceroute.symbol)
                }
            }
        }
        .navigationTitle(server.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("编辑") { showingEdit = true }
            }
        }
        .sheet(isPresented: $showingEdit) {
            NavigationStack {
                ServerEditView(server: server)
            }
        }
    }

    private func runCheck() {
        guard !isChecking else { return }
        isChecking = true
        let target = server
        Task {
            let res = await ServerChecker.check(target)
            await MainActor.run {
                result = res
                isChecking = false
            }
        }
    }
}
