// ServerListView.swift
// 服务器列表：名称/地址/未测状态点，左滑删除、EditButton 排序，点行进详情，右上 + 新建

import SwiftUI

struct ServerListView: View {
    @EnvironmentObject private var serverStore: ServerStore
    @State private var showingAdd = false

    var body: some View {
        Group {
            if serverStore.servers.isEmpty {
                ContentUnavailableView(
                    "暂无服务器",
                    systemImage: "server.rack",
                    description: Text("点右上角 + 添加一台服务器"))
            } else {
                List {
                    ForEach(serverStore.servers) { server in
                        NavigationLink(destination: ServerDetailView(serverID: server.id)) {
                            HStack(spacing: 12) {
                                // 列表页不做实时检测，状态点统一灰 = 未测（详情页/监测页才有实时状态）
                                Circle()
                                    .fill(Color.gray)
                                    .frame(width: 10, height: 10)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(server.name)
                                        .font(.headline)
                                    Text(server.host)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                    .onDelete { offsets in
                        serverStore.delete(at: offsets)
                    }
                    .onMove { source, destination in
                        serverStore.move(from: source, to: destination)
                    }
                }
            }
        }
        .navigationTitle("服务器列表")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if !serverStore.servers.isEmpty {
                    EditButton()
                }
                Button {
                    showingAdd = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showingAdd) {
            NavigationStack {
                ServerEditView()
            }
        }
    }
}
