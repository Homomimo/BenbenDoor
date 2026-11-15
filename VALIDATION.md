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

## Not executed here

- Added a glass-door app icon asset catalog with nine opaque PNG sizes; linked it in the app resources phase and set AppIcon for Debug and Release. Validated PNG dimensions and RGB mode locally. Appearance after Xcode asset compilation and installation still needs confirmation.

- Swift compilation, Xcode build, code signing, installation and WidgetKit runtime testing.
- The ten XCTest methods included in this project.
- iPhone Core Bluetooth communication, actual door response or physical opening.

The source and protocol fixture checks are not a substitute for an Xcode build or an iPhone test. Run the included GitHub Actions workflow or build on a Mac; sign the IPA and test on an iPhone. Android physical opening was confirmed by the user on 2026-11-14, which does not verify the iOS app.
