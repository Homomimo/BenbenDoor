import AppIntents
import CoreBluetooth

struct UnlockDoorIntent: AppIntent {
    static var title: LocalizedStringResource = "蓝牙开门"
    static var description = IntentDescription("连接已配置的奔奔门锁并执行一次开门。需先在 App 中导入钥匙并开启锁屏快捷开门。")
    static var openAppWhenRun: Bool = false
    // The app's explicit opt-in controls locked-device use.
    static var authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        guard KeyStore.backgroundUnlockEnabled else {
            throw DoorError.message("请先打开奔奔开门，在设置中开启“允许锁屏快捷开门”。")
        }
        guard CBManager.authorization == .allowedAlways else {
            throw DoorError.message("请先在奔奔开门 App 内允许蓝牙访问，并完成一次前台开门测试。")
        }
        let message = try await BluetoothDoor.shared.unlockFromShortcut()
        return .result(dialog: IntentDialog(stringLiteral: message))
    }
}

struct BenbenDoorShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: UnlockDoorIntent(),
                    phrases: ["使用\(.applicationName)开门"],
                    shortTitle: "蓝牙开门", systemImageName: "lock.open.fill")
    }
}
