import SwiftUI
import UniformTypeIdentifiers
import UIKit

@main
struct BenbenDoorApp: App {
    @StateObject private var door = BluetoothDoor.shared
    var body: some Scene {
        WindowGroup { DoorView().environmentObject(door) }
    }
}

struct DoorView: View {
    @EnvironmentObject private var door: BluetoothDoor
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .largeTitle) private var buttonSize: CGFloat = 228
    @State private var importing = false
    @State private var pendingUnlock = false
    @State private var showDeleteConfirmation = false
    @State private var showSettings = false
    @State private var importAfterSettings = false
    @State private var showLog = false
    @State private var backgroundUnlock = KeyStore.backgroundUnlockEnabled
    @State private var backgroundSettingError = ""
    private var accent: Color { door.lastSucceeded ? .green : .blue }

    var body: some View {
        // The fixed header and scroll viewport both respect the safe area.
        // Only the decorative background may extend behind the status bar.
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 24).padding(.vertical, 12)
                .frame(maxWidth: 560).frame(maxWidth: .infinity)
                .background(.regularMaterial)
            ScrollView {
                VStack(spacing: 30) {
                    VStack(spacing: 10) {
                        Text(door.hasKey ? "你的门，轻点即开" : "让回家更简单")
                            .font(.subheadline).foregroundStyle(.secondary)
                        Text(door.doorName)
                            .font(.system(.largeTitle, design: .rounded, weight: .bold))
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    unlockControl
                    statusCard
                    if door.isBusy {
                        Button("停止本次操作", role: .cancel) { door.cancel() }
                            .font(.subheadline.weight(.semibold)).padding(.horizontal, 22).padding(.vertical, 14)
                            .modifier(DoorGlass(cornerRadius: 26, interactive: true))
                    }
                    if !door.hasKey { importControl }
                    widgetHint
                    logPanel
                }
                .padding(.horizontal, 24).padding(.top, 16).padding(.bottom, 32)
                .frame(maxWidth: 560).frame(maxWidth: .infinity)
            }
            .scrollIndicators(.hidden)
            // Clip bouncing/scrolling content below the fixed header.
            .clipped()
        }
        .background { DoorBackdrop() }
        .tint(accent)
        .sheet(isPresented: $showSettings, onDismiss: {
            if importAfterSettings { importAfterSettings = false; importing = true }
        }) { settings }
        .sheet(isPresented: $importing) { KeyImportView().environmentObject(door) }
        .onOpenURL { url in
            guard url.scheme?.lowercased() == "benbenlock", url.host?.lowercased() == "unlock" else { return }
            pendingUnlock = true
            runPendingUnlock()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { door.appBecameActive(); runPendingUnlock() }
            if phase == .background { pendingUnlock = false; door.appEnteredBackground() }
        }
        .sensoryFeedback(.success, trigger: door.lastSucceeded) { _, succeeded in succeeded }
    }

    private var header: some View {
        HStack {
            Label("奔奔开门", systemImage: "door.left.hand.open").font(.headline)
            Spacer()
            Button { showSettings = true } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 18, weight: .medium)).frame(width: 48, height: 48)
                    .foregroundStyle(.primary)
                    .modifier(DoorGlass(cornerRadius: 24, interactive: true))
            }
            .buttonStyle(.plain).accessibilityLabel("钥匙与设置")
        }
    }

    private var unlockControl: some View {
        Button { door.start() } label: {
            VStack(spacing: 18) {
                if door.isBusy {
                    ProgressView().controlSize(.large).tint(accent)
                        .frame(height: 56).accessibilityLabel("正在连接门锁")
                } else {
                    Image(systemName: door.lastSucceeded ? "lock.open.fill" : "lock.fill")
                        .font(.system(size: 48, weight: .light))
                        .symbolRenderingMode(.hierarchical)
                        .frame(height: 56)
                }
                Text(door.isBusy ? "正在开门" : "一键开门")
                    .font(.system(.title2, design: .rounded, weight: .semibold))
                Text(door.hasKey ? "靠近门锁 · 轻触开启" : "请先导入钥匙")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(24)
            .frame(width: min(buttonSize, 248), height: min(buttonSize, 248))
            .foregroundStyle(door.hasKey ? accent : Color.secondary)
            .modifier(DoorGlass(cornerRadius: 150, interactive: true, tint: door.hasKey ? accent.opacity(0.12) : .clear))
            .overlay {
                Circle().strokeBorder(accent.opacity(door.hasKey ? 0.18 : 0.06), lineWidth: 1)
                    .padding(-9).accessibilityHidden(true)
            }
            .shadow(color: accent.opacity(door.hasKey ? 0.12 : 0.03), radius: 30, y: 16)
            .padding(12)
        }
        .buttonStyle(DoorPressStyle(reduceMotion: reduceMotion))
        .disabled(door.isBusy || !door.hasKey)
        .accessibilityIdentifier("unlock-button")
        .accessibilityLabel(door.isBusy ? "正在开门" : "一键开门")
        .accessibilityHint(door.hasKey ? "连接附近已配置的门锁并开门" : "请先导入门锁配置")
    }

    private var statusCard: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: door.lastSucceeded ? "checkmark.circle.fill" : (door.isBusy ? "antenna.radiowaves.left.and.right" : "dot.radiowaves.left.and.right"))
                .font(.title3).foregroundStyle(accent).padding(.top, 1)
            VStack(alignment: .leading, spacing: 6) {
                Text(door.status).font(.subheadline.weight(.medium))
                    .accessibilityIdentifier("door-status")
                Text(door.isBusy ? "请保持 App 在前台" : "通过附近蓝牙连接门锁")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(20).frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24))
        .accessibilityElement(children: .combine)
    }

    private var importControl: some View {
        Button { importing = true } label: {
            Label("导入门锁配置", systemImage: "key.horizontal")
                .font(.headline).frame(maxWidth: .infinity).padding(18)
                .modifier(DoorGlass(cornerRadius: 24, interactive: true, tint: .blue.opacity(0.1)))
        }
        .buttonStyle(.plain).disabled(door.isBusy)
    }

    private var widgetHint: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "square.grid.2x2").font(.title2).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 6) {
                Text("把开门放在桌面").font(.subheadline.weight(.semibold))
                Text("长按桌面添加“奔奔一键开门”小组件，轻点即可打开 App 并开门。")
                    .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
    }

    private var logPanel: some View {
        DisclosureGroup(isExpanded: $showLog) {
            VStack(alignment: .leading, spacing: 16) {
                Toggle("记录原始通信字节", isOn: $door.includePacketBytes).font(.footnote)
                HStack(spacing: 20) {
                    ShareLink(item: door.exportedLog) { Label("分享日志", systemImage: "square.and.arrow.up") }
                    Spacer()
                    Button { door.clearLog() } label: { Label("清空", systemImage: "trash") }
                        .disabled(door.isBusy)
                }
                .font(.footnote)
                Text(door.log.isEmpty ? "连接步骤和门锁响应将在这里显示。" : door.log.joined(separator: "\n"))
                    .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.top, 16)
        } label: {
            Label("连接日志", systemImage: "waveform.path.ecg").font(.subheadline.weight(.medium))
        }
        .padding(20)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24))
    }

    private var settings: some View {
        NavigationStack {
            Form {
                Section("本机钥匙") {
                    Label(door.doorName, systemImage: "key.horizontal.fill")
                    Button("导入或更新门锁配置") {
                        importAfterSettings = true
                        showSettings = false
                    }
                    .disabled(door.isBusy)
                    if door.hasKey {
                        Button("移除本机钥匙", role: .destructive) { showDeleteConfirmation = true }
                            .disabled(door.isBusy)
                    }
                }
                Section("使用方式") {
                    Label("在 App 或桌面小组件中一键开门", systemImage: "hand.tap")
                    Label("首次使用请允许蓝牙访问", systemImage: "antenna.radiowaves.left.and.right")
                    Label("钥匙仅保存在此设备", systemImage: "iphone")
                    Text("版本 1.2.2 · Build 5").font(.footnote).foregroundStyle(.secondary)
                }
                Section {
                    Toggle("允许锁屏快捷开门", isOn: Binding(get: { backgroundUnlock }, set: { enabled in
                        do {
                            try KeyStore.setBackgroundUnlockEnabled(enabled)
                            backgroundUnlock = enabled
                        } catch { backgroundSettingError = error.localizedDescription }
                    }))
                    .disabled(!door.hasKey || door.isBusy)
                    if !backgroundSettingError.isEmpty { Text(backgroundSettingError).foregroundStyle(.red).font(.footnote) }
                } footer: {
                    Text("开启后，可用快捷指令中的“蓝牙开门”动作尝试锁屏开门。钥匙会在本次开机首次解锁后允许后台读取。后台扫描与执行受系统限制；原有“打开 URL”入口仍会打开 App。")
                }
                Section {
                    Text("配置续期或重新发放后，请重新导入有效钥匙。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("钥匙与设置").navigationBarTitleDisplayMode(.inline)
            .onAppear { backgroundUnlock = KeyStore.backgroundUnlockEnabled }
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showSettings = false } } }
            .confirmationDialog("移除本机保存的门锁钥匙？", isPresented: $showDeleteConfirmation, titleVisibility: .visible) {
                Button("移除钥匙", role: .destructive) { door.removeKey() }
            }
        }
    }

    private func runPendingUnlock() {
        guard pendingUnlock, scenePhase == .active, UIApplication.shared.applicationState == .active else { return }
        pendingUnlock = false
        door.start()
    }
}

