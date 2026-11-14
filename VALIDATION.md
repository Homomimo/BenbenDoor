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

## Not executed here

- Swift compilation, Xcode build, code signing, installation and WidgetKit runtime testing.
- The seven XCTest methods included in this project.
- iPhone Core Bluetooth communication, actual door response or physical opening.

The source and protocol fixture checks are not a substitute for an Xcode build or an iPhone test. Run the included GitHub Actions workflow or build on a Mac; sign the IPA and test on an iPhone. Android physical opening was confirmed by the user on 2026-11-14, which does not verify the iOS app.
