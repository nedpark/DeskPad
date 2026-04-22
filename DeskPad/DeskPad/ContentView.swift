import SwiftUI

struct ContentView: View {
    var connection: VNCConnection
    var store: ConnectionStore
    @State private var inputManager: InputManager?
    @State private var keyboardToggleCount = 0
    @State private var activeConnectionID: UUID?

    var body: some View {
        ZStack {
            switch connection.state {
            case .disconnected:
                ConnectionListView(store: store) { savedConnection in
                    activeConnectionID = savedConnection.id
                    store.markConnected(id: savedConnection.id)
                    connection.connect(
                        host: savedConnection.host,
                        port: savedConnection.port,
                        username: savedConnection.username,
                        password: savedConnection.password
                    )
                }

            case .connecting, .handshaking, .authenticating, .initializing:
                connectingView

            case .connected:
                remoteDesktopSession

            case .failed(let message):
                failedView(message: message)
            }
        }
        .onChange(of: connection.state) { oldValue, newValue in
            if newValue == .connected {
                inputManager = InputManager(connection: connection)
            }
        }
    }

    // MARK: - Disconnect with Screenshot Capture

    private func disconnectAndCapture() {
        if let image = connection.framebufferImage,
           let connectionID = activeConnectionID {
            store.saveThumbnail(image, for: connectionID)
        }
        activeConnectionID = nil
        connection.disconnect()
    }

    // MARK: - Connecting View

    private var connectingView: some View {
        VStack(spacing: 24) {
            ProgressView()
                .scaleEffect(1.5)
            
            VStack(spacing: 8) {
                Text(connectingMessage)
                    .font(.headline)
                Text("Please wait...")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Button("Cancel", role: .cancel) {
                disconnectAndCapture()
            }
            .buttonStyle(.bordered)
            .padding(.top, 8)
        }
    }

    private var connectingMessage: String {
        switch connection.state {
        case .connecting: return "Connecting..."
        case .handshaking: return "Handshaking..."
        case .authenticating: return "Authenticating..."
        case .initializing: return "Initializing..."
        default: return "Connecting..."
        }
    }

    // MARK: - Remote Desktop Session

    private var remoteDesktopSession: some View {
        ZStack(alignment: .top) {
            if let inputManager {
                RemoteDesktopView(
                    desktopImage: connection.framebufferImage,
                    desktopSize: connection.desktopSize,
                    inputManager: inputManager,
                    keyboardToggleCount: keyboardToggleCount
                )
                .ignoresSafeArea()
            }

            if connection.framebufferImage == nil {
                waitingForFrameView
            }

            if let warning = connection.framebufferWarning {
                framebufferWarningBanner(warning)
            }

            SessionToolbar(
                desktopName: connection.desktopName,
                onDisconnect: { disconnectAndCapture() },
                onToggleKeyboard: { keyboardToggleCount += 1 }
            )
        }
    }

    // MARK: - Waiting for Frame

    private var waitingForFrameView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.2)
            Text("Waiting for screen data...")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black)
    }

    // MARK: - Warning Banner

    private func framebufferWarningBanner(_ message: String) -> some View {
        VStack {
            Spacer()
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.leading)
                Spacer()
                Button {
                    disconnectAndCapture()
                } label: {
                    Text("Disconnect")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundStyle(.red)
                }
            }
            .padding(12)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
    }

    // MARK: - Failed View

    private func failedView(message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(.red)

            Text("Connection Failed")
                .font(.title2)
                .fontWeight(.semibold)

            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Button("Try Again") {
                disconnectAndCapture()
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 8)
        }
    }
}
