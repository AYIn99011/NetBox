// RecordDetailView.swift
// 历史记录详情：先查看（目标/时间/摘要/统计/完整输出），需要时再从底部按钮重跑。
// 若为 Ping 记录且有统计，额外提供「复制 Ping 结果」——只复制四项汇总文本。

import SwiftUI
import UIKit

struct RecordDetailView: View {
    let record: HistoryRecord
    var onRerun: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var historyStore: HistoryStore
    @State private var copied = false
    @State private var confirmDelete = false

    var body: some View {
        List {
            Section("概览") {
                LabeledContent("工具", value: record.tool.title)
                LabeledContent("目标", value: record.target)
                LabeledContent("时间", value: formatDateTime(record.date))
                LabeledContent("摘要", value: record.summary)
            }

            if let stats = record.pingStats {
                Section("Ping 统计") {
                    if let sent = stats.sent {
                        LabeledContent("次数", value: "\(sent)")
                    }
                    LabeledContent("最低延迟", value: formatMs(stats.minMs))
                    LabeledContent("平均延迟", value: formatMs(stats.avgMs))
                    LabeledContent("最高延迟", value: formatMs(stats.maxMs))
                    LabeledContent("丢包", value: String(format: "%.0f%%", stats.lossPercent))
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
            }

            Section("完整输出") {
                OutputConsoleView(lines: record.fullOutput.components(separatedBy: "\n"))
                    .listRowInsets(EdgeInsets())
            }

            if let onRerun {
                Section {
                    Button("按此目标重新运行") {
                        onRerun()
                        dismiss()
                    }
                }
            }
        }
        .navigationTitle("记录详情")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(role: .destructive) {
                    confirmDelete = true
                } label: {
                    Image(systemName: "trash")
                }
            }
        }
        .confirmationDialog("删除这条记录？", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                historyStore.delete(id: record.id)
                dismiss()
            }
            Button("取消", role: .cancel) {}
        }
    }
}
