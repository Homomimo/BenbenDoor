import AppIntents
import Foundation

struct WidgetUnlockIntent: AppIntent {
    static let title: LocalizedStringResource = "从小组件开门"
    static let isDiscoverable = false
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    static let openAppWhenRun = true

    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { [.foreground(.immediate)] }

    @MainActor
    func perform() async throws -> some IntentResult {
        #if BENBENDOOR_WIDGET
        // Only the foreground app owns the key and Bluetooth controller.
        try requireAppProcess()
        #else
        try await BluetoothDoor.shared.startFromWidget()
        #endif
        return .result()
    }

    #if BENBENDOOR_WIDGET
    private func requireAppProcess() throws {
        throw NSError(domain: "BenbenDoor.WidgetUnlock", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "请打开奔奔开门 App 后重试。"])
    }
    #endif
}
