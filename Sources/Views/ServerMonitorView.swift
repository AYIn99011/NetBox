// ServerMonitorView.swift
// 服务器监测：打开自动测未测过的服务器，逐台状态卡（状态点/延迟/丢包/端口徽章），
// 测法与详情页共用 ServerChecker；并发以 3 台一批的 TaskGroup 控制。监测结果不写历史。

import SwiftUI

struct ServerMonitorView: View {
    @EnvironmentObject private var serverStore: ServerStore
    @State private var results: [UUID: ServerCheckResult] = [:]
    @State private var isChecking = false

    private var onlineCount: Int {
        results.values.filter { $0.isOnline }.count
    }

    var body: some View {
        Group {
            if serverStore.servers.isEmpty {
                ContentUnavailableView(
                    "暂无服务器",
                    systemImage: "server.rack",
                    description: Text("先在「服务器列表」里添加服务器，再回来监测"))
            } else {
                List {
                    Section {
                        HStack {
                            Text("在线 \(onlineCount) / 共 \(serverStore.servers.count)")
                                .font(.headline)
                            Spacer()
                            if isChecking {
                                ProgressView()
                                Text("检测中…")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    Section {
                        ForEach(serverStore.servers) { server in
                            NavigationLink(destination: ServerDetailView(serverID: server.id)) {
                                statusCard(for: server)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("服务器监测")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    check(force: true)
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(isChecking || serverStore.servers.isEmpty)
            }
        }
        .onAppear {
            check(force: false)
        }
    }

    // MARK: - 状态卡

    private func statusCard(for server: ServerItem) -> some View {
        let result = results[server.id]
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor(result))
                    .frame(width: 10, height: 10)
                Text(server.name)
                    .font(.headline)
                Spacer()
                Text(statusText(result))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Text(server.host)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            if let result {
                HStack(spacing: 12) {
                    if let avg = result.pingAvgMs {
                        Text("延迟 \(formatMs(avg))")
                    } else {
                        Text("Ping 无回复")
                    }
                    Text("丢包 \(String(format: "%.0f%%", result.lossPercent))")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if !server.ports.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(server.ports, id: \.self) { port in
                            let open = result.portOpen[port] ?? false
                            Text("\(port)")
                                .font(.caption2)
                                .monospacedDigit()
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background((open ? Color.green : Color.red).opacity(0.15), in: Capsule())
                                .foregroundStyle(open ? Color.green : Color.red)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func statusColor(_ result: ServerCheckResult?) -> Color {
        guard let result else { return .gray }
        return result.isOnline ? .green : .red
    }

    private func statusText(_ result: ServerCheckResult?) -> String {
        guard let result else { return "未测" }
        return result.isOnline ? "在线" : "离线"
    }

    // MARK: - 批量检测（每批最多 3 台并发）

    private func check(force: Bool) {
        guard !isChecking else { return }
        let targets = force
            ? serverStore.servers
            : serverStore.servers.filter { results[$0.id] == nil }
        guard !targets.isEmpty else { return }
        isChecking = true
        Task {
            for chunk in targets.chunked(into: 3) {
                let chunkResults = await withTaskGroup(of: (UUID, ServerCheckResult).self) { group in
                    for server in chunk {
                        group.addTask {
                            (server.id, await ServerChecker.check(server))
                        }
                    }
                    var collected: [UUID: ServerCheckResult] = [:]
                    for await (id, res) in group {
                        collected[id] = res
                    }
                    return collected
                }
                await MainActor.run {
                    results.merge(chunkResults) { _, new in new }
                }
            }
            await MainActor.run {
                isChecking = false
            }
        }
    }
}

// MARK: - 分批小工具

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0, !isEmpty else { return isEmpty ? [] : [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
