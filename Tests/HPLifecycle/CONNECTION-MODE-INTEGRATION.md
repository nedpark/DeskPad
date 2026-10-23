# Persisted HP opt-in integration

`DeskPadConnectionMode` is independent of `VNCColorQuality`. `ConnectionModeSettings`
is a ready SwiftUI picker with AppStorage persistence and Korean explanatory text.
No screen connections are opened by the component. Standard mode remains default;
unknown stored values select standard mode. Existing quality preferences survive.

Root integration (ContentView and VNCSession owned by integrating agent):

1. In the host list and SessionView, add
   `@AppStorage(DeskPadConnectionMode.storageKey) private var storedConnectionMode = DeskPadConnectionMode.standard.rawValue`.
2. Add `ConnectionModeSettings()` to the connection settings section/menu. Disable
   the existing color-quality picker only while
   `DeskPadConnectionMode.restored(from: storedConnectionMode).usesHighPerformance`.
   Do not write to the color quality preference on mode changes.
3. Pass `connectionMode: .restored(from: storedConnectionMode)` to all initial,
   retry, reconnect and quality-change calls to session.connect.
4. Reconnect explicitly in `.onChange(of: storedConnectionMode)` after dismissing
   local keyboard/releasing held keys, using the same saved connection/credential.
5. Extend model.connect and RFBClient initializer with a mode defaulting to
   `.standard`; route HP by that explicit value, not a Release launch argument.
   Retain DEBUG launch override only for diagnostic use. Check server capability
   and trust before sending credentials. Never silently fall back to ordinary VNC
   after a user selected HP, since that would silently lose sound.
6. Keep unsupported authenticated multi-video-stream handling fail-closed in the
   transport; this selection does not relax protocol or decoder validation.

The component may be integrated before release acceptance, but should not be
shipped as functional until root approves actual video/audio/reconnect results.

Validation: standalone Swift6 persistence harness passes in a disposable defaults
suite; SwiftUI component typechecks on macOS15. Full app/iPad build is required
with root's current integration (not performed by this isolated component change).
