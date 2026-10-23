import SwiftUI

/// Persisted explicit opt-in. Root connection code must pass the selected mode
/// into every initial connect/reconnect; this view itself never opens a session.
struct ConnectionModeSettings: View {
    @AppStorage(DeskPadConnectionMode.storageKey) private var storedMode = DeskPadConnectionMode.standard.rawValue
    private var selection: Binding<DeskPadConnectionMode> {
        Binding(get: { .restored(from: storedMode) }, set: { storedMode = $0.rawValue })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("연결 방식", selection: selection) {
                ForEach(DeskPadConnectionMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            Text(selection.wrappedValue.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("연결 중 변경하면 다시 연결합니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
