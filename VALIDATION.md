# Validation status

## Passed in the Windows authoring environment

- Parsed the generated OpenStep Xcode project; all object references resolve and referenced source files exist.
- Checked app/widget Info.plist and shared scheme XML, and scheme target references.
- Extracted the original two 256-byte identifier lookup tables into Swift.
- Executed original JS builders with synthetic parameters to generate expected protocol fixtures.
- Verified identifier conversion, select frame, packed time, both unlock options, response checksum and corruption rejection against those fixtures using an independent Python translation of the Swift logic.
- Exported a separate import configuration from the supplied HTTP response; excluded actual credentials from the source archive.
- Added GitHub Actions macOS simulator tests and unsigned device IPA packaging, including the Widget extension. Workflow has not yet run on GitHub.
- Redesigned the SwiftUI interface with native Liquid Glass on iOS 26 (Swift 6.2+ compiler), material fallback, accessibility options and matching widget styling. UI appearance has not been rendered or tested with Xcode in this Windows environment.

## User-reported cloud build failure and fix

- The user reported an earlier GitHub Actions build failed while compiling BenbenDoorWidget.swift: buildExpression unavailable because the expression does not conform to View. XCTest was cancelled before running.
- The original widget background returned Color.blue.gradient (AnyGradient) from a ViewBuilder. The current widget uses a separate background property returning some View (ZStack with Color and LinearGradient).
- This correction is included in the current source ZIP and the standalone widget replacement file. A successful cloud rebuild has not yet been observed.

## JSON import selection fix

- The user reported JSON configuration files could not be selected. Broadened the fileImporter filter from json to item, while retaining JSON decoding and authorization validation after selection.
- Added coordinated reads for file providers, UTF-8 BOM handling, directory and size checks, and visible file-picker/read failure reporting. Selecting a file still does not trigger unlocking.
- The updated import flow has not been compiled or tested on an iPhone in this Windows environment.

## Status bar overlap correction

- Import update 1.1 (Build 2): after the user reported files remained unselectable, replaced fileImporter with a native copy-mode document picker and added an explicit paste-JSON import screen. Both routes share decoding, size/expiry validation and Keychain persistence. App and widget versions match; new picker and paste flow still need Xcode/iPhone verification.

- The user reported scroll content overlapped the status bar. Moved the home header out of the ScrollView into a fixed safe-area-respecting VStack, applied clipping to the scroll viewport, and placed the edge-to-edge decorative backdrop in a background modifier.
- No fixed status-bar heights or device-specific offsets are used. The change still needs an Xcode build and iPhone verification, including scrolling, bounce, expanded logs and larger text.

## Background unlock 1.2 Build 3

- Previous iOS 1.1 installation/use was confirmed working by the user.
- Added an opt-in App Intent, bluetooth-central mode, shared controller, scoped background execution, 25-second deadline and completion/cancellation handling.
- Keychain access changes only when the user enables the lock-screen setting; default remains WhenUnlockedThisDeviceOnly.
- Added three XCTest cases for opt-in, stale request rejection and foreground-only UI operation, ten tests total. These await Xcode execution.
- New App Intent and background Bluetooth operation have not been compiled or tested here; no claim of successful lock-screen opening.

## Background reconnect diagnostics 1.2.1 Build 4

- User reports that the 1.2 shortcut spins while the phone is unlocked and only proceeds when the app is opened. The exact cause remains unconfirmed.
- Added successful-peripheral UUID caching, direct reconnect with a discovery fallback before any unlock write, Dispatch-based stage watchdogs, and expiry checks on Bluetooth callbacks and foreground resume.
- Added persisted stage diagnostics excluding raw packet bytes and an explicit App Intent entry/return log.
- Request validity is 25 seconds; process suspension can delay watchdog execution and shortcut completion. Expired operations are rejected when execution resumes.
- This revision has not been compiled with Xcode or verified on an iPhone. Ten XCTest methods remain pending macOS execution.

## Background reconnect diagnostics 1.2.3 Build 6

