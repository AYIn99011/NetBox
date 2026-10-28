// WhoisView.swift
// Whois 查询：RDAP 优先、43 端口兜底（引擎内部处理），结果整段等宽文本卡 + 复制全文 + 本工具历史

import SwiftUI
import Combine
import UIKit

// MARK: - ViewModel

final class WhoisViewModel: ObservableObject {

    @Published var query: String = ""
    @Published var result: String = ""
    @Published var isRunning = false

    /// 由 View 在 onAppear 注入（与 D1 契约一致）
    var historyStore: HistoryStore?

    private var task: Task<Void, Never>?

    func start() {
        guard !isRunning else { return }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        isRunning = true
        result = ""
        task = Task { [weak self] in
            guard let self else { return }
            let text = await WhoisClient.lookup(q)
            await MainActor.run {
                self.isRunning = false
                if Task.isCancelled {
                    self.result = "已取消"
                    return
                }
                self.result = text
                let firstLine = text.split(separator: "\n").first.map(String.init) ?? text
                let record = HistoryRecord(
                    tool: .whois,
                    target: q,
                    summary: String(firstLine.prefix(48)),
                    fullOutput: text)
                self.historyStore?.add(record)
            }
        }
    }

    func stop() {
        task?.cancel()
    }

    /// 历史重跑：只带回查询串
    func rerun(record: HistoryRecord) {
        query = record.target
        start()
    }
}

// MARK: - View

struct WhoisView: View {
    @StateObject private var vm: WhoisViewModel
    @EnvironmentObject private var historyStore: HistoryStore
    @State private var copied = false

    init(initialTarget: String? = nil) {
        let model = WhoisViewModel()
        if let initialTarget { model.query = initialTarget }
        _vm = StateObject(wrappedValue: model)
    }

    var body: some View {
        List {
            Section {
                TextField("域名或 IP，如 example.com", text: $vm.query)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
            } header: {
                Text("查询")
            } footer: {
                Text("优先走 RDAP 结构化查询，失败时回退到 43 端口原始 whois")
            }

            Section {
                Button {
                    vm.isRunning ? vm.stop() : vm.start()
                } label: {
                    HStack {
                        Spacer()
                        if vm.isRunning {
                            ProgressView()
                        }
                        Text(vm.isRunning ? "停止" : "开始查询")
                            .fontWeight(.semibold)
                        Spacer()
                    }
                }
                .disabled(!vm.isRunning && vm.query.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            Section("结果") {
                if vm.isRunning {
                    HStack {
                        ProgressView()
                        Text("查询中…")
                            .foregroundStyle(.secondary)
                    }
                } else if vm.result.isEmpty {
                    Text("暂无结果")
                        .foregroundStyle(.secondary)
                } else {
                    Text(vm.result)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                    Button {
                        UIPasteboard.general.string = vm.result
                        copied = true
                    } label: {
                        Label(copied ? "已复制" : "复制全文",
                              systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                }
            }

            HistorySectionView(tool: .whois, makeRerun: { record in
                { vm.rerun(record: record) }
            })
        }
        .navigationTitle(ToolKind.whois.title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { vm.historyStore = historyStore }
        .onChange(of: vm.isRunning) { _, running in
            if running { copied = false }
        }
    }
}