private struct KeyImportView: View {
    @EnvironmentObject private var door: BluetoothDoor
    @Environment(\.dismiss) private var dismiss
    @State private var showFiles = false
    @State private var json = ""
    @State private var resultMessage = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button { showFiles = true } label: {
                        Label("选择配置文件", systemImage: "doc.badge.plus")
                    }
                    .disabled(door.isBusy)
                } footer: {
                    Text("选择 JSON 或文本配置文件。如果文件仍为灰色，可将完整 JSON 内容粘贴到下方导入。")
                }
                Section("粘贴配置 JSON") {
                    TextEditor(text: $json)
                        .font(.system(.footnote, design: .monospaced))
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                        .frame(minHeight: 180)
                        .accessibilityLabel("配置 JSON 内容")
                    Button("校验并导入") {
                        if door.importKey(text: json) { json = ""; dismiss() }
                        else { resultMessage = door.status }
                    }
                    .disabled(door.isBusy || json.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if !resultMessage.isEmpty {
                    Section("导入结果") { Text(resultMessage).font(.footnote) }
                }
            }
            .navigationTitle("导入钥匙配置").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
            .sheet(isPresented: $showFiles) {
                KeyDocumentPicker { url in
                    showFiles = false
                    if let url = url { door.importKey(from: url); resultMessage = door.status }
                }
                .ignoresSafeArea()
            }
        }
    }
}

