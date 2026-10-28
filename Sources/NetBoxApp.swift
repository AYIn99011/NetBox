// NetBoxApp.swift
// App 入口：注入全局 HistoryStore / ServerStore 两个环境对象

import SwiftUI

@main
struct NetBoxApp: App {
    @StateObject private var historyStore = HistoryStore()
    @StateObject private var serverStore = ServerStore()

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environmentObject(historyStore)
                .environmentObject(serverStore)
        }
    }
}
