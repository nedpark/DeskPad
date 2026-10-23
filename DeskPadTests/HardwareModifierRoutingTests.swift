import XCTest
import UIKit
@testable import DeskPad

@MainActor final class HardwareModifierRoutingTests: XCTestCase {
    func testShiftEdgesReachUIKitWhileRemoteSelectionRemainsIntact() {
        let parent = PressObserverView()
        let view = RemoteDesktopUIView(); parent.addSubview(view)
        var remote: [String] = []
        view.onKey = { remote.append("\($0):\($1)") }
        let shift = StubPress(.keyboardLeftShift, modifiers: .shift)
        let arrow = StubPress(.keyboardRightArrow, modifiers: .shift)
        view.pressesBegan([shift], with: nil)
        view.pressesBegan([arrow], with: nil)
        view.pressesEnded([arrow], with: nil)
        view.pressesEnded([shift], with: nil)
        XCTAssertEqual(parent.began, [.keyboardLeftShift])
        XCTAssertEqual(parent.ended, [.keyboardLeftShift])
        XCTAssertEqual(remote, ["65505:true", "65363:true", "65363:false", "65505:false"])
        view.releaseAllKeys()
        XCTAssertEqual(remote.count, 4, "Shift must not remain remotely pressed")
    }
    func testCancelledShiftReachesUIKitCancellationAndReleasesRemoteKey() {
        let parent = PressObserverView()
        let view = RemoteDesktopUIView(); parent.addSubview(view)
        var remote: [Bool] = []
        view.onKey = { _, down in remote.append(down) }
        let shift = StubPress(.keyboardRightShift, modifiers: .shift)
        view.pressesBegan([shift], with: nil)
        view.pressesCancelled([shift], with: nil)
        XCTAssertEqual(parent.cancelled, [.keyboardRightShift])
        XCTAssertTrue(parent.ended.isEmpty)
        XCTAssertEqual(remote, [true, false])
        view.releaseAllKeys(); XCTAssertEqual(remote, [true, false])
    }
}
@MainActor private final class PressObserverView: UIView {
    var began: [UIKeyboardHIDUsage] = []
    var ended: [UIKeyboardHIDUsage] = []
    var cancelled: [UIKeyboardHIDUsage] = []
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) { began += presses.compactMap { $0.key?.keyCode } }
    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) { ended += presses.compactMap { $0.key?.keyCode } }
    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) { cancelled += presses.compactMap { $0.key?.keyCode } }
}
@MainActor private final class StubKey: UIKey {
    let usage: UIKeyboardHIDUsage
    let flags: UIKeyModifierFlags
    init(_ usage: UIKeyboardHIDUsage, modifiers: UIKeyModifierFlags) { self.usage = usage; flags = modifiers; super.init() }
    required init?(coder: NSCoder) { fatalError("unused") }
    override var keyCode: UIKeyboardHIDUsage { usage }
    override var modifierFlags: UIKeyModifierFlags { flags }
    override var characters: String { "" }
    override var charactersIgnoringModifiers: String { "" }
}
@MainActor private final class StubPress: UIPress {
    let stubKey: StubKey
    init(_ usage: UIKeyboardHIDUsage, modifiers: UIKeyModifierFlags) { stubKey = StubKey(usage, modifiers: modifiers); super.init() }
    override var key: UIKey? { stubKey }
}
