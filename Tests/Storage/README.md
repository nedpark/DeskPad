# Storage regression harness

Run from any directory on macOS with the Xcode command-line tools installed:

```sh
Tests/Storage/run.sh
```

The script compiles the actual `DeskPad/Connections/ConnectionStore.swift` with Foundation,
Observation, and Security, treats compiler warnings as errors, and executes eleven
isolated scenarios. It uses temporary JSON files, private UserDefaults suites,
and an injected credential store; it never reads or changes real Keychain items.

Coverage includes legacy JSON and AppStorage migration, no passwords in new JSON,
credential deletion, failed credential and metadata writes, retry after partial
migration/cleanup, merging into existing metadata without replacing newer
credentials, corruption protection, save/delete rollback, rollback error reporting,
and port boundaries. Legacy migration and simultaneous-source import were observed
failing before their implementations; other scenarios exercise failure behavior
and existing validation.

This harness does not establish iOS Keychain entitlements, device accessibility
behavior, or SwiftUI error presentation. Build the iOS app and validate those on a
device separately. The upstream project has no test target; this harness requires
no Xcode project changes.
