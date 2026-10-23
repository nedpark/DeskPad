import SwiftUI
import UIKit
import Observation

struct ContentView: View {
    @AppStorage(DeskPadConnectionMode.storageKey) private var storedConnectionMode = DeskPadConnectionMode.standard.rawValue
    @AppStorage("deskpadColorQuality") private var colorQuality = VNCColorQuality.lowLatency
    @AppStorage("deskpadScrollSensitivity") private var scrollSensitivity = RemoteScrollSensitivity.double
    @State private var store = ConnectionStore()
    @State private var editingConnection: SavedConnection?
    @State private var isAddingConnection = false
    @State private var connectingTo: SavedConnection?
    @State private var deletingConnection: SavedConnection?
    @State private var message: UserMessage?

    var body: some View {
        NavigationStack {
            Group {
                if store.connections.isEmpty {
                    VStack {
                        if let error = store.loadError {
                            Label(error, systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                                .padding()
                        }
                        ContentUnavailableView {
                            Label("연결이 없습니다", systemImage: "display")
                        } description: {
                            Text("VNC 서버를 추가해 원격 데스크톱에 연결하세요.")
                        } actions: {
                            Button("서버 추가", systemImage: "plus") {
                                isAddingConnection = true
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                } else {
                    List {
                        if let loadError = store.loadError {
                            Label(loadError, systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                        }
                        ForEach(store.connections) { connection in
                            ConnectionRow(connection: connection) {
                                connectingTo = connection
                            } edit: {
                                editingConnection = connection
                            } delete: {
                                deletingConnection = connection
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("DeskPad")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        ConnectionModeSettings()
                            ColorQualityPicker(selection: $colorQuality)
                                .disabled(DeskPadConnectionMode.restored(from: storedConnectionMode).usesHighPerformance)
                        Divider()
                        ScrollSensitivityPicker(selection: $scrollSensitivity)
                    } label: {
                        Label("화면 및 스크롤 설정", systemImage: "speedometer")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isAddingConnection = true
                    } label: {
                        Label("서버 추가", systemImage: "plus")
                    }
                    .accessibilityHint("새 VNC 연결 정보를 입력합니다.")
                }
            }
            .sheet(isPresented: $isAddingConnection) {
                ConnectionEditor(store: store, connection: nil)
            }
            .sheet(item: $editingConnection) { connection in
                ConnectionEditor(store: store, connection: connection)
            }
            .fullScreenCover(item: $connectingTo) { connection in
                SessionView(connection: connection, store: store)
            }
            .confirmationDialog(
                "이 연결을 삭제할까요?",
                isPresented: Binding(
                    get: { deletingConnection != nil },
                    set: { if !$0 { deletingConnection = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("삭제", role: .destructive) {
                    guard let deletingConnection else { return }
                    do {
                        try store.delete(deletingConnection)
                    } catch {
                        message = UserMessage(text: "연결을 삭제하지 못했습니다: \(error.localizedDescription)")
                    }
                    self.deletingConnection = nil
                }
                Button("취소", role: .cancel) { deletingConnection = nil }
            }
            .alert(item: $message) { item in
                Alert(
                    title: Text("DeskPad"),
                    message: Text(item.text),
                    dismissButton: .default(Text("확인"))
                )
            }
        }
    }
}

private struct ConnectionRow: View {
    let connection: SavedConnection
    let connect: () -> Void
    let edit: () -> Void
    let delete: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "desktopcomputer")
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 42, height: 42)
                .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))

            VStack(alignment: .leading, spacing: 4) {
                Text(connection.displayName)
                    .font(.headline)
                Text(verbatim: "\(connection.host):\(connection.port)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if let date = connection.lastConnected {
                    Text("최근 연결 \(date.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 8)
            Button(action: connect) {
                Label("연결", systemImage: "arrow.up.right")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityLabel("\(connection.displayName)에 연결")
        }
        .padding(.vertical, 5)
        .swipeActions(edge: .trailing) {
            Button(role: .destructive, action: delete) {
                Label("삭제", systemImage: "trash")
            }
            Button(action: edit) {
                Label("편집", systemImage: "pencil")
            }
            .tint(.blue)
        }
        .contextMenu {
            Button(action: connect) { Label("연결", systemImage: "arrow.up.right") }
            Button(action: edit) { Label("편집", systemImage: "pencil") }
            Button(role: .destructive, action: delete) { Label("삭제", systemImage: "trash") }
        }
    }
}

private struct ConnectionEditor: View {
    @Environment(\.dismiss) private var dismiss
    let store: ConnectionStore
    let connection: SavedConnection?
    @State private var message: UserMessage?

    @State private var name = ""
    @State private var host = ""
    @State private var port = "5900"
    @State private var username = ""
    @State private var password = ""
    @State private var hasExistingPassword = false

    var body: some View {
        NavigationStack {
            Form {
                Section("서버") {
                    TextField("표시 이름 (선택)", text: $name)
                        .textContentType(.nickname)
                    TextField("호스트 이름 또는 IP", text: $host)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .textContentType(.URL)
                    TextField("포트", text: $port)
                        .keyboardType(.numberPad)
                }
                Section("로그인") {
                    TextField("Mac 계정 사용자 이름", text: $username)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                    SecureField(hasExistingPassword ? "Mac 계정 암호 변경 (비워두면 유지)" : "Mac 계정 암호", text: $password)
                        .textContentType(.password)
                    Text("macOS 화면 공유의 Apple Diffie–Hellman 인증에는 Mac 계정 사용자 이름과 암호가 필요합니다. 인증 후 화면 데이터는 암호화되지 않으므로 신뢰할 수 있는 네트워크에서만 연결하세요.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(connection == nil ? "연결 추가" : "연결 편집")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("취소") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("저장", action: save)
                }
            }
            .alert(item: $message) { item in
                Alert(title: Text("DeskPad"), message: Text(item.text), dismissButton: .default(Text("확인")))
            }
            .task {
                guard let connection else { return }
                name = connection.name
                host = connection.host
                port = String(connection.port)
                username = connection.username
                do {
                    hasExistingPassword = try store.hasPassword(for: connection)
                } catch {
                    message = UserMessage(text: "Keychain 자격 증명을 확인하지 못했습니다: \(error.localizedDescription)")
                }
            }
        }
    }

    private func save() {
        do {
            let parsedPort = try ConnectionStore.parsePort(port)
            let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
            try ConnectionStore.validate(host: trimmedHost, port: parsedPort)
            let saved = SavedConnection(
                id: connection?.id ?? UUID(),
                name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                host: trimmedHost,
                port: parsedPort,
                username: username.trimmingCharacters(in: .whitespacesAndNewlines),
                lastConnected: connection?.lastConnected
            )
            try store.save(saved, newPassword: password.isEmpty ? nil : password)
            dismiss()
        } catch {
            message = UserMessage(text: "연결을 저장하지 못했습니다: \(error.localizedDescription)")
        }
    }
}

private struct SessionView: View {
    @AppStorage(DeskPadConnectionMode.storageKey) private var storedConnectionMode = DeskPadConnectionMode.standard.rawValue
    @AppStorage("deskpadColorQuality") private var colorQuality = VNCColorQuality.lowLatency
    @AppStorage("deskpadScrollSensitivity") private var scrollSensitivity = RemoteScrollSensitivity.double
    @Environment(\.dismiss) private var dismiss
    @State private var session = VNCSessionModel()
    @State private var keyboardController = RemoteKeyboardController()
    @State private var didStart = false
    @Environment(\.scenePhase) private var scenePhase
    @State private var warning: UserMessage?
    @State private var password: String?

    let connection: SavedConnection
    let store: ConnectionStore

    var body: some View {
        NavigationStack {
            ZStack(alignment: .topLeading) {
                VStack(spacing: 0) {
                    if let error = session.clipboardError {
                        Label(error, systemImage: "doc.on.clipboard")
                            .font(.footnote).foregroundStyle(.orange).padding(8)
                    }
                    if case .failed = session.state {
                        Label(session.state.title, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal)
                            .padding(.vertical, 8)
                    }
                    if session.screenWidth > 0, session.screenHeight > 0,
                       (session.highPerformancePlayback != nil || session.framebuffer.count == session.screenWidth * session.screenHeight * 4) {
                        RemoteDesktopSurface(controller: keyboardController, framebuffer: session.framebuffer,
                            framebufferRevision: session.framebufferRevision,
                            size: CGSize(width: session.screenWidth, height: session.screenHeight),
                            remoteCursor: session.remoteCursor,
                            playback: session.highPerformancePlayback,
                            scrollSensitivity: scrollSensitivity,
                            onKey: { session.sendKey(keysym: $0, pressed: $1) },
                            onPointer: { point, mask in session.sendPointer(x: Int(point.x), y: Int(point.y), buttonMask: mask) })
                            .background(.black)
                            .accessibilityLabel("원격 데스크톱. 두 손가락 스크롤, 세 손가락 화면 이동, 핀치 확대.")
                    } else {
                        ContentUnavailableView {
                            Label(session.state.title, systemImage: session.stateIcon)
                        } description: {
                            Text(sessionDescription)
                        } actions: {
                            if session.state == .ended {
                                Button("다시 연결") { session.connect(to: connection, password: password, colorQuality: colorQuality, connectionMode: .restored(from: storedConnectionMode)) }
                                    .buttonStyle(.borderedProminent)
                            } else if case .failed = session.state {
                                Button("다시 시도") { session.connect(to: connection, password: password, colorQuality: colorQuality, connectionMode: .restored(from: storedConnectionMode)) }
                                    .buttonStyle(.borderedProminent)
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }

            }
            .ignoresSafeArea(.keyboard)
            .navigationTitle(connection.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("닫기") {
                        keyboardController.dismiss()
                        session.disconnect()
                        dismiss()
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if case .connected = session.state {
                        Text("iPad · \(keyboardController.inputLanguageLabel)")
                            .font(.subheadline.monospacedDigit())
                            .fixedSize(horizontal: true, vertical: false)
                            .accessibilityLabel("iPad 입력 언어: \(keyboardController.inputLanguageLabel)")
                            .accessibilityHint("원격 Mac의 입력 언어가 아닌 iPad 키보드의 선택 상태입니다.")
                        Button {
                            if keyboardController.isFocused {
                                keyboardController.dismiss()
                            } else {
                                keyboardController.focus()
                            }
                        } label: {
                            Label(
                                keyboardController.isFocused ? "키보드 닫기" : "키보드",
                                systemImage: keyboardController.isFocused
                                    ? "keyboard.chevron.compact.down"
                                    : "keyboard"
                            )
                        }
                        .accessibilityHint("Mac에 문자와 키 입력을 보냅니다.")
                        Menu {
                            PasteButton(payloadType: String.self) { strings in
                                if let text = strings.first { session.sendClipboard(text: text) }
                            }
                            Button("원격 클립보드 복사") {
                                if let text = session.receivedClipboard { UIPasteboard.general.string = text }
                            }.disabled(session.receivedClipboard == nil)
                            Text("클립보드는 Latin-1 문자, 최대 1 MiB를 지원합니다.")
                        } label: { Label("클립보드", systemImage: "doc.on.clipboard") }
                        Menu {
                            ConnectionModeSettings()
                            ColorQualityPicker(selection: $colorQuality)
                                .disabled(DeskPadConnectionMode.restored(from: storedConnectionMode).usesHighPerformance)
                            if session.usingCompatibleColor {
                                Text("검은 화면을 감지해 호환 색상으로 연결했습니다. 전송량이 늘어날 수 있습니다.")
                            }
                            Text("모드를 바꾸면 다시 연결합니다.")
                            Divider()
                            ScrollSensitivityPicker(selection: $scrollSensitivity)
                            Divider()
                            Button("화면에 맞추기") { keyboardController.inputView?.resetViewport() }
                            Button("실제 크기") { keyboardController.inputView?.actualSize() }
                            Button("확대 및 이동 초기화") { keyboardController.inputView?.resetViewport() }
                            Text("핀치 확대 · 세 손가락 화면 이동")
                            Text("두 손가락 스크롤 · 두 손가락 탭 오른쪽 클릭")
                        } label: { Label("화면 보기", systemImage: "arrow.up.left.and.arrow.down.right") }
                        if session.usingCompatibleColor {
                            Text("호환 색상")
                                .font(.caption)
                                .accessibilityLabel("검은 화면 복구를 위해 호환 색상으로 연결됨")
                        }
                        Text("\(session.screenWidth) × \(session.screenHeight)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .task {
                guard !didStart else { return }
                didStart = true
                do {
                    password = try store.password(for: connection)
                    session.connect(to: connection, password: password, colorQuality: colorQuality, connectionMode: .restored(from: storedConnectionMode))
                } catch {
                    session.reportError("저장된 VNC 암호를 읽지 못했습니다: \(error.localizedDescription)")
                }
            }
            .onChange(of: storedConnectionMode) { _, _ in
                keyboardController.dismiss()
                session.connect(to: connection, password: password, colorQuality: colorQuality, connectionMode: .restored(from: storedConnectionMode))
            }
            .onChange(of: colorQuality) { _, _ in
                keyboardController.dismiss()
                session.connect(to: connection, password: password, colorQuality: colorQuality, connectionMode: .restored(from: storedConnectionMode))
            }
            .onChange(of: session.state) { _, newState in
                switch newState {
                case .ended, .failed, .disconnected, .paused, .reconnecting: keyboardController.dismiss()
                default: break
                }
                if case .connected = newState {
                    do {
                        try store.markConnected(connection)
                    } catch {
                        warning = UserMessage(text: "화면은 연결됐지만 최근 연결 시각을 저장하지 못했습니다: \(error.localizedDescription)")
                    }
                }
            }
            .alert(item: $warning) { item in
                Alert(title: Text("DeskPad"), message: Text(item.text), dismissButton: .default(Text("확인")))
            }
            .alert("Mac 서버 신뢰 확인", isPresented: Binding(
                get: { session.hpTrustChallenge != nil },
                set: { if !$0 { session.answerHPTrust(false) } }
            ), presenting: session.hpTrustChallenge) { _ in
                Button("취소", role: .cancel) { session.answerHPTrust(false) }
                Button("이 Mac 신뢰") { session.answerHPTrust(true) }
            } message: { challenge in
                Text("처음 연결하는 고성능 서버입니다. 연결 대상이 맞는지 확인하세요.\n\(challenge.host):\(String(challenge.port))\nSHA-256: \(challenge.fingerprint)")
            }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active { keyboardController.inputView?.releaseAllKeys(); keyboardController.dismiss() }
                switch phase {
                case .active: session.sceneActive()
                case .inactive: session.sceneInactive()
                case .background: session.sceneBackground()
                @unknown default: session.sceneInactive()
                }
            }
            .onDisappear {
                keyboardController.dismiss()
                if scenePhase == .active { session.disconnect() }
            }
        }
    }

    private var sessionDescription: String {
        switch session.state {
        case .failed(let message): message
        case .ended: "화면 공유가 중지되었거나 네트워크 연결이 끊어졌을 수 있습니다. Mac의 화면 공유 설정과 네트워크 상태를 확인한 뒤 다시 연결해 주세요."
        case .connecting, .handshaking, .authenticating, .initializing: "서버 응답을 기다리고 있습니다."
        case .connected: "첫 번째 화면 업데이트를 기다리고 있습니다."
        case .disconnected: "연결이 종료되었습니다."
        case .paused: "앱으로 돌아오면 다시 연결합니다. 닫기를 누르면 연결을 취소합니다."
        case .reconnecting: "네트워크 연결을 복구하고 있습니다. 닫기를 누르면 취소합니다."
        }
    }


}

private extension VNCSessionModel {
    var stateIcon: String {
        switch state {
        case .failed: "exclamationmark.triangle"
        case .connecting, .handshaking, .authenticating, .initializing: "network"
        case .connected: "display"
        case .disconnected, .ended: "wifi.slash"
        case .paused: "pause.circle"
        case .reconnecting: "arrow.clockwise"
        }
    }

}

private struct UserMessage: Identifiable {
    let id = UUID()
    let text: String
}

@Observable
@MainActor
private final class RemoteKeyboardController {
    fileprivate weak var inputView: RemoteDesktopUIView?
    fileprivate var isFocused = false
    fileprivate var inputLanguage: String?
    var inputLanguageLabel: String {
        guard let inputLanguage, !inputLanguage.isEmpty else { return "언어 미확인" }
        let base = inputLanguage.replacingOccurrences(of: "_", with: "-").split(separator: "-").first.map(String.init)
        switch base {
        case "ko": return "한글"
        case "en": return "영문"
        case "emoji": return "이모지"
        default: return Locale.current.localizedString(forIdentifier: inputLanguage) ?? inputLanguage
        }
    }
    func focus() { inputView?.toggleVirtualKeyboard() }
    func dismiss() { _ = inputView?.resignFirstResponder() }
}

private struct RemoteDesktopSurface: UIViewRepresentable {
    let controller: RemoteKeyboardController
    let framebuffer: Data
    let framebufferRevision: UInt64
    let size: CGSize
    let remoteCursor: RFBCursorShape?
    let playback: HighPerformancePlayback?
    let scrollSensitivity: RemoteScrollSensitivity
    let onKey: (UInt32, Bool) -> Void
    let onPointer: (CGPoint, UInt8) -> Void
    final class Coordinator {
        var framebufferRevision: UInt64?
    }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> RemoteDesktopUIView {
        let view = RemoteDesktopUIView()
        view.onFocusChanged = { [weak controller] in controller?.isFocused = $0 }
        view.onInputLanguageChanged = { [weak controller] in
            if controller?.inputLanguage != $0 { controller?.inputLanguage = $0 }
        }
        updateUIView(view, context: context)
        return view
    }
    func updateUIView(_ view: RemoteDesktopUIView, context: Context) {
        if context.coordinator.framebufferRevision != framebufferRevision {
            view.desktopImage = makeImage()
            context.coordinator.framebufferRevision = framebufferRevision
        }
        view.videoLayer = playback?.videoLayer
        view.desktopSize = size
        view.remoteCursor = remoteCursor
        view.scrollSensitivity = scrollSensitivity
        view.onKey = onKey
        view.onPointer = onPointer
        controller.inputView = view
    }
    private func makeImage() -> CGImage? {
        let width = Int(size.width), height = Int(size.height)
        guard width > 0, height > 0, framebuffer.count == width * height * 4,
              let provider = CGDataProvider(data: framebuffer as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    static func dismantleUIView(_ view: RemoteDesktopUIView, coordinator: Coordinator) {
        view.releaseAllKeys()
        _ = view.resignFirstResponder()
    }
}


private struct ColorQualityPicker: View {
    @Binding var selection: VNCColorQuality

    var body: some View {
        Picker("화면 모드", selection: $selection) {
            ForEach(VNCColorQuality.allCases, id: \.self) { quality in
                Text(quality.title).tag(quality)
            }
        }
        Text(selection.detail)
    }
}

private extension VNCColorQuality {
    var title: String {
        switch self {
        case .lowLatency: "초저지연 모드"
        case .fullColor: "무손실 모드"
        }
    }

    var detail: String {
        switch self {
        case .lowLatency: "색상 정밀도를 낮춰 반응 속도를 우선합니다. 사진과 그라데이션 표현이 달라질 수 있으며, 네트워크 상태에 따라 지연이 발생할 수 있습니다."
        case .fullColor: "색상 손실 없이 화면을 전송합니다. 화면 변화가 크면 전송량과 지연이 늘어날 수 있습니다."
        }
    }
}

private struct ScrollSensitivityPicker: View {
    @Binding var selection: RemoteScrollSensitivity

    var body: some View {
        Picker("스크롤 감도", selection: $selection) {
            ForEach(RemoteScrollSensitivity.allCases, id: \.self) { sensitivity in
                Text(sensitivity.title).tag(sensitivity)
            }
        }
        Text("두 손가락 · 트랙패드 · 마우스 휠에 즉시 적용됩니다.")
    }
}
