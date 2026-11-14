import SwiftUI
import UniformTypeIdentifiers
import UIKit

@main
struct BenbenDoorApp: App {
    @StateObject private var door = BluetoothDoor()
    var body: some Scene {
        WindowGroup { DoorView().environmentObject(door) }
    }
}

struct DoorView: View {
    @EnvironmentObject private var door: BluetoothDoor
    @Environment(\.scenePhase) private var scenePhase
    @State private var importing = false
    @State private var pendingUnlock = false
    @State private var showDeleteConfirmation = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("就在门前，轻点即开").font(.subheadline).foregroundStyle(.secondary)
                        Text(door.doorName).font(.largeTitle.bold())
                        Label(door.status, systemImage: door.lastSucceeded ? "checkmark.circle.fill" : "dot.radiowaves.left.and.right")
                            .foregroundStyle(door.lastSucceeded ? Color.green : Color.secondary)
                            .accessibilityIdentifier("door-status")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Button { door.start() } label: {
                        VStack(spacing: 16) {
                            if door.isBusy { ProgressView().tint(.white).scaleEffect(1.5) }
                            else { Image(systemName: "lock.open.fill").font(.system(size: 44, weight: .medium)) }
                            Text(door.isBusy ? "正在处理" : "一键开门").font(.title2.bold())
                        }
                        .frame(maxWidth: .infinity).frame(height: 190)
                        .foregroundStyle(.white)
                        .background(door.hasKey ? Color.blue.gradient : Color.gray.gradient, in: RoundedRectangle(cornerRadius: 30))
                    }
                    .buttonStyle(.plain)
                    .disabled(door.isBusy || !door.hasKey)
                    .accessibilityIdentifier("unlock-button")

                    if door.isBusy {
                        Button("停止本次操作", role: .cancel) { door.cancel() }
                            .frame(maxWidth: .infinity)
                    }

                    VStack(alignment: .leading, spacing: 14) {
                        Label("配置与桌面入口", systemImage: "square.grid.2x2").font(.headline)
                        Button { importing = true } label: { Label("导入门锁配置", systemImage: "square.and.arrow.down") }
                            .disabled(door.isBusy)
                        Text("首次导入后，长按桌面添加“奔奔开门”小组件。点击小组件会打开此 App 并自动执行一次开门。")
                            .font(.footnote).foregroundStyle(.secondary)
                        if door.hasKey {
                            Button("移除本机钥匙", role: .destructive) { showDeleteConfirmation = true }
                                .font(.footnote).disabled(door.isBusy)
                        }
                    }
                    .padding(20).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22))

                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("测试日志").font(.headline)
                            Spacer()
                            ShareLink(item: door.exportedLog) { Image(systemName: "square.and.arrow.up") }
                            Button { door.clearLog() } label: { Image(systemName: "trash") }
                                .disabled(door.isBusy)
                        }
                        Toggle("记录原始通信字节", isOn: $door.includePacketBytes).font(.footnote)
                        if door.log.isEmpty {
                            Text("连接步骤和门锁响应将在这里显示。")
                                .font(.footnote).foregroundStyle(.secondary)
                        } else {
                            Text(door.log.joined(separator: "\n"))
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(20).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22))
                }
                .padding(20)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("奔奔开门")
            .navigationBarTitleDisplayMode(.inline)
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            switch result {
            case .success(let url): door.importKey(from: url)
            case .failure: break
            }
        }
        .confirmationDialog("移除本机保存的门锁钥匙？", isPresented: $showDeleteConfirmation, titleVisibility: .visible) {
            Button("移除钥匙", role: .destructive) { door.removeKey() }
        }
        .onOpenURL { url in
            guard url.scheme?.lowercased() == "benbenlock", url.host?.lowercased() == "unlock" else { return }
            pendingUnlock = true
            runPendingUnlock()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { runPendingUnlock() }
            if phase == .background { pendingUnlock = false; door.cancel() }
        }
    }

    private func runPendingUnlock() {
        guard pendingUnlock, scenePhase == .active, UIApplication.shared.applicationState == .active else { return }
        pendingUnlock = false
        door.start()
    }
}
