import Foundation

nonisolated enum AppleHPFailure: Error, LocalizedError, Sendable {
    case unsupportedVideoLayout
    case playbackFailure
    case mediaIdleTimeout
    case videoStalled

    var errorDescription: String? {
        switch self {
        case .unsupportedVideoLayout:
            return "Mac이 지원하지 않는 고성능 화면 구성을 전송했습니다. 일반 화면 공유 모드로 다시 연결해 주세요."
        case .playbackFailure:
            return "고성능 화면 또는 소리를 재생하지 못했습니다. 다시 연결하거나 일반 화면 공유 모드를 사용해 주세요."
        case .videoStalled:
            return "고성능 영상 갱신이 멈췄습니다. 연결을 복구합니다."
        case .mediaIdleTimeout:
            return "Mac의 고성능 미디어 응답 시간이 초과되었습니다. 네트워크 상태를 확인한 뒤 다시 연결해 주세요."
        }
    }
}

/// Callback-safe first terminal cause, recorded before canceling the connection.
nonisolated final class AppleHPTerminalFailure: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: AppleHPFailure?
    func record(_ failure: AppleHPFailure) {
        lock.lock(); defer { lock.unlock() }
        if stored == nil { stored = failure }
    }
    var value: AppleHPFailure? {
        lock.lock(); defer { lock.unlock() }
        return stored
    }
}
