// ServerEditView.swift
// 服务器新建/编辑表单：名称、地址、备注、监测端口（文本框 + 常用端口快捷 chips）。
// 由 ServerListView（新建）与 ServerDetailView（编辑）以 sheet 形式弹出，外层包 NavigationStack。

import SwiftUI

struct ServerEditView: View {
    /// nil = 新建；非 nil = 编辑该服务器
    private let editing: ServerItem?

    @EnvironmentObject private var serverStore: ServerStore
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var host: String
    @State private var note: String
    @State private var portsText: String

    private static let quickPorts = [22, 80, 443, 3389, 8080]

    init(server: ServerItem? = nil) {
        self.editing = server
        _name = State(initialValue: server?.name ?? "")
        _host = State(initialValue: server?.host ?? "")
        _note = State(initialValue: server?.note ?? "")
        _portsText = State(initialValue: server?.ports.map(String.init).joined(separator: ", ") ?? "")
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedHost: String { host.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isValid: Bool { !trimmedName.isEmpty && !trimmedHost.isEmpty }
    private var parsedPorts: [Int] { Self.parsePorts(portsText) }

    var body: some View {
        Form {
            Section("基本信息") {
                TextField("名称，如 VMISS 东京", text: $name)
                TextField("地址（域名或 IP）", text: $host)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                TextField("备注（可选）", text: $note)
            }

            Section {
                TextField("端口，如 22, 443", text: $portsText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.numbersAndPunctuation)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Self.quickPorts, id: \.self) { port in
                            let selected = parsedPorts.contains(port)
                            Button {
                                toggleQuickPort(port)
                            } label: {
                                Text("\(port)")
                                    .font(.callout)
                                    .monospacedDigit()
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(selected ? Color.accentColor : Color.secondary.opacity(0.12), in: Capsule())
                                    .foregroundStyle(selected ? Color.white : Color.primary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 2)
                }
            } header: {
                Text("监测端口")
            } footer: {
                Text("点数字可快速添加/移除常用端口；也可直接输入，逗号分隔")
            }
        }
        .navigationTitle(editing == nil ? "添加服务器" : "编辑服务器")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") { save() }
                    .disabled(!isValid)
            }
        }
    }

    private func toggleQuickPort(_ port: Int) {
        var ports = parsedPorts
        if let index = ports.firstIndex(of: port) {
            ports.remove(at: index)
        } else {
            ports.append(port)
            ports.sort()
        }
        portsText = ports.map(String.init).joined(separator: ", ")
    }

    private func save() {
        guard isValid else { return }
        if var existing = editing {
            existing.name = trimmedName
            existing.host = trimmedHost
            existing.note = note.trimmingCharacters(in: .whitespacesAndNewlines)
            existing.ports = parsedPorts
            serverStore.update(existing)
        } else {
            serverStore.add(ServerItem(
                name: trimmedName,
                host: trimmedHost,
                note: note.trimmingCharacters(in: .whitespacesAndNewlines),
                ports: parsedPorts))
        }
        dismiss()
    }

    static func parsePorts(_ text: String) -> [Int] {
        let parts = text.components(separatedBy: CharacterSet(charactersIn: ",，、 \n\t"))
        let values = parts.compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            .filter { (1...65535).contains($0) }
        return Array(Set(values)).sorted()
    }
}