private struct KeyDocumentPicker: UIViewControllerRepresentable {
    let completion: (URL?) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(completion: completion) }
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        // Copy mode allows providers to supply a local file for import.
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.data, .content, .json, .plainText], asCopy: true)
        picker.allowsMultipleSelection = false
        picker.shouldShowFileExtensions = true
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let completion: (URL?) -> Void
        init(completion: @escaping (URL?) -> Void) { self.completion = completion }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { completion(urls.first) }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { completion(nil) }
    }
}

private struct DoorBackdrop: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color(uiColor: .systemGroupedBackground)
                if !reduceTransparency {
                    Ellipse().fill(Color.cyan.opacity(scheme == .dark ? 0.16 : 0.22))
                        .frame(width: geometry.size.width * 1.2, height: 340)
                        .blur(radius: 70).offset(x: -110, y: -230)
                    Ellipse().fill(Color.blue.opacity(scheme == .dark ? 0.19 : 0.13))
                        .frame(width: geometry.size.width, height: 360)
                        .blur(radius: 80).offset(x: 130, y: 60)
                    Ellipse().fill(Color.mint.opacity(0.12))
                        .frame(width: 260, height: 300)
                        .blur(radius: 65).offset(x: -100, y: 310)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .ignoresSafeArea().accessibilityHidden(true).allowsHitTesting(false)
    }
}

// Glass is reserved for controls; content cards use material for readability.
private struct DoorGlass: ViewModifier {
    var cornerRadius: CGFloat
    var interactive = false
    var tint: Color = .clear
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    @ViewBuilder func body(content: Content) -> some View {
        if reduceTransparency || contrast == .increased {
            content
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: cornerRadius))
                .overlay { RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(Color.primary.opacity(0.25), lineWidth: 1) }
        } else {
            compatibleGlass(content)
        }
    }

    @ViewBuilder private func compatibleGlass(_ content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular.tint(tint).interactive(interactive), in: .rect(cornerRadius: cornerRadius))
        } else {
            material(content)
        }
        #else
        material(content)
        #endif
    }

    private func material(_ content: Content) -> some View {
        content
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
            .background(tint, in: RoundedRectangle(cornerRadius: cornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(LinearGradient(colors: [.white.opacity(0.75), .white.opacity(0.12), .white.opacity(0.35)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1)
            }
    }
}

private struct DoorPressStyle: ButtonStyle {
    var reduceMotion: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.72), value: configuration.isPressed)
    }
}
