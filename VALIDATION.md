# Validation status

## Review fixes 1.4.1 Build 13

- The production DoorResponseSession classifies each receive/recovery batch before controller events can submit an unlock. Actual submission discards pre-submission partial bytes; a flow-controlled command does not discard or mark submission early.
- Added seven Swift regression cases for coalesced old results, every pre-submission split point, flow control, fragment recovery, normal reply splits, pre-selection fragments and reset. Session refresh compatibility remains unchanged. A delayed standalone reply first delivered after submission cannot be authenticated as belonging to a particular request by this protocol.
- The picker transfers only confirmed App-owned copies into unique staging directories. Consumption awaits the actual read before cleanup, including failure, early rejection and cancellation. Cleanup failures are reported separately from successful saving. Startup cleanup is limited to this helper's UUID-named directories and excludes symbolic links.
- Added ten Swift file-lifecycle tests using synthetic local files, including original-file protection, duplicate ownership, cancellation while reading, cleanup failure and startup sweep boundaries.
- Five Python packaging regressions ran and passed on Windows. Static project/plist/scheme/source-archive and independent original-protocol fixture checks are included in the local release validation.
- There are 47 XCTest methods in the current source. Swift compilation, these tests, actual picker copy paths and iPhone Bluetooth behavior have not been executed in this Windows environment. The included macOS workflow remains responsible for Xcode testing, unsigned device archive and automatic Release publication.

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

## Control Center removal 1.3.3 Build 11

- Removed the native control, shared ControlDoorIntent, app refresh/settings, Xcode references, SDK routing flags, flag-only CI check and control-specific packaging requirements at the user's request.
- Retained the original timeline home/lock-screen widget, its URL opening path, the background UnlockDoorIntent, Liquid Glass app UI and automatic Release workflow.
- Packaging still checks main-app UnlockDoorIntent metadata. No extension intent metadata is required for the timeline widget.
- Local project/plist/scheme/protocol/source ZIP checks passed; Swift compilation, XCTest and device upgrade behavior remain pending macOS CI and iPhone verification.

## Reliability and performance revision 1.4.0 Build 12

- Added a pure response decoder and exchange state with strict business lengths, fragmented/combined frame handling, invalid-header recovery, actual submission tracking and duplicate-write prevention.
- Preserved the original client's response session refresh semantics. There is no unproven response-session equality requirement.
- All active opening paths now attempt remembered-peripheral reconnect. A failed direct connection triggers a 60-second in-process scan-first cooldown. Same-door renewal retains the cache only after Keychain save succeeds.
- ContinuousClock deadlines are shared by callback and write checks. Key validity is rechecked immediately before submission, including queued writes; queued commands rebuild their time window when the channel is ready.
- File import reads/decodes off the main actor with bounded file reads. Import and opening are mutually excluded. Time rollback records are scoped to authorization; a foreground confirmation recovers from a corrected device clock without extending key validity or opening a door.
- Logs record stage and cumulative durations; raw packets never enter the new persistent ring. Stage saves coalesce over 0.5 seconds and flush at completion/background transitions. A sudden process exit can lose the unflushed tail.
- Shared Version.xcconfig supplies app/widget versions. CI includes regression XCTest cases and preserves automatic Release publication. Runtime UI/log versions use bundle metadata.
- Five packaging policy regressions ran and passed locally using synthetic bundles and substituted lipo/ditto commands. They exercise the real Python packager, not an Xcode archive or iPhone installation.
- Static project/protocol/archive checks pass locally; added XCTest execution, actor-isolation compilation and physical speed/reliability verification require macOS CI/iPhone.

## Not executed here

- Added a glass-door app icon asset catalog with nine opaque PNG sizes; linked it in the app resources phase and set AppIcon for Debug and Release. Validated PNG dimensions and RGB mode locally. Appearance after Xcode asset compilation and installation still needs confirmation.

- Swift compilation, Xcode build, code signing, installation and WidgetKit runtime testing.
- The forty-seven XCTest methods included in the current project.
- iPhone Core Bluetooth communication, actual door response or physical opening.

The source and protocol fixture checks are not a substitute for an Xcode build or an iPhone test. Run the included GitHub Actions workflow or build on a Mac; sign the IPA and test on an iPhone. Android physical opening was confirmed by the user on 2026-11-14, which does not verify the iOS app.
