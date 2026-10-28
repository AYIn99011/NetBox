// Shared.swift
// 工具页共享组件：图标块、终端式输出控制台、历史记录区，以及工具主题色

import SwiftUI

/// 工具主题色（首页图标块与二级页共用；服务器两色在 HomeView 内本地定义）
extension ToolKind {
    var tintColor: Color {
        switch self {
        case .ping: return .blue
        case .traceroute: return .purple
        case .dns: return .cyan
        case .ports: return .orange
        case .whois: return .gray
        case .lan: return .teal
        }
    }
}

/// iOS 设置风格的圆角图标块：30×30、圆角 7、白色符号
struct IconTile: View {
    let symbol: String
    let color: Color

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(color)
                .frame(width: 30, height: 30)
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
        }
    }
}

/// 深色终端式输出区：等宽字体、自动滚到底部；空时显示占位文字
struct OutputConsoleView: View {
    let lines: [String]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if lines.isEmpty {
                    Text("暂无输出")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(Color(white: 0.45))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                            Text(line.isEmpty ? " " : line)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(Color(white: 0.88))
                                .textSelection(.enabled)
                                .id(index)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                }
            }
            .onChange(of: lines.count) { _, newCount in
                if newCount > 0 {
                    proxy.scrollTo(newCount - 1, anchor: .bottom)
                }
            }
            .onAppear {
                if !lines.isEmpty {
                    proxy.scrollTo(lines.count - 1, anchor: .bottom)
                }
            }
        }
        .frame(height: 220)
        .background(Color(white: 0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// 各工具页底部的历史区：只列本工具记录；点条目先进详情页查看，不直接重跑。
/// makeRerun 由工具页提供：给定一条记录，返回「按此目标重新运行」的闭包（或 nil 表示不支持）。
struct HistorySectionView: View {
    let tool: ToolKind
    let makeRerun: (HistoryRecord) -> (() -> Void)?

    @EnvironmentObject private var historyStore: HistoryStore
    @State private var showClearConfirm = false

    var body: some View {
        Section {
            let recs = historyStore.records(for: tool)
            if recs.isEmpty {
                Text("暂无记录")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(recs) { rec in
                    NavigationLink(destination: RecordDetailView(record: rec, onRerun: makeRerun(rec))) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(rec.target)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            HStack(spacing: 6) {
                                Text(formatDateTime(rec.date))
                                Text(rec.summary)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        } header: {
            HStack {
                Text("历史记录")
                Spacer()
                if !historyStore.records(for: tool).isEmpty {
                    Button("清空") { showClearConfirm = true }
                        .font(.footnote)
                        .textCase(nil)
                }
            }
        }
        .confirmationDialog("清空\(tool.title)的全部历史记录？",
                            isPresented: $showClearConfirm,
                            titleVisibility: .visible) {
            Button("清空", role: .destructive) {
                historyStore.clear(tool: tool)
            }
            Button("取消", role: .cancel) {}
        }
    }
}
