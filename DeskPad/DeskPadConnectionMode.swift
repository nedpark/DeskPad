import Foundation

/// Independent of VNCColorQuality: selecting HP never overwrites the user's
/// lossless/low-latency preference for the standard connection path.
enum DeskPadConnectionMode: String, CaseIterable, Identifiable, Sendable {
    case standard
    case highPerformanceExperimental

    static let storageKey = "deskpadConnectionMode"
    static let defaultMode = Self.standard
    var id: String { rawValue }
    var title: String {
        switch self {
        case .standard: "기본 화면 공유"
        case .highPerformanceExperimental: "고성능 화면·소리 공유 (실험)"
        }
    }
    var usesHighPerformance: Bool { self == .highPerformanceExperimental }
    var detail: String {
        switch self {
        case .standard: "무손실 또는 초저지연 화면 모드를 사용합니다. 소리는 공유되지 않습니다."
        case .highPerformanceExperimental:
            "Mac 화면을 그대로 보여주고 소리를 함께 전송합니다. Mac의 해상도를 바꾸거나 화면을 가리지 않습니다. 처음 연결할 때 서버 신뢰를 확인합니다. 지원하지 않는 영상 구성은 연결을 종료합니다."
        }
    }
    /// Unknown stored values fail back to the ordinary VNC path, never HP.
    static func restored(from rawValue: String?) -> Self {
        rawValue.flatMap(Self.init(rawValue:)) ?? .standard
    }
}
