// PingView.swift
// Ping 工具页：目标 + 次数选项、逐行控制台输出、四格统计卡与「复制 Ping 结果」、本工具历史

import SwiftUI
import Combine
import UIKit

final class PingViewModel: ObservableObject {
    @Published var target: String = ""
    @Published var count: Int = 10
    @Published var payloadSize: Int = 56
    @Published var intervalSeconds: Double = 1.0
    @Published var timeoutSeconds: Double = 1.5
    @Published var output: [String] = []
    @Published var isRunning = false
    @Published var stats: PingStats?

    /// 由 View 在 onAppear 注入；运行结束时直接写历史
    var historyStore: HistoryStore?

    private var task: Task<Void, Never>?

    func start() {
        let host = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, !isRunning else { return }
        output = []
        stats = nil
        isRunning = true
        let runCount = count
        let runSize = payloadSize
        let runInterval = intervalSeconds
        let runTimeout = timeoutSeconds
        task = Task {
            let summary = await PingEngine.run(host: host, count: runCount,
                                               payloadSize: runSize,
                                               timeoutSeconds: runTimeout,
                                               intervalSeconds: runInterval) { line in
                DispatchQueue.main.async { [weak self] in
                    self?.output.append(line)
                }
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.isRunning = false
                if let summary {
                    self.stats = summary.stats
                    // 引擎 lines 与最终 output 一致，用 lines 落盘最稳妥
                    let summaryText: String
                    if let s = summary.stats {
                        summaryText = s.summaryText()
                    } else {
                        summaryText = "发送 \(summary.sent)，接收 \(summary.received)，丢包 \(String(format: "%.1f", summary.lossPercent))%"
                    }
                    self.historyStore?.add(HistoryRecord(
                        tool: .ping,
                        target: host,
                        summary: summaryText,
                        fullOutput: summary.lines.joined(separator: "\n"),
                        pingStats: summary.stats))
                } else {
                    // 硬错误（解析失败等）：引擎已把原因写进输出行，一并存档便于回看
                    self.historyStore?.add(HistoryRecord(
                        tool: .ping,
                        target: host,
                        summary: "执行失败",
                        fullOutput: self.output.joined(separator: "\n")))
                }
            }
        }
    }

    func stop() {
        task?.cancel()
    }

    /// 历史详情页「按此目标重新运行」：写入输入框并立即开跑
    func rerun(target newTarget: String) {
        target = newTarget
        start()
    }
}

struct PingView: View {
    private let initialTarget: String?

    @StateObject private var vm = PingViewModel()
    @EnvironmentObject private var historyStore: HistoryStore
    @State private var copied = false

    init(initialTarget: String? = nil) {
        self.initialTarget = initialTarget
    }

    var body: some View {
        List {
            Section("目标") {
                TextField("主机名或 IP 地址", text: $vm.target)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .keyboardType(.URL)
                    .disabled(vm.isRunning)
                Stepper(value: $vm.count, in: 1...100) {
                    Text("次数：\(vm.count)")
                }
                .disabled(vm.isRunning)
                Stepper(value: $vm.payloadSize, in: 16...1472, step: 16) {
                    Text("包大小：\(vm.payloadSize) 字节")
                }
                .disabled(vm.isRunning)
                Stepper(value: $vm.intervalSeconds, in: 0.2...5.0, step: 0.2) {
                    Text("间隔：\(vm.intervalSeconds, specifier: "%.1f") 秒")
                }
                .disabled(vm.isRunning)
                Stepper(value: $vm.timeoutSeconds, in: 0.5...10.0, step: 0.5) {
                    Text("超时：\(vm.timeoutSeconds, specifier: "%.1f") 秒")
                }
                .disabled(vm.isRunning)
            }

            Section {
                if vm.isRunning {
                    Button("停止", role: .destructive) { vm.stop() }
                } else {
                    Button("开始 Ping") { vm.start() }
                        .disabled(vm.target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }

            if vm.isRunning || !vm.output.isEmpty {
                Section("结果") {
                    // 统计与复制放控制台前面：跑完第一眼先看到结论，不必滚过日志
                    if let stats = vm.stats {
                        HStack(spacing: 0) {
                            statCell(title: "最低", value: formatMs(stats.minMs))
                            statCell(title: "平均", value: formatMs(stats.avgMs))
                            statCell(title: "最高", value: formatMs(stats.maxMs))
                            statCell(title: "丢包", value: String(format: "%.0f%%", stats.lossPercent))
                        }
                        .listRowInsets(EdgeInsets(top: 10, leading: 0, bottom: 10, trailing: 0))
                        Button {
                            UIPasteboard.general.string = stats.summaryText()
                            copied = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                copied = false
                            }
                        } label: {
                            Label(copied ? "已复制" : "复制 Ping 结果",
                                  systemImage: copied ? "checkmark" : "doc.on.doc")
                        }
                    }
                    OutputConsoleView(lines: vm.output)
                        .listRowInsets(EdgeInsets())
                }
            }

            HistorySectionView(tool: .ping) { rec in
                { vm.rerun(target: rec.target) }
            }
        }
        .navigationTitle(ToolKind.ping.title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            vm.historyStore = historyStore
            if let initialTarget, vm.target.isEmpty {
                vm.target = initialTarget
            }
        }
    }

    private func statCell(title: String, value: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(.body, design: .monospaced))
                .fontWeight(.semibold)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}