- User reports that the 1.2 shortcut spins while the phone is unlocked and only proceeds when the app is opened. The exact cause remains unconfirmed.
- Added successful-peripheral UUID caching, direct reconnect with a discovery fallback before any unlock write, Dispatch-based stage watchdogs, and expiry checks on Bluetooth callbacks and foreground resume.
- Added persisted stage diagnostics excluding raw packet bytes and an explicit App Intent entry/return log.
- Request validity is 25 seconds; process suspension can delay watchdog execution and shortcut completion. Expired operations are rejected when execution resumes.
- This revision has not been compiled with Xcode or verified on an iPhone. Ten XCTest methods remain pending macOS execution.

## Readable logs 1.2.4 Build 7

- Replaced numeric Bluetooth and application state messages with Chinese descriptions and explained connection, communication confirmation, writes and door replies in plain language.
- Retained request IDs, error codes and signal readings for troubleshooting. A write acknowledgement is explicitly distinguished from confirmed door success.
- Checked all known Bluetooth state mappings and raw-packet persistence filtering locally. No protocol, timeout or connection-policy changes in this revision.
- Swift compilation and iPhone display verification remain pending.

## Native Control Center button 1.3.0 Build 8

- Added an iOS 18+ StaticControlConfiguration with ControlWidgetButton, registered alongside the original widget in a WidgetBundle.
- Included ControlDoorIntent in app and extension targets; app-only ForegroundContinuableIntent conformance routes to the app implementation, which awaits the existing unlock intent. Extension fallback explicitly throws instead of reporting success.
- Checked source target membership and extension compilation flags. No shared Keychain or additional Bluetooth controller was added to the extension.
- Xcode compilation, control gallery registration, process routing, lock-screen authentication and physical door operation remain unverified for this feature.

## Control Center revision 1.3.1 Build 9

- User reports blank control icon and no app entry log when tapping on iOS 27.3 beta 1. The exact runtime cause is not proven.
- Added supportedModes to both control intent builds, re-enabled discoverability and added SDK-gated iOS 27 main-app execution targeting. Build scripts enable the new gate only when the installed SDK supports it.
- Changed the control to an explicit title, key symbol and running caption, used a new control kind, and reload controls on app launch. The old Label initializer is also a documented supported API; this is not proof that its usage caused the blank icon.
- Added archive checks that both app and extension contain control intent metadata. These checks require the macOS archive and have not executed locally.
- App/extension routing, icon rendering and the user's beta OS remain pending device verification. Remove the old control before adding this revision.

## Build flags correction for 1.3.1

- User reports CONTROL_SWIFT_FLAGS unbound variable while running the CI build script.
- Replaced the optional empty Bash array with a nonempty quoted scalar that preserves inherited Swift flags and adds the iOS 27 SDK gate when needed.
- Added a runner-side regression check using /bin/bash under nounset for SDK 26, 27 and 28; the workflow runs it before the Xcode build. Bash execution and Xcode compilation are not available in this Windows environment, so these checks remain pending the macOS runner.

## Control Center revision 1.3.2 Build 10

- User confirms the home widget displays and opens the app successfully, while the control displays only text and produces no app entry log. Control-specific rendering and routing remain unverified.
- SDK 26 builds now explicitly foreground the app before performing the control action. SDK 27 builds on iOS 27 retain main-app-only background execution. This removes the SDK 26 background compatibility path that could dispatch into the throwing extension implementation.
- Removed app-only deprecated ForegroundContinuableIntent conformance. Both targets now advertise matching execution modes. Existing background shortcut behavior is retained.
- Simplified the control to a stable system door symbol Label and system tint; Control Center supplies the glass appearance. New control kind v3 requires replacing the old control. Icon root cause is not established and rendering is not verified.
- Settings and action logs identify the routing path. Static source checks and packaging do not prove system dispatch or physical opening. Xcode and device validation remain pending.

## Not executed here

- Added a glass-door app icon asset catalog with nine opaque PNG sizes; linked it in the app resources phase and set AppIcon for Debug and Release. Validated PNG dimensions and RGB mode locally. Appearance after Xcode asset compilation and installation still needs confirmation.

- Swift compilation, Xcode build, code signing, installation and WidgetKit runtime testing.
- The ten XCTest methods included in this project.
- iPhone Core Bluetooth communication, actual door response or physical opening.

The source and protocol fixture checks are not a substitute for an Xcode build or an iPhone test. Run the included GitHub Actions workflow or build on a Mac; sign the IPA and test on an iPhone. Android physical opening was confirmed by the user on 2026-11-14, which does not verify the iOS app.
