// TracerouteView.swift
// 路由轨迹工具页：目标 + 最大跳数、逐跳控制台输出、本工具历史

import SwiftUI
import Combine

final class TracerouteViewModel: ObservableObject {
    @Published var target: String = ""
    @Published var maxHops: Int = 30
    @Published var output: [String] = []
    @Published var isRunning = false

    /// 由 View 在 onAppear 注入；运行结束时直接写历史
    var historyStore: HistoryStore?

    private var task: Task<Void, Never>?

    func start() {
        let host = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, !isRunning else { return }
        output = []
        isRunning = true
        let hopsLimit = maxHops
        task = Task {
            let hops = await TracerouteEngine.run(host: host, maxHops: hopsLimit) { line in
                DispatchQueue.main.async { [weak self] in
                    self?.output.append(line)
                }
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.isRunning = false
                // emit 全部先于本次 MainActor 块入队主队列，output 此时已完整
                let summary: String
                if hops.isEmpty {
                    summary = "执行失败"
                } else if hops.last?.reachedTarget == true {
                    summary = "共 \(hops.count) 跳，已到达目标"
                } else {
                    summary = "共 \(hops.count) 跳，未到达目标"
                }
                self.historyStore?.add(HistoryRecord(
                    tool: .traceroute,
                    target: host,
                    summary: summary,
                    fullOutput: self.output.joined(separator: "\n")))
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

struct TracerouteView: View {
    private let initialTarget: String?

    @StateObject private var vm = TracerouteViewModel()
    @EnvironmentObject private var historyStore: HistoryStore

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
                Stepper(value: $vm.maxHops, in: 5...64) {
                    Text("最大跳数：\(vm.maxHops)")
                }
                .disabled(vm.isRunning)
            }

            Section {
                if vm.isRunning {
                    Button("停止", role: .destructive) { vm.stop() }
                } else {
                    Button("开始追踪") { vm.start() }
                        .disabled(vm.target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }

            if vm.isRunning || !vm.output.isEmpty {
                Section("结果") {
                    OutputConsoleView(lines: vm.output)
                        .listRowInsets(EdgeInsets())
                }
            }

            HistorySectionView(tool: .traceroute) { rec in
                { vm.rerun(target: rec.target) }
            }
        }
        .navigationTitle(ToolKind.traceroute.title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            vm.historyStore = historyStore
            if let initialTarget, vm.target.isEmpty {
                vm.target = initialTarget
            }
        }
    }
}
