import XCTest
@testable import DeskPad

@MainActor
final class RemoteInputTests: XCTestCase {
    func testDefaultScrollSensitivityDoublesPreviousRate() {
        let view = RemoteDesktopUIView()
        let pan = StubPan()
        pan.testState = .began
        pan.testTranslation = CGPoint(x: 0, y: 20)
        var masks: [UInt8] = []
        view.onPointer = { _, mask in masks.append(mask) }
        _ = view.perform(NSSelectorFromString("handleScroll:"), with: pan)
        XCTAssertEqual(masks, [8, 0, 8, 0])
    }

    func testScrollSensitivityChoicesPreserveDirectionAndReleaseWheelButtons() {
        for (sensitivity, count) in [(RemoteScrollSensitivity.half, 1), (.normal, 2), (.double, 4), (.triple, 6)] {
            let view = RemoteDesktopUIView()
            view.scrollSensitivity = sensitivity
            let pan = StubPan()
            pan.testState = .began
            pan.testTranslation = CGPoint(x: 0, y: -40)
            var masks: [UInt8] = []
            view.onPointer = { _, mask in masks.append(mask) }
            _ = view.perform(NSSelectorFromString("handleScroll:"), with: pan)
            XCTAssertEqual(masks, Array(repeating: [UInt8(16), 0], count: count).flatMap { $0 })
        }
    }

    func testScrollFractionsResetBetweenGesturesAndSensitivityChanges() {
        let view = RemoteDesktopUIView()
        let pan = StubPan()
        var masks: [UInt8] = []
        view.onPointer = { _, mask in masks.append(mask) }
        func scroll(_ state: UIGestureRecognizer.State, _ delta: CGFloat) {
            pan.testState = state
            pan.testTranslation = CGPoint(x: 0, y: delta)
            _ = view.perform(NSSelectorFromString("handleScroll:"), with: pan)
        }
        scroll(.began, 6)
        scroll(.changed, 4)
        XCTAssertEqual(masks, [8, 0], "Small deltas accumulate within a gesture")
        masks.removeAll()
        for terminal in [UIGestureRecognizer.State.ended, .cancelled, .failed] {
            scroll(.began, 6)
            scroll(terminal, 0)
            scroll(.began, 4)
            XCTAssertTrue(masks.isEmpty)
        }
        view.scrollSensitivity = .normal
        scroll(.changed, 16)
        XCTAssertTrue(masks.isEmpty, "Changing sensitivity discards old fractional movement")
        scroll(.changed, 4)
        XCTAssertEqual(masks, [8, 0])
    }

    func testScrollRejectsNonFiniteAndBoundsHugeInput() {
        let view = RemoteDesktopUIView()
        let pan = StubPan()
        pan.testState = .changed
        var masks: [UInt8] = []
        view.onPointer = { _, mask in masks.append(mask) }
        for delta in [CGFloat.nan, .infinity, -.infinity] {
            pan.testTranslation = CGPoint(x: 0, y: delta)
            _ = view.perform(NSSelectorFromString("handleScroll:"), with: pan)
        }
        XCTAssertTrue(masks.isEmpty)
        pan.testTranslation = CGPoint(x: 0, y: CGFloat.greatestFiniteMagnitude)
        _ = view.perform(NSSelectorFromString("handleScroll:"), with: pan)
        XCTAssertEqual(masks.count, 64)
    }

    func testIndependentScrollSourcesDoNotShareRemainders() {
        let view = RemoteDesktopUIView()
        let direct = StubPan(), indirect = StubPan()
        var masks: [UInt8] = []
        view.onPointer = { _, mask in masks.append(mask) }
        for pan in [direct, indirect] {
            pan.testState = .began
            pan.testTranslation = CGPoint(x: 0, y: 6)
            _ = view.perform(NSSelectorFromString("handleScroll:"), with: pan)
        }
        XCTAssertTrue(masks.isEmpty)
        direct.testState = .changed
        direct.testTranslation = CGPoint(x: 0, y: 4)
        _ = view.perform(NSSelectorFromString("handleScroll:"), with: direct)
        XCTAssertEqual(masks, [8, 0])
    }

