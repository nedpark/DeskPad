import SwiftUI

struct ContentView: View {
    var connection: VNCConnection
    @State private var inputManager: InputManager?

    var body: some View {
        ZStack {
            switch connection.state {
            case .disconnected:
                ConnectionView { host, port, username, password in
                    connection.connect(host: host, port: port, username: username, password: password)
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
                connection.disconnect()
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
                    inputManager: inputManager
                )
                .ignoresSafeArea()
            }

            SessionToolbar(
                desktopName: connection.desktopName,
                onDisconnect: { connection.disconnect() }
            )
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
                connection.disconnect()
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 8)
        }
    }
}
