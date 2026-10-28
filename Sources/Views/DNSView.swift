// DNSView.swift
// DNS 扫描工具页：域名 + 解析器/记录类型选择、应答记录列表 + 控制台行、本工具历史

import SwiftUI
import Combine

final class DNSViewModel: ObservableObject {
    @Published var domain: String = ""
    @Published var server: String = "223.5.5.5"
    @Published var recordType: DNSRecordType = .A
    @Published var output: [String] = []
    @Published var answers: [DNSAnswer] = []
    @Published var isRunning = false

    /// 由 View 在 onAppear 注入；查询结束时直接写历史
    var historyStore: HistoryStore?

    private var task: Task<Void, Never>?

    func start() {
        let name = domain.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !isRunning else { return }
        output = []
        answers = []
        isRunning = true
        let serverUsed = server
        let type = recordType
        task = Task {
            let result = await DNSClient.query(name: name, server: serverUsed, type: type)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.isRunning = false
                self.answers = result.answers
                self.output = result.lines
                let summary = result.answers.isEmpty
                    ? "无 \(type.rawValue) 记录"
                    : "\(result.answers.count) 条 \(type.rawValue) 记录"
                self.historyStore?.add(HistoryRecord(
                    tool: .dns,
                    target: name,
                    summary: summary,
                    fullOutput: result.lines.joined(separator: "\n")))
            }
        }
    }

    func stop() {
        task?.cancel()
    }

    /// 历史详情页「按此目标重新运行」：写入输入框并立即开跑
    func rerun(target newTarget: String) {
        domain = newTarget
        start()
    }
}

struct DNSView: View {
    private let initialTarget: String?

    @StateObject private var vm = DNSViewModel()
    @EnvironmentObject private var historyStore: HistoryStore

    init(initialTarget: String? = nil) {
        self.initialTarget = initialTarget
    }

    var body: some View {
        List {
            Section("查询") {
                TextField("域名，如 example.com", text: $vm.domain)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .keyboardType(.URL)
                    .disabled(vm.isRunning)
                Picker("解析器", selection: $vm.server) {
                    Text("阿里 223.5.5.5").tag("223.5.5.5")
                    Text("腾讯 119.29.29.29").tag("119.29.29.29")
                    Text("Cloudflare 1.1.1.1").tag("1.1.1.1")
                    Text("Google 8.8.8.8").tag("8.8.8.8")
                }
                .disabled(vm.isRunning)
                Picker("记录类型", selection: $vm.recordType) {
                    ForEach(DNSRecordType.allCases, id: \.self) { type in
                        Text(type.rawValue).tag(type)
                    }
                }
                .disabled(vm.isRunning)
            }

            Section {
                if vm.isRunning {
                    Button("停止", role: .destructive) { vm.stop() }
                } else {
                    Button("开始查询") { vm.start() }
                        .disabled(vm.domain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }

            if !vm.answers.isEmpty {
                Section("应答记录") {
                    ForEach(Array(vm.answers.enumerated()), id: \.offset) { _, answer in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(answer.data)
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                            HStack(spacing: 6) {
                                Text(answer.name)
                                Text(answer.type)
                                Text("TTL \(answer.ttl)")
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        }
                    }
                }
            }

            if vm.isRunning || !vm.output.isEmpty {
                Section("日志") {
                    OutputConsoleView(lines: vm.output)
                        .listRowInsets(EdgeInsets())
                }
            }

            HistorySectionView(tool: .dns) { rec in
                { vm.rerun(target: rec.target) }
            }
        }
        .navigationTitle(ToolKind.dns.title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            vm.historyStore = historyStore
            if let initialTarget, vm.domain.isEmpty {
                vm.domain = initialTarget
            }
        }
    }
}
