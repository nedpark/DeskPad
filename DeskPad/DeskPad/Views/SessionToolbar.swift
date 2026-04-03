import SwiftUI

struct SessionToolbar: View {
    let desktopName: String
    let onDisconnect: () -> Void

    @State private var isExpanded = false

    var body: some View {
        VStack(spacing: 0) {
            if isExpanded {
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(desktopName)
                            .font(.caption)
                            .fontWeight(.medium)
                        Text("Connected")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button(action: onDisconnect) {
                        Label("Disconnect", systemImage: "xmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            }

            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 20)
                    .background(.ultraThinMaterial, in: Capsule())
            }
        }
        .padding(.top, 4)
    }
}
