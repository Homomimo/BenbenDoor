import AppIntents
import Foundation
import OSLog

// Shared metadata is compiled into the app and widget extension. Only the app
// performs Bluetooth work and reads its own Keychain and preferences.
struct ControlDoorIntent: AppIntent {
    static var title: LocalizedStringResource = "奔奔开门"
    static var description = IntentDescription("从控制中心连接已配置的门锁并开门。")
    // SDK 26 cannot express main-app-only background execution. In that case
    // explicitly foreground the app before perform(), instead of dispatching
    // a background action to an extension that cannot access the Bluetooth key.
    static var openAppWhenRun: Bool {
        #if BENBEN_IOS27_SDK
        if #available(iOS 27.0, *) { return false }
        #endif
        return true
    }
    static var authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed
    static var isDiscoverable: Bool = true

    #if compiler(>=6.2)
    @available(iOS 26.0, *)
    static var supportedModes: IntentModes {
        #if BENBEN_IOS27_SDK
        if #available(iOS 27.0, *) { return [.background] }
        #endif
        return [.foreground(.immediate)]
    }
    #endif

    #if BENBEN_IOS27_SDK
    @available(iOS 27.0, *)
    static var allowedExecutionTargets: IntentExecutionTargets { [.main] }
    #endif

    @MainActor func perform() async throws -> some IntentResult {
        #if BENBEN_WIDGET_EXTENSION
        // Fail explicitly if the system ever dispatches to the extension.
        // Never report success or attempt a second Bluetooth controller here.
        Logger(subsystem: "BenbenDoor", category: "ControlCenter").error("控制中心动作错误地进入小组件扩展，版本 1.3.2 Build 10")
        throw NSError(domain: "BenbenDoor.Control", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "控制中心未能将动作交给主 App，未发送开门指令。请使用“蓝牙开门”快捷指令，并反馈版本及构建 SDK。"])
        #else
        BluetoothDoor.shared.recordShortcutEvent("收到控制中心按钮的开门请求，版本 1.3.2 Build 10")
        #if BENBEN_IOS27_SDK
        if #available(iOS 27.0, *) {
            BluetoothDoor.shared.recordShortcutEvent("控制中心：主 App 后台执行")
        } else {
            BluetoothDoor.shared.recordShortcutEvent("控制中心：已打开 App，开始执行开门")
        }
        #else
        BluetoothDoor.shared.recordShortcutEvent("控制中心：已打开 App，开始执行开门（iOS 26 SDK 兼容路径）")
        #endif
        _ = try await UnlockDoorIntent().perform()
        #endif
        return .result()
    }
}

