import SwiftUI

struct ConnectionRow: View {
    let connection: SavedConnection
    let store: ConnectionStore

    var body: some View {
        HStack(spacing: 16) {
            thumbnailView
                .frame(width: 120, height: 75)
                .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 4) {
                Text(connection.displayName)
                    .font(.headline)

                if !connection.name.isEmpty {
                    Text(addressLabel)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                if let lastConnected = connection.lastConnected {
                    Text(lastConnected, style: .relative)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }

    private var addressLabel: String {
        connection.port == 5900 ? connection.host : "\(connection.host):\(connection.port)"
    }

    @ViewBuilder
    private var thumbnailView: some View {
        if let url = store.thumbnailURL(for: connection),
           let uiImage = UIImage(contentsOfFile: url.path) {
            Image(uiImage: uiImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            ZStack {
                Rectangle()
                    .fill(.quaternary)
                Image(systemName: "desktopcomputer")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
