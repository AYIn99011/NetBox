// Stores.swift
// 历史记录与服务器列表的持久化存储（UserDefaults + Codable JSON）

import Foundation
import Combine

/// 历史记录存储：按工具分组，每种工具最多保留 100 条，新记录插头部
final class HistoryStore: ObservableObject {
    @Published private(set) var records: [HistoryRecord] = []

    private let defaultsKey = "history.v1"
    private let perToolLimit = 100
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    /// 某工具的全部历史（已按时间倒序，因为新记录始终插头部）
    func records(for tool: ToolKind) -> [HistoryRecord] {
        records.filter { $0.tool == tool }
    }

    /// 插入一条新记录；同工具超出上限时从尾部淘汰最旧的
    func add(_ record: HistoryRecord) {
        records.insert(record, at: 0)
        let sameTool = records.filter { $0.tool == record.tool }
        if sameTool.count > perToolLimit {
            let overflowIDs = Set(sameTool.suffix(from: perToolLimit).map { $0.id })
            records.removeAll { overflowIDs.contains($0.id) }
        }
        save()
    }

    /// 清空某工具的全部历史
    func clear(tool: ToolKind) {
        records.removeAll { $0.tool == tool }
        save()
    }

    private func load() {
        guard let data = defaults.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([HistoryRecord].self, from: data) else {
            records = []
            return
        }
        records = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        defaults.set(data, forKey: defaultsKey)
    }
}

/// 服务器列表存储：不预置任何条目，无存档即空列表
final class ServerStore: ObservableObject {
    @Published var servers: [ServerItem] = []

    private let defaultsKey = "servers.v2"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    func add(_ server: ServerItem) {
        servers.append(server)
        save()
    }

    func update(_ server: ServerItem) {
        guard let index = servers.firstIndex(where: { $0.id == server.id }) else { return }
        servers[index] = server
        save()
    }

    func delete(at offsets: IndexSet) {
        servers.remove(atOffsets: offsets)
        save()
    }

    func delete(id: UUID) {
        servers.removeAll { $0.id == id }
        save()
    }

    func move(from source: IndexSet, to destination: Int) {
        servers.move(fromOffsets: source, toOffset: destination)
        save()
    }

    func server(id: UUID) -> ServerItem? {
        servers.first { $0.id == id }
    }

    private func load() {
        // 不预置任何服务器：无存档时就是空列表，用户自己添加
        guard let data = defaults.data(forKey: defaultsKey) else {
            servers = []
            return
        }
        servers = (try? JSONDecoder().decode([ServerItem].self, from: data)) ?? []
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(servers) else { return }
        defaults.set(data, forKey: defaultsKey)
    }
}
