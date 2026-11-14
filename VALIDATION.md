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

## Not executed here

- Added a glass-door app icon asset catalog with nine opaque PNG sizes; linked it in the app resources phase and set AppIcon for Debug and Release. Validated PNG dimensions and RGB mode locally. Appearance after Xcode asset compilation and installation still needs confirmation.

- Swift compilation, Xcode build, code signing, installation and WidgetKit runtime testing.
- The seven XCTest methods included in this project.
- iPhone Core Bluetooth communication, actual door response or physical opening.

The source and protocol fixture checks are not a substitute for an Xcode build or an iPhone test. Run the included GitHub Actions workflow or build on a Mac; sign the IPA and test on an iPhone. Android physical opening was confirmed by the user on 2026-11-14, which does not verify the iOS app.
