import Foundation
@main struct ConnectionModeHarness {
    static func main() {
        precondition(DeskPadConnectionMode.restored(from: nil) == .standard)
        precondition(DeskPadConnectionMode.restored(from: "future-mode") == .standard)
        precondition(!DeskPadConnectionMode.defaultMode.usesHighPerformance)
        let suite = "DeskPad.ConnectionModeTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("fullColor", forKey: "deskpadColorQuality")
        defaults.set(DeskPadConnectionMode.highPerformanceExperimental.rawValue,
                     forKey: DeskPadConnectionMode.storageKey)
        let fresh = UserDefaults(suiteName: suite)!
        precondition(DeskPadConnectionMode.restored(from: fresh.string(forKey: DeskPadConnectionMode.storageKey)).usesHighPerformance)
        defaults.set(DeskPadConnectionMode.standard.rawValue, forKey: DeskPadConnectionMode.storageKey)
        precondition(defaults.string(forKey: "deskpadColorQuality") == "fullColor")
        print("Connection mode defaults, explicit persisted opt-in and color preference isolation passed")
    }
}