    func testRemoteSurfaceUsesNativePointerWithoutAdditionalMarker() {
        let view = RemoteDesktopUIView(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        view.desktopSize = CGSize(width: 400, height: 200)
        let hover = StubHover()
        hover.testLocation = CGPoint(x: 150, y: 125)
        hover.testState = .changed
        var sent: CGPoint?
        view.onPointer = { point, _ in sent = point }
        _ = view.perform(NSSelectorFromString("handleHover:"), with: hover)
        XCTAssertEqual(sent, CGPoint(x: 300, y: 150))
        XCTAssertTrue(view.interactions.contains { $0 is UIPointerInteraction })
        XCTAssertFalse(view.layer.sublayers?.contains { $0.name == "local-input-pointer" } ?? false)
    }

    func testNativeArrowDoesNotDrawDuplicateAndCursorUpdatesDoNotRepaintDesktop() throws {
        let view = RemoteDesktopUIView(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        view.desktopSize = CGSize(width: 200, height: 200)
        view.layer.displayIfNeeded()
        view.remoteCursor = cursor(width: 3, height: 3, hotspotX: 0, hotspotY: 0, mask: [1,0,0, 1,1,0, 1,1,1])
        XCTAssertFalse(view.layer.needsDisplay())
        let hover = StubHover()
        hover.testLocation = CGPoint(x: 80, y: 90)
        hover.testState = .changed
        _ = view.perform(NSSelectorFromString("handleHover:"), with: hover)
        let layer = try XCTUnwrap(view.layer.sublayers?.first { $0.name == "remote-cursor" })
        XCTAssertTrue(layer.isHidden, "Native pointer must be the only pointer during hardware hover")
        XCTAssertNotNil(RemoteCursorPresentation(try XCTUnwrap(view.remoteCursor)).nativeShape)
        XCTAssertFalse(view.layer.needsDisplay())
    }

    func testBitmapFallbackAlignsHotspotAndHidesOnExitAndReset() throws {
        let view = RemoteDesktopUIView(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        view.desktopSize = CGSize(width: 400, height: 200)
        let shape = cursor(width: 3, height: 3, hotspotX: 1, hotspotY: 2, mask: Array(repeating: 1, count: 9))
        view.remoteCursor = shape
        XCTAssertNil(RemoteCursorPresentation(shape).nativeShape)
        let hover = StubHover()
        hover.testLocation = CGPoint(x: 150, y: 125)
        hover.testState = .changed
        _ = view.perform(NSSelectorFromString("handleHover:"), with: hover)
        let layer = try XCTUnwrap(view.layer.sublayers?.first { $0.name == "remote-cursor" })
        XCTAssertFalse(layer.isHidden)
        XCTAssertEqual(layer.position, CGPoint(x: 149, y: 123))
        let interaction = try XCTUnwrap(view.interactions.first { $0 is UIPointerInteraction } as? UIPointerInteraction)
        XCTAssertNotNil(view.pointerInteraction(interaction, styleFor: UIPointerRegion(rect: view.bounds)))
        view.actualSize()
        XCTAssertEqual(layer.position, CGPoint(x: 199, y: 148))
        hover.testState = .ended
        _ = view.perform(NSSelectorFromString("handleHover:"), with: hover)
        XCTAssertTrue(layer.isHidden)
        hover.testState = .changed
        _ = view.perform(NSSelectorFromString("handleHover:"), with: hover)
        view.remoteCursor = nil
        XCTAssertTrue(layer.isHidden)
        XCTAssertNil(view.pointerInteraction(interaction, styleFor: UIPointerRegion(rect: view.bounds)))
    }

    func testCenteredTextBeamUsesNativePointerAndTransparentCursorStaysHidden() {
        var mask = Array(repeating: UInt8(0), count: 5 * 11)
        for x in 0..<5 { mask[x] = 1; mask[50 + x] = 1 }
        for y in 1..<10 { mask[y * 5 + 2] = 1 }
        let beam = cursor(width: 5, height: 11, hotspotX: 2, hotspotY: 5, mask: mask)
        XCTAssertNotNil(RemoteCursorPresentation(beam).nativeShape)
        let offCenter = cursor(width: 5, height: 11, hotspotX: 0, hotspotY: 5, mask: mask)
        XCTAssertNil(RemoteCursorPresentation(offCenter).nativeShape)
        let transparent = cursor(width: 5, height: 11, hotspotX: 0, hotspotY: 0, mask: Array(repeating: 0, count: 55))
        XCTAssertTrue(RemoteCursorPresentation(transparent).isHidden)
        XCTAssertNil(RemoteCursorPresentation(transparent).nativeShape)
    }

    func testColoredCursorRetainsBitmapAndEmptyCursorHidesSystemPointer() throws {
        let colored = RFBCursorShape(width: 1, height: 1, hotspotX: 0, hotspotY: 0,
                                     rgba: Data([255, 0, 0, 255]))
        let presentation = RemoteCursorPresentation(colored)
        XCTAssertNil(presentation.nativeShape, "Color conveys remote state and must not become a monochrome silhouette")
        XCTAssertNotNil(presentation.image)
        let view = RemoteDesktopUIView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        view.remoteCursor = cursor(width: 0, height: 0, hotspotX: 0, hotspotY: 0, mask: [])
        let interaction = try XCTUnwrap(view.interactions.first { $0 is UIPointerInteraction } as? UIPointerInteraction)
        XCTAssertNotNil(view.pointerInteraction(interaction, styleFor: UIPointerRegion(rect: view.bounds)))
        XCTAssertTrue(RemoteCursorPresentation(try XCTUnwrap(view.remoteCursor)).isHidden)
    }

    func testLargeRemoteCursorRetainsLogicalPointSizeAcrossViewportChanges() throws {
        let shape = cursor(width: 128, height: 64, hotspotX: 8, hotspotY: 4, mask: Array(repeating: 1, count: 128 * 64))
        XCTAssertEqual(RemoteCursorPresentation(shape).size, CGSize(width: 128, height: 64))
        let view = RemoteDesktopUIView(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        view.desktopSize = CGSize(width: 400, height: 200)
        view.remoteCursor = shape
        let hover = StubHover()
        hover.testLocation = CGPoint(x: 100, y: 100)
        hover.testState = .changed
        _ = view.perform(NSSelectorFromString("handleHover:"), with: hover)
        let layer = try XCTUnwrap(view.layer.sublayers?.first { $0.name == "remote-cursor" })
        XCTAssertEqual(layer.bounds.size, CGSize(width: 128, height: 64))
        XCTAssertEqual(layer.position, CGPoint(x: 92, y: 96))
        view.actualSize()
        XCTAssertEqual(layer.bounds.size, CGSize(width: 128, height: 64))
        XCTAssertEqual(layer.position, CGPoint(x: 92, y: 96))
        view.resetViewport()
        view.bounds.size = CGSize(width: 400, height: 400)
        view.layoutSubviews()
        XCTAssertEqual(layer.bounds.size, CGSize(width: 128, height: 64))
        XCTAssertEqual(layer.position, CGPoint(x: 192, y: 196))
    }

    func testNativeShapeKeepsLogicalSizeWithoutThirtyTwoPointCap() throws {
        let shape = cursor(width: 64, height: 64, hotspotX: 0, hotspotY: 0, mask: Array(repeating: 1, count: 64 * 64))
        let presentation = RemoteCursorPresentation(shape)
        XCTAssertEqual(presentation.size, CGSize(width: 64, height: 64))
        guard case .path(let path) = try XCTUnwrap(presentation.nativeShape) else {
            return XCTFail("Top-left hotspot uses native path")
        }
        XCTAssertEqual(path.bounds.size, CGSize(width: 64, height: 64))
    }

    func testTouchShowsActualRemoteCursorWithoutDecorativeRing() throws {
        let view = RemoteDesktopUIView(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        view.desktopSize = CGSize(width: 200, height: 200)
        view.remoteCursor = cursor(width: 2, height: 2, hotspotX: 0, hotspotY: 0, mask: [1,0,1,1])
        let pan = StubPan()
        pan.testLocation = CGPoint(x: 90, y: 100)
        pan.testState = .began
        _ = view.perform(NSSelectorFromString("handleDrag:"), with: pan)
        let layer = try XCTUnwrap(view.layer.sublayers?.first { $0.name == "remote-cursor" })
        XCTAssertFalse(layer.isHidden)
        XCTAssertNotNil(layer.contents)
        XCTAssertNil(layer.animationKeys())
        view.releaseAllKeys()
        XCTAssertTrue(layer.isHidden)
    }

    private func cursor(width: Int, height: Int, hotspotX: Int, hotspotY: Int, mask: [UInt8]) -> RFBCursorShape {
        RFBCursorShape(width: width, height: height, hotspotX: hotspotX, hotspotY: hotspotY,
                       rgba: Data(mask.flatMap { [UInt8(255), 255, 255, $0 == 0 ? 0 : 255] }))
    }

    func testSparseDragPressesOriginalPointAndMovesBeforeRelease() {
        let view = RemoteDesktopUIView(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        view.desktopSize = CGSize(width: 200, height: 200)
        var events: [(CGPoint, UInt8)] = []
        view.onPointer = { events.append(($0, $1)) }
        let pan = StubPan()
        pan.testLocation = CGPoint(x: 110, y: 68)
        pan.testTranslation = CGPoint(x: 10, y: 12.6)
        pan.testState = .began
        _ = view.perform(NSSelectorFromString("handleDrag:"), with: pan)
        pan.testLocation = CGPoint(x: 120, y: 80)
        pan.testState = .ended
        _ = view.perform(NSSelectorFromString("handleDrag:"), with: pan)
        XCTAssertEqual(events.map { $0.1 }, [0, 1, 1, 1, 0])
        XCTAssertEqual(events.first?.0.x ?? -1, 100, accuracy: 0.001)
        XCTAssertEqual(events.first?.0.y ?? -1, 55.4, accuracy: 0.001)
        XCTAssertEqual(events.dropFirst().first?.0, events.first?.0)
        XCTAssertEqual(events.suffix(2).map { $0.0 }, [CGPoint(x: 120, y: 80), CGPoint(x: 120, y: 80)])
    }

    func testDragOriginIsMappedThroughViewportAndCancellationReleases() {
        let view = RemoteDesktopUIView(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        view.desktopSize = CGSize(width: 400, height: 200)
        view.actualSize()
        var events: [(CGPoint, UInt8)] = []
        view.onPointer = { events.append(($0, $1)) }
        let pan = StubPan()
        pan.testLocation = CGPoint(x: 130, y: 120)
        pan.testTranslation = CGPoint(x: 30, y: 20)
        pan.testState = .began
        _ = view.perform(NSSelectorFromString("handleDrag:"), with: pan)
        XCTAssertEqual(events.first?.0, CGPoint(x: 200, y: 100))
        XCTAssertEqual(events.last?.0.x ?? -1, 230, accuracy: 0.001)
        XCTAssertEqual(events.last?.0.y ?? -1, 120, accuracy: 0.001)
        events.removeAll()
        pan.testState = .cancelled
        _ = view.perform(NSSelectorFromString("handleDrag:"), with: pan)
        XCTAssertEqual(events.map { $0.1 }, [0])
        view.releaseAllKeys()
        XCTAssertEqual(events.count, 1)
    }

    func testDragAfterBlurDoesNotPressAgain() {
        let view = RemoteDesktopUIView(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        view.desktopSize = CGSize(width: 200, height: 200)
        var masks: [UInt8] = []
        view.onPointer = { masks.append($1) }
        let pan = StubPan()
        pan.testLocation = CGPoint(x: 100, y: 100)
        pan.testState = .began
        _ = view.perform(NSSelectorFromString("handleDrag:"), with: pan)
        _ = view.resignFirstResponder()
        masks.removeAll()
        pan.testState = .changed
        _ = view.perform(NSSelectorFromString("handleDrag:"), with: pan)
        pan.testState = .ended
        _ = view.perform(NSSelectorFromString("handleDrag:"), with: pan)
        XCTAssertFalse(masks.contains { $0 != 0 })
    }

    func testSecondaryMouseClickCannotRecognizeDirectTouch() throws {
        let taps = RemoteDesktopUIView().gestureRecognizers?.compactMap { $0 as? UITapGestureRecognizer } ?? []
        let secondary = try XCTUnwrap(taps.first { $0.buttonMaskRequired == .secondary })
        XCTAssertEqual(secondary.allowedTouchTypes, [NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)])
    }

    func testSingleTapRequiresPrimaryMouseButton() throws {
        let taps = RemoteDesktopUIView().gestureRecognizers?.compactMap { $0 as? UITapGestureRecognizer } ?? []
        let primary = try XCTUnwrap(taps.first { $0.numberOfTouchesRequired == 1 && $0.buttonMaskRequired != .secondary })
        XCTAssertEqual(primary.buttonMaskRequired, .primary)
        XCTAssertTrue(primary.allowedTouchTypes.contains(NSNumber(value: UITouch.TouchType.direct.rawValue)))
    }

    func testTwoFingerRightClickRemainsDirectTouchOnly() throws {
        let taps = RemoteDesktopUIView().gestureRecognizers?.compactMap { $0 as? UITapGestureRecognizer } ?? []
        let twoFinger = try XCTUnwrap(taps.first { $0.numberOfTouchesRequired == 2 })
        XCTAssertEqual(twoFinger.allowedTouchTypes, [NSNumber(value: UITouch.TouchType.direct.rawValue)])
    }

    func testCompositionDoesNotSendUntilCommitAndEmitsEveryScalar() {
        let view = RemoteDesktopUIView()
        var keys: [UInt32] = []
        view.onKey = { if $1 { keys.append($0) } }
        view.setMarkedText("한", selectedRange: NSRange(location: 1, length: 0))
        XCTAssertTrue(keys.isEmpty)
        view.insertText("한😀")
        XCTAssertEqual(keys, [0x0100D55C, 0x0101F600])
        view.unmarkText()
        XCTAssertEqual(keys.count, 2)
    }
    func testBackspaceDuringCompositionIsLocal() {
        let view = RemoteDesktopUIView()
        var keys: [UInt32] = []
        view.onKey = { if $1 { keys.append($0) } }
        view.setMarkedText("😀", selectedRange: NSRange(location: 2, length: 0))
        XCTAssertFalse(view.handlesDirectly(code: .keyboardDeleteOrBackspace, modifiers: []))
        view.deleteBackward()
        view.unmarkText()
        XCTAssertTrue(keys.isEmpty)
        XCTAssertFalse(view.handlesDirectly(code: .keyboardDeleteOrBackspace, modifiers: []))
        view.deleteBackward()
        XCTAssertEqual(keys, [0xff08])
    }
    func testNavigationAndClickInvalidateUnmarkedInputContext() {
        let view = RemoteDesktopUIView()
        let delegate = InputBoundaryDelegate()
        view.inputDelegate = delegate
        view.keyDown(code: .keyboardLeftShift, keysym: 0xffe1)
        XCTAssertEqual(delegate.changes, 0)
        view.keyDown(code: .keyboardLeftArrow, keysym: 0xff51)
        XCTAssertEqual(delegate.changes, 1)
        view.pointer(.zero)
        view.pointer(.zero, mask: 8) // Wheel events must not reset composition.
        view.pointer(.zero, mask: 0)
        XCTAssertEqual(delegate.changes, 1)
        view.pointer(.zero, mask: 1)
        XCTAssertEqual(delegate.changes, 2)
        view.pointer(CGPoint(x: 1, y: 1), mask: 1)
        view.pointer(.zero, mask: 0)
        XCTAssertEqual(delegate.changes, 2)
    }

    func testMarkedCompositionCommitsBeforePointerButtonDown() {
        let view = RemoteDesktopUIView()
        var events: [String] = []
        view.onKey = { events.append("key:\($0):\($1)") }
        view.onPointer = { _, mask in events.append("pointer:\(mask)") }
        view.setMarkedText("때", selectedRange: NSRange(location: 1, length: 0))
        view.pointer(.zero, mask: 1)
        XCTAssertEqual(events, ["key:16823628:true", "key:16823628:false", "pointer:1"])
    }

    func testHardwareKoreanBackspaceUsesUIKitWithoutMarkedText() {
        let view = RemoteDesktopUIView()
        XCTAssertNil(view.markedTextRange)
        XCTAssertFalse(view.handlesDirectly(code: .keyboardDeleteOrBackspace, modifiers: []))
        XCTAssertFalse(view.handlesDirectly(code: .keyboardDeleteOrBackspace, modifiers: [.shift]))
        for modifier: UIKeyModifierFlags in [.control, .alternate, .command] {
            XCTAssertTrue(view.handlesDirectly(code: .keyboardDeleteOrBackspace, modifiers: modifier))
        }
        var events: [String] = []
        view.onKey = { events.append("\($0):\($1)") }
        // UIKit's observed hardware Korean replacement sequence: 때 → ㄸ → 때.
        view.insertText("때")
        view.deleteBackward()
        view.insertText("ㄸ")
        view.deleteBackward()
        view.insertText("때")
        let symbols: [UInt32] = [0x0100B54C, 0xFF08, 0x01003138, 0xFF08, 0x0100B54C]
        XCTAssertEqual(events, symbols.flatMap { ["\($0):true", "\($0):false"] })
    }

    func testUIKitBackspaceStillDeletesRemoteContentWithoutLocalText() {
        let view = RemoteDesktopUIView()
        var events: [String] = []
        view.onKey = { events.append("\($0):\($1)") }
        XCTAssertTrue(view.hasText)
        view.deleteBackward()
        view.insertText("a")
        view.deleteBackward()
        XCTAssertEqual(events, ["65288:true", "65288:false", "97:true", "97:false", "65288:true", "65288:false"])
    }

    func testShortcutCommitsCompositionBeforePressingControl() {
        let view = RemoteDesktopUIView()
        var events: [String] = []
        view.onKey = { events.append("\($0):\($1)") }
        view.setMarkedText("한", selectedRange: NSRange(location: 1, length: 0))
        view.keyDown(code: .keyboardLeftControl, keysym: 0xffe3)
        XCTAssertEqual(events, ["16831836:true", "16831836:false", "65507:true"])
        XCTAssertNil(view.markedTextRange)
    }
    func testViewportMappingClampsAndResetRestoresFit() {
        let view = RemoteDesktopUIView(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        view.desktopSize = CGSize(width: 400, height: 200)
        XCTAssertEqual(view.viewPointToDesktopPoint(CGPoint(x: 100, y: 100)), CGPoint(x: 200, y: 100))
        XCTAssertEqual(view.viewPointToDesktopPoint(CGPoint(x: -100, y: -100)), .zero)
        view.actualSize()
        XCTAssertEqual(view.viewPointToDesktopPoint(CGPoint(x: 0, y: 100)), CGPoint(x: 100, y: 100))
        view.resetViewport()
        XCTAssertEqual(view.viewPointToDesktopPoint(CGPoint(x: 100, y: 100)), CGPoint(x: 200, y: 100))
    }
    func testBlurSendsUpForHeldModifiersAndShortcut() {
        let view = RemoteDesktopUIView()
        var events: [String] = []
        view.onKey = { events.append("\($0):\($1)") }
        XCTAssertTrue(view.handlesDirectly(code: .keyboardC, modifiers: [.command]))
        XCTAssertFalse(view.handlesDirectly(code: .keyboardC, modifiers: []))
        view.keyDown(code: .keyboardLeftGUI, keysym: 0xffeb)
        view.keyDown(code: .keyboardC, keysym: 99)
        _ = view.resignFirstResponder()
        XCTAssertEqual(Set(events.filter { $0.hasSuffix(":false") }), ["65515:false", "99:false"])
        view.releaseAllKeys()
        XCTAssertEqual(events.count, 4)
    }
}

@MainActor
private final class StubPan: UIPanGestureRecognizer {
    var testState: UIGestureRecognizer.State = .possible
    var testLocation = CGPoint.zero
    var testTranslation = CGPoint.zero
    override var state: UIGestureRecognizer.State { get { testState } set { testState = newValue } }
    override func location(in view: UIView?) -> CGPoint { testLocation }
    override func translation(in view: UIView?) -> CGPoint { testTranslation }
}

@MainActor
private final class StubHover: UIHoverGestureRecognizer {
    var testState: UIGestureRecognizer.State = .possible
    var testLocation = CGPoint.zero
    override var state: UIGestureRecognizer.State { get { testState } set { testState = newValue } }
    override func location(in view: UIView?) -> CGPoint { testLocation }
}

@MainActor
private final class InputBoundaryDelegate: NSObject, UITextInputDelegate {
    var changes = 0
    func conversationContext(_ context: UIConversationContext?, didChange textInput: (any UITextInput)?) {}
    func selectionWillChange(_ textInput: (any UITextInput)?) {}
    func selectionDidChange(_ textInput: (any UITextInput)?) {}
    func textWillChange(_ textInput: (any UITextInput)?) {}
    func textDidChange(_ textInput: (any UITextInput)?) { changes += 1 }
}
