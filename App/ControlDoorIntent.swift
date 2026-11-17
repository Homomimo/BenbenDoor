import AppIntents
import Foundation
import OSLog

// Shared metadata is compiled into the app and widget extension. Only the app
// performs Bluetooth work and reads its own Keychain and preferences.
struct ControlDoorIntent: AppIntent {
    static var title: LocalizedStringResource = "奔奔开门"
    static var description = IntentDescription("从控制中心连接已配置的门锁并开门。")
    static var openAppWhenRun: Bool = false
    static var authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed
    static var isDiscoverable: Bool = true

    #if compiler(>=6.2)
    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { [.background, .foreground(.dynamic)] }
    #endif

    #if BENBEN_IOS27_SDK
    @available(iOS 27.0, *)
    static var allowedExecutionTargets: IntentExecutionTargets { [.main] }
    #endif

    @MainActor func perform() async throws -> some IntentResult {
        #if BENBEN_WIDGET_EXTENSION
        // Fail explicitly if the system ever dispatches to the extension.
        // Never report success or attempt a second Bluetooth controller here.
        Logger(subsystem: "BenbenDoor", category: "ControlCenter").error("控制中心动作被派发到小组件扩展，没有进入主 App。版本 1.3.1 Build 9")
        throw NSError(domain: "BenbenDoor.Control", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "控制中心未能启动开门服务。请打开 App 一次，并删除旧控件后重新添加“奔奔开门”。"])
        #else
        BluetoothDoor.shared.recordShortcutEvent("收到控制中心按钮的开门请求，版本 1.3.1 Build 9")
        #if BENBEN_IOS27_SDK
        BluetoothDoor.shared.recordShortcutEvent("控制中心兼容配置：使用 iOS 27 主 App 执行限定")
        #else
        BluetoothDoor.shared.recordShortcutEvent("控制中心兼容配置：使用后台执行模式")
        #endif
        _ = try await UnlockDoorIntent().perform()
        #endif
        return .result()
    }
}

#if !BENBEN_WIDGET_EXTENSION
// This conformance routes execution to the app process. We never request a
// foreground continuation: opening the app UI is not part of this action.
extension ControlDoorIntent: ForegroundContinuableIntent {}
#endif
