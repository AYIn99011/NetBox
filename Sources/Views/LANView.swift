// LANView.swift
// 局域网扫描：无目标输入；顶部显示当前 WiFi 网络信息（视图层 getifaddrs 自取，引擎未暴露该 API），
// 扫描结果为设备列表（IP/主机名/服务/网关标记）+ 控制台 + 本工具历史。
// 说明：iOS 读不到 ARP 表与他人 MAC，设备识别上限就是 IP + 主机名 + Bonjour 服务（引擎注释同）。

import SwiftUI
import Combine
import Darwin

// MARK: - 视图层网络信息（仅本文件使用）

/// en0 的 IPv4/掩码/网段快照
struct LANInterfaceSnapshot {
    var ip: String
    var mask: String
    var subnetCIDR: String   // 如 192.168.1.0/24

    static func current() -> LANInterfaceSnapshot? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            let entry = current.pointee
            cursor = entry.ifa_next
            guard let addrPtr = entry.ifa_addr,
                  addrPtr.pointee.sa_family == sa_family_t(AF_INET),
                  String(cString: entry.ifa_name) == "en0",
                  let maskPtr = entry.ifa_netmask else { continue }
            guard let ip = ipv4String(from: addrPtr), let mask = ipv4String(from: maskPtr) else { continue }
            let ipInt = ipv4ToInt(ip)
            let maskInt = ipv4ToInt(mask)
            let network = ipInt & maskInt
            let cidr = "\(intToIPv4(network))/\(maskInt.nonzeroBitCount)"
            return LANInterfaceSnapshot(ip: ip, mask: mask, subnetCIDR: cidr)
        }
        return nil
    }

    private static func ipv4String(from sockaddrPtr: UnsafeMutablePointer<sockaddr>) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        let ok = sockaddrPtr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { sin in
            var addr = sin.pointee.sin_addr
            return inet_ntop(AF_INET, &addr, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil
        }
        return ok ? String(cString: buffer) : nil
    }

    private static func ipv4ToInt(_ s: String) -> UInt32 {
        var addr = in_addr()
        guard inet_pton(AF_INET, s, &addr) == 1 else { return 0 }
        return UInt32(bigEndian: addr.s_addr)
    }

    private static func intToIPv4(_ v: UInt32) -> String {
        "\((v >> 24) & 0xFF).\((v >> 16) & 0xFF).\((v >> 8) & 0xFF).\(v & 0xFF)"
    }
}

// MARK: - ViewModel

final class LANScanViewModel: ObservableObject {

    @Published var output: [String] = []
    @Published var devices: [LANDevice] = []
    @Published var isRunning = false
    @Published var snapshot: LANInterfaceSnapshot?

    /// 由 View 在 onAppear 注入（与 D1 契约一致）
    var historyStore: HistoryStore?

    private var task: Task<Void, Never>?

    func refreshSnapshot() {
        snapshot = LANInterfaceSnapshot.current()
    }

    func start() {
        guard !isRunning else { return }
        refreshSnapshot()
        isRunning = true
        output = []
        devices = []
        let emit: (String) -> Void = { [weak self] line in
            DispatchQueue.main.async { self?.output.append(line) }
        }
        task = Task { [weak self] in
            guard let self else { return }
            let found = await LANScanner.scan(emit: emit)
            await MainActor.run {
                self.devices = found
                self.isRunning = false
                // 历史 target 记网段；拿不到快照时退回引擎输出语义的占位
                let subnet = self.snapshot?.subnetCIDR ?? "局域网"
                let record = HistoryRecord(
                    tool: .lan,
                    target: subnet,
                    summary: "发现 \(found.count) 台设备",
                    fullOutput: self.output.joined(separator: "\n"))
                self.historyStore?.add(record)
            }
        }
    }

    func stop() {
        task?.cancel()
    }

    /// 历史重跑：局域网无目标参数，直接重新扫描
    func rerun(record: HistoryRecord) {
        start()
    }
}

// MARK: - View

struct LANView: View {
    @StateObject private var vm = LANScanViewModel()
    @EnvironmentObject private var historyStore: HistoryStore

    init(initialTarget: String? = nil) {
        // 局域网扫描无目标输入，initialTarget 仅为统一契约保留，不使用
    }

    var body: some View {
        List {
            Section {
                if let snap = vm.snapshot {
                    LabeledContent("本机 IP", value: snap.ip)
                    LabeledContent("子网掩码", value: snap.mask)
                    LabeledContent("网段", value: snap.subnetCIDR)
                } else {
                    Text("未获取到 WiFi 信息，请确认已连接 WiFi 后重试")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("当前网络")
            } footer: {
                Text("扫描通过 ICMP 探测存活设备，并用 Bonjour 补充服务信息；iOS 限制下无法获取其他设备的 MAC 地址")
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
            }

            if !vm.devices.isEmpty {
                Section("设备（\(vm.devices.count)）") {
                    ForEach(vm.devices, id: \.ip) { device in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                Text(device.ip)
                                    .font(.headline)
                                    .monospacedDigit()
                                if device.isGateway {
                                    Text("网关")
                                        .font(.caption2)
                                        .fontWeight(.semibold)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.orange.opacity(0.15), in: Capsule())
                                        .foregroundStyle(.orange)
                                }
                                Spacer()
                            }
                            if let hostname = device.hostname {
                                Text(hostname)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            if !device.services.isEmpty {
                                Text(device.services.joined(separator: " · "))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }

            if !vm.output.isEmpty {
                Section("输出") {
                    OutputConsoleView(lines: vm.output)
                }
            }

            HistorySectionView(tool: .lan, makeRerun: { record in
                { vm.rerun(record: record) }
            })
        }
        .navigationTitle(ToolKind.lan.title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            vm.historyStore = historyStore
            vm.refreshSnapshot()
        }
    }
}
