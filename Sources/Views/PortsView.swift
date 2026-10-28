// PortsView.swift
// 服务器端口查看：预设/自定义端口组 + TCP connect 扫描，开放端口大字列表 + 控制台 + 本工具历史

import SwiftUI
import Combine

// MARK: - ViewModel

final class PortScanViewModel: ObservableObject {

    enum Preset: String, CaseIterable, Identifiable {
        case common = "常用端口"
        case web = "Web"
        case top1024 = "1–1024"
        case custom = "自定义"
        var id: String { rawValue }
    }

    @Published var target: String = ""
    @Published var preset: Preset = .common
    @Published var customPortsText: String = ""
    @Published var output: [String] = []
    @Published var openPorts: [Int] = []
    @Published var isRunning = false

    /// 由 View 在 onAppear 注入（与 D1 契约一致）
    var historyStore: HistoryStore?

    private var task: Task<Void, Never>?

    /// 当前选择对应的待扫端口（自定义解析失败返回空数组）
    var selectedPorts: [Int] {
        switch preset {
        case .common: return PortScanner.commonPorts
        case .web: return PortScanner.webPorts
        case .top1024: return PortScanner.top1024
        case .custom: return Self.parsePorts(customPortsText)
        }
    }

    static func parsePorts(_ text: String) -> [Int] {
        let parts = text.components(separatedBy: CharacterSet(charactersIn: ",，、 \n\t"))
        let values = parts.compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            .filter { (1...65535).contains($0) }
        return Array(Set(values)).sorted()
    }

    func start() {
        guard !isRunning else { return }
        let host = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { return }
        let ports = selectedPorts
        output = []
        openPorts = []
        guard !ports.isEmpty else {
            output.append("自定义端口为空或格式无效，请用逗号分隔填写 1–65535 的端口")
            return
        }
        isRunning = true
        let emit: (String) -> Void = { [weak self] line in
            DispatchQueue.main.async { self?.output.append(line) }
        }
        task = Task { [weak self] in
            guard let self else { return }
            let found = await PortScanner.scan(host: host, ports: ports, emit: emit)
            await MainActor.run {
                self.openPorts = found
                self.isRunning = false
                let record = HistoryRecord(
                    tool: .ports,
                    target: host,
                    summary: "开放 \(found.count) 个端口",
                    fullOutput: self.output.joined(separator: "\n"))
                self.historyStore?.add(record)
            }
        }
    }

    func stop() {
        task?.cancel()
    }

    /// 历史重跑：只带回目标，端口组沿用当前选择
    func rerun(record: HistoryRecord) {
        target = record.target
        start()
    }
}

// MARK: - View

struct PortsView: View {
    @StateObject private var vm: PortScanViewModel
    @EnvironmentObject private var historyStore: HistoryStore

    init(initialTarget: String? = nil) {
        let model = PortScanViewModel()
        if let initialTarget { model.target = initialTarget }
        _vm = StateObject(wrappedValue: model)
    }

    var body: some View {
        List {
            Section {
                TextField("目标主机（域名或 IP）", text: $vm.target)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                Picker("端口预设", selection: $vm.preset) {
                    ForEach(PortScanViewModel.Preset.allCases) { preset in
                        Text(preset.rawValue).tag(preset)
                    }
                }
                if vm.preset == .custom {
                    TextField("自定义端口，如 22, 80, 443", text: $vm.customPortsText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.numbersAndPunctuation)
                }
            } header: {
                Text("目标")
            } footer: {
                Text("将扫描 \(vm.selectedPorts.count) 个端口（TCP 连接探测）")
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
                        Text(vm.isRunning ? "停止" : "开始扫描")
                            .fontWeight(.semibold)
                        Spacer()
                    }
                }
                .disabled(!vm.isRunning && vm.target.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            if !vm.openPorts.isEmpty {
                Section("开放端口（\(vm.openPorts.count)）") {
                    ForEach(vm.openPorts, id: \.self) { port in
                        HStack(alignment: .firstTextBaseline) {
                            Text("\(port)")
                                .font(.title3)
                                .fontWeight(.semibold)
                                .monospacedDigit()
                            Text(PortScanner.serviceNames[port] ?? "未知服务")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("开放")
                                .foregroundStyle(.green)
                        }
                    }
                }
            }

            if !vm.output.isEmpty {
                Section("输出") {
                    OutputConsoleView(lines: vm.output)
                }
            }

            HistorySectionView(tool: .ports, makeRerun: { record in
                { vm.rerun(record: record) }
            })
        }
        .navigationTitle(ToolKind.ports.title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { vm.historyStore = historyStore }
    }
}
