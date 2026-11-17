import AppIntents
import Foundation

// Shared metadata is compiled into the app and widget extension. Only the app
// performs Bluetooth work and reads its own Keychain and preferences.
struct ControlDoorIntent: AppIntent {
    static var title: LocalizedStringResource = "奔奔开门"
    static var description = IntentDescription("从控制中心连接已配置的门锁并开门。")
    static var openAppWhenRun: Bool = false
    static var authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed
    static var isDiscoverable: Bool = false

    @MainActor func perform() async throws -> some IntentResult {
        #if BENBEN_WIDGET_EXTENSION
        // Fail explicitly if the system ever dispatches to the extension.
        // Never report success or attempt a second Bluetooth controller here.
        throw NSError(domain: "BenbenDoor.Control", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "开门动作未进入主 App，请先打开奔奔开门后重试。"])
        #else
        BluetoothDoor.shared.recordShortcutEvent("收到控制中心按钮的开门请求")
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
