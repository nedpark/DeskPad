import UIKit
import AVFoundation
#if DEBUG
import os
#endif

// MARK: - Text Input Helpers

/// Minimal UITextPosition subclass for UITextInput conformance.
private class SimpleTextPosition: UITextPosition {
    let index: Int
    init(_ index: Int) { self.index = index }
}

/// Minimal UITextRange subclass for UITextInput conformance.
private class SimpleTextRange: UITextRange {
    private let _start: SimpleTextPosition
    private let _end: SimpleTextPosition

    override var start: UITextPosition { _start }
    override var end: UITextPosition { _end }
    override var isEmpty: Bool { _start.index >= _end.index }

    init(start: Int, end: Int) {
        _start = SimpleTextPosition(start)
        _end = SimpleTextPosition(end)
    }
}

enum RemoteScrollSensitivity: String, CaseIterable {
    case half, normal, double, triple

    var multiplier: CGFloat {
        switch self {
        case .half: 0.5
        case .normal: 1
        case .double: 2
        case .triple: 3
        }
    }

    var title: String {
        switch self {
        case .half: "0.5배"
        case .normal: "1배 (기존 속도)"
        case .double: "2배 (기본)"
        case .triple: "3배"
        }
    }
}

final class RemoteDesktopUIView: UIView {
    var videoLayer: AVSampleBufferDisplayLayer? {
        didSet {
            guard videoLayer !== oldValue else { return }
            oldValue?.removeFromSuperlayer()
            if let videoLayer { videoLayer.videoGravity = .resize; layer.insertSublayer(videoLayer, at: 0) }
            setNeedsLayout()
        }
    }
    private func updateVideoFrame() {
        guard let videoLayer else { return }
        let rect = calculateDisplayRect()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        videoLayer.frame = CGRect(x: rect.minX * zoomScale + panOffset.x, y: rect.minY * zoomScale + panOffset.y,
                                  width: rect.width * zoomScale, height: rect.height * zoomScale)
        CATransaction.commit()
    }


    #if DEBUG
    private var diagnosticCallbackCount = 0
    private func recordInputCallback(_ kind: String) {
        diagnosticCallbackCount += 1
        VNCControlDiagnostics.logger.notice("ui callback kind=\(kind, privacy: .public) count=\(self.diagnosticCallbackCount)")
    }
    private func recordCompositionCallback(_ kind: String, text: String?) {
        recordInputCallback(kind)
        let utf16Length = text?.utf16.count ?? 0
        let scalarCount = text?.unicodeScalars.count ?? 0
        let asciiCount = text?.unicodeScalars.filter { $0.isASCII }.count ?? 0
        let nonASCIICount = scalarCount - asciiCount
        let language = textInputMode?.primaryLanguage ?? "unknown"
        VNCControlDiagnostics.logger.notice("ui composition kind=\(kind, privacy: .public) utf16_length=\(utf16Length) ascii_scalars=\(asciiCount) nonascii_scalars=\(nonASCIICount) input_language=\(language, privacy: .public)")
    }
    #endif

    var onKey: ((UInt32, Bool) -> Void)?
    var onPointer: ((CGPoint, UInt8) -> Void)?
    var onFocusChanged: ((Bool) -> Void)?
    var onInputLanguageChanged: ((String?) -> Void)?
    @objc private func inputLanguageDidChange() {
        guard isFirstResponder else { return }
        onInputLanguageChanged?(textInputMode?.primaryLanguage)
    }
    private func observeInputLanguage() {
        NotificationCenter.default.addObserver(self, selector: #selector(inputLanguageDidChange),
            name: UITextInputMode.currentInputModeDidChangeNotification, object: nil)
    }
    deinit { NotificationCenter.default.removeObserver(self) }
    private var pressedKeys: [UIKeyboardHIDUsage: UInt32] = [:]
    private var pointerMask: UInt8 = 0
    private var pointerPoint: CGPoint = .zero
    var scrollSensitivity: RemoteScrollSensitivity = .double {
        didSet {
            if scrollSensitivity != oldValue { scrollRemainders.removeAll() }
        }
    }
    // Direct touch and trackpad events must not consume each other's fractions.
    private var scrollRemainders: [ObjectIdentifier: CGFloat] = [:]

    /// The native pointer is preferred; an exact bitmap is used only when UIKit
    /// cannot represent a server cursor's hotspot. Never draw both at once.
    var remoteCursor: RFBCursorShape? {
        didSet {
            guard remoteCursor != oldValue else { return }
            cursorPresentation = remoteCursor.map(RemoteCursorPresentation.init)
            cursorLayer.contents = cursorPresentation?.image
            pointerInteraction.invalidate()
            updatePointerMarker()
        }
    }
    private var cursorPresentation: RemoteCursorPresentation?
    private let cursorLayer = CALayer()
    private lazy var pointerInteraction = UIPointerInteraction(delegate: self)
    private var hasPointerPosition = false
    private var hardwarePointerInside = false

    func resetViewport() { zoomScale = 1; panOffset = .zero; pointerInteraction.invalidate(); updatePointerMarker(); setNeedsDisplay() }
    func actualSize() {
        guard desktopSize.width > 0, bounds.width > 0 else { return }
        zoomScale = desktopSize.width / calculateDisplayRect().width
        panOffset = CGPoint(x: bounds.midX * (1 - zoomScale), y: bounds.midY * (1 - zoomScale))
        pointerInteraction.invalidate()
        updatePointerMarker()
        setNeedsDisplay()
    }
    func releaseAllKeys() {
        for key in pressedKeys.values { onKey?(key, false) }
        pressedKeys.removeAll()
        if pointerMask != 0 { pointerMask = 0; onPointer?(pointerPoint, 0) }
        hidePointerMarker()
        updateComposition(nil, selection: NSRange(location: 0, length: 0))
    }
    func keyDown(code: UIKeyboardHIDUsage, keysym: UInt32) {
        // Commit before a shortcut modifier reaches the server, while Shift remains
        // available to the local IME for composing shifted characters.
        // Hardware Korean retains UIKit context even when markedText is nil.
        if code != .keyboardLeftShift, code != .keyboardRightShift {
            unmarkText()
        }
        pressedKeys[code] = keysym; onKey?(keysym, true)
    }
    private func sendText(_ text: String) {
        for scalar in text.unicodeScalars {
            let key = scalar.value == 10 ? 0xff0d : scalar.value == 9 ? 0xff09 : scalar.value <= 255 ? scalar.value : 0x01000000 | scalar.value
            onKey?(key, true); onKey?(key, false)
        }
    }
    func pointer(_ point: CGPoint, mask: UInt8? = nil) {
        // A new physical button press changes the remote caret; hover and wheel do not.
        if let mask, mask & 0x07 & ~pointerMask != 0 {
            unmarkText()
        }
        pointerPoint = point
        if let mask { pointerMask = mask }
        hasPointerPosition = true
        updatePointerMarker()
        onPointer?(point, pointerMask)
    }
    override func resignFirstResponder() -> Bool {
        releaseAllKeys()
        wantsVirtualKeyboard = false
        let result = super.resignFirstResponder()
        if result { onFocusChanged?(false); onInputLanguageChanged?(nil) }
        return result
    }
    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result { onFocusChanged?(wantsVirtualKeyboard); inputLanguageDidChange() }
        return result
    }

    /// The remote desktop image to render
    var desktopImage: CGImage? {
        didSet { if desktopImage == nil { hidePointerMarker() }; setNeedsDisplay() }
    }

    /// Remote desktop pixel dimensions for coordinate mapping
    var desktopSize: CGSize = .zero {
        didSet { if desktopSize != oldValue { hidePointerMarker(); pointerInteraction.invalidate() } }
    }

    // Zoom/pan state
    private var zoomScale: CGFloat = 1.0
    private var panOffset: CGPoint = .zero

    // Virtual keyboard state
    private var wantsVirtualKeyboard = false
    private static let emptyInputView = UIView(frame: .zero)

    // IME composition state (UITextInput)
    private var _markedText: String?
    // UITextInput positions and NSRange selections are UTF-16 offsets.
    private var _markedSelection = NSRange(location: 0, length: 0)
    private weak var _inputDelegate: (any UITextInputDelegate)?
    private lazy var _tokenizer: UITextInputStringTokenizer = UITextInputStringTokenizer(textInput: self)

    /// Recognizer for trackpad/mouse scroll events (used by gesture delegate)
    private var indirectScrollRecognizer: UIGestureRecognizer?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        isMultipleTouchEnabled = true
        setupPointerMarker()
        setupGestureRecognizers()
        observeInputLanguage()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        backgroundColor = .black
        isMultipleTouchEnabled = true
        setupPointerMarker()
        setupGestureRecognizers()
        observeInputLanguage()
    }

    override var canBecomeFirstResponder: Bool { true }

    /// Returns an empty view to suppress the virtual keyboard, or nil to show it.
    override var inputView: UIView? {
        wantsVirtualKeyboard ? nil : Self.emptyInputView
    }

    /// Toggle the virtual keyboard visibility.
    func toggleVirtualKeyboard() {
        wantsVirtualKeyboard.toggle()
        if isFirstResponder {
            reloadInputViews()
            onFocusChanged?(wantsVirtualKeyboard)
        } else {
            _ = becomeFirstResponder()
        }
    }

    // MARK: - Rendering

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext(),
              let image = desktopImage else { return }

        let displayRect = calculateDisplayRect()

        ctx.saveGState()

        // Apply zoom and pan
        ctx.translateBy(x: panOffset.x, y: panOffset.y)
        ctx.scaleBy(x: zoomScale, y: zoomScale)

        // Large multi-monitor desktops can exceed a GPU's single-texture axis
        // limit. Bound each source image submitted to UIKit, while retaining the
        // same desktop-to-view mapping and the pan/zoom transform above.
        let tileDimension = 8192
        if image.width <= tileDimension && image.height <= tileDimension {
            UIImage(cgImage: image).draw(in: displayRect)
        } else {
            let scaleX = displayRect.width / CGFloat(image.width)
            let scaleY = displayRect.height / CGFloat(image.height)
            let visible = ctx.boundingBoxOfClipPath
            ctx.interpolationQuality = .none
            ctx.setShouldAntialias(false)
            for sourceY in stride(from: 0, to: image.height, by: tileDimension) {
                for sourceX in stride(from: 0, to: image.width, by: tileDimension) {
                    let source = CGRect(x: sourceX, y: sourceY,
                        width: min(tileDimension, image.width - sourceX),
                        height: min(tileDimension, image.height - sourceY))
                    let destination = CGRect(x: displayRect.minX + source.minX * scaleX,
                        y: displayRect.minY + source.minY * scaleY,
                        width: source.width * scaleX, height: source.height * scaleY)
                    guard destination.intersects(visible), let tile = image.cropping(to: source) else { continue }
                    // Adjacent tiles meet on fractional device pixels when fit to
                    // the screen. Give each pixel to exactly one tile, preventing
                    // translucent seams and a later tile painting over its neighbor.
                    let device = ctx.convertToDeviceSpace(destination)
                    let pixelBounds = CGRect(x: device.minX.rounded(), y: device.minY.rounded(),
                        width: device.maxX.rounded() - device.minX.rounded(),
                        height: device.maxY.rounded() - device.minY.rounded())
                    ctx.saveGState()
                    ctx.clip(to: ctx.convertToUserSpace(pixelBounds))
                    UIImage(cgImage: tile).draw(in: destination)
                    ctx.restoreGState()
                }
            }
        }

        ctx.restoreGState()
    }

    private func setupPointerMarker() {
        clipsToBounds = true
        cursorLayer.name = "remote-cursor"
        cursorLayer.anchorPoint = .zero
        cursorLayer.isHidden = true
        cursorLayer.magnificationFilter = .nearest
        layer.addSublayer(cursorLayer)
        addInteraction(pointerInteraction)
    }

    private func hidePointerMarker() {
        hasPointerPosition = false
        hardwarePointerInside = false
        cursorLayer.isHidden = true
    }

    private var visibleDesktopRect: CGRect {
        let rect = calculateDisplayRect()
        return CGRect(x: rect.minX * zoomScale + panOffset.x,
                      y: rect.minY * zoomScale + panOffset.y,
                      width: rect.width * zoomScale, height: rect.height * zoomScale).intersection(bounds)
    }

    private func updatePointerMarker() {
        updateVideoFrame()
        guard hasPointerPosition, let cursor = cursorPresentation,
              !cursor.isHidden, desktopSize.width > 0, desktopSize.height > 0,
              bounds.width > 0, bounds.height > 0 else {
            cursorLayer.isHidden = true
            return
        }
        let rect = calculateDisplayRect()
        let point = CGPoint(x: (rect.minX + pointerPoint.x / desktopSize.width * rect.width) * zoomScale + panOffset.x,
                            y: (rect.minY + pointerPoint.y / desktopSize.height * rect.height) * zoomScale + panOffset.y)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cursorLayer.bounds = CGRect(origin: .zero, size: cursor.size)
        cursorLayer.position = CGPoint(x: point.x - cursor.hotspot.x, y: point.y - cursor.hotspot.y)
        cursorLayer.isHidden = !visibleDesktopRect.contains(point) || (hardwarePointerInside && cursor.nativeShape != nil)
        CATransaction.commit()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        pointerInteraction.invalidate()
        updatePointerMarker()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { releaseAllKeys() }
    }

    // MARK: - Coordinate Mapping

    /// Convert a point in view coordinates to remote desktop coordinates
    func viewPointToDesktopPoint(_ viewPoint: CGPoint) -> CGPoint {
        guard desktopSize.width > 0, desktopSize.height > 0, bounds.width > 0, bounds.height > 0 else { return .zero }

        let displayRect = calculateDisplayRect()

        let adjustedPoint = CGPoint(
            x: (viewPoint.x - panOffset.x) / zoomScale - displayRect.origin.x,
            y: (viewPoint.y - panOffset.y) / zoomScale - displayRect.origin.y
        )

        let desktopX = adjustedPoint.x / displayRect.width * desktopSize.width
        let desktopY = adjustedPoint.y / displayRect.height * desktopSize.height

        return CGPoint(
            x: max(0, min(desktopX, desktopSize.width - 1)),
            y: max(0, min(desktopY, desktopSize.height - 1))
        )
    }

    private func calculateDisplayRect() -> CGRect {
        guard desktopSize.width > 0 && desktopSize.height > 0 else {
            return bounds
        }

        let viewAspect = bounds.width / bounds.height
        let desktopAspect = desktopSize.width / desktopSize.height

        if desktopAspect > viewAspect {
            // Fit to width
            let h = bounds.width / desktopAspect
            return CGRect(x: 0, y: (bounds.height - h) / 2,
                          width: bounds.width, height: h)
        } else {
            // Fit to height
            let w = bounds.height * desktopAspect
            return CGRect(x: (bounds.width - w) / 2, y: 0,
                          width: w, height: bounds.height)
        }
    }

    // MARK: - Gesture Recognizers

    private func setupGestureRecognizers() {
        // Hover (mouse/trackpad movement)
        let hover = UIHoverGestureRecognizer(target: self, action: #selector(handleHover))
        addGestureRecognizer(hover)

        // Single tap = left click
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        tap.buttonMaskRequired = .primary
        addGestureRecognizer(tap)

        // Two-finger tap = right click
        let rightClick = UITapGestureRecognizer(target: self, action: #selector(handleRightClick))
        rightClick.numberOfTouchesRequired = 2
        rightClick.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        addGestureRecognizer(rightClick)

        // Pinch to zoom
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch))
        addGestureRecognizer(pinch)

        // Two-finger touch scroll (direct touch only)
        let touchScroll = UIPanGestureRecognizer(target: self, action: #selector(handleScroll))
        touchScroll.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        touchScroll.minimumNumberOfTouches = 2
        touchScroll.maximumNumberOfTouches = 2
        addGestureRecognizer(touchScroll)

        // Trackpad/mouse scroll (indirect scroll events)
        let indirectScroll = UIPanGestureRecognizer(target: self, action: #selector(handleScroll))
        indirectScroll.allowedScrollTypesMask = [.continuous, .discrete]
        indirectScroll.delegate = self
        self.indirectScrollRecognizer = indirectScroll
        addGestureRecognizer(indirectScroll)

        let viewportPan = UIPanGestureRecognizer(target: self, action: #selector(handleViewportPan))
        viewportPan.minimumNumberOfTouches = 3
        viewportPan.maximumNumberOfTouches = 3
        addGestureRecognizer(viewportPan)
        let secondary = UITapGestureRecognizer(target: self, action: #selector(handleRightClick))
        secondary.buttonMaskRequired = .secondary
        // Button masks do not exclude direct touches: without this restriction,
        // an ordinary screen tap can win this recognizer and become a right click.
        secondary.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
        addGestureRecognizer(secondary)

        // Single finger drag for pointer movement (touch)
        let drag = UIPanGestureRecognizer(target: self, action: #selector(handleDrag))
        drag.minimumNumberOfTouches = 1
        drag.maximumNumberOfTouches = 1
        // Ensure taps are recognized as clicks before drag can begin.
        // Without this, slight finger movement during a tap triggers the pan
        // gesture, which sends a drag sequence instead of a clean click.
        drag.require(toFail: tap)
        addGestureRecognizer(drag)
    }

    @objc private func handleHover(_ recognizer: UIHoverGestureRecognizer) {
        if recognizer.state == .ended || recognizer.state == .cancelled {
            hidePointerMarker()
            return
        }
        let viewPoint = recognizer.location(in: self)
        guard visibleDesktopRect.contains(viewPoint) else {
            hidePointerMarker()
            return
        }
        hardwarePointerInside = true
        let desktopPoint = viewPointToDesktopPoint(viewPoint)
        pointer(desktopPoint)
    }

    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        #if DEBUG
        recordInputCallback("tap")
        VNCControlDiagnostics.logger.notice("ui layout width=\(self.bounds.width) height=\(self.bounds.height) desktop_width=\(self.desktopSize.width) desktop_height=\(self.desktopSize.height)")
        #endif
        guard recognizer.state == .ended else { return }
        let viewPoint = recognizer.location(in: self)
        let desktopPoint = viewPointToDesktopPoint(viewPoint)
        
        // Ensure we are first responder to keep receiving keyboard events
        if !isFirstResponder {
            _ = becomeFirstResponder()
        }
        
        // Move cursor to tap position first so the server registers the location,
        // then send the click. This is important for macOS login screen and other
        // UI elements that require cursor presence before responding to clicks.
        pointer(desktopPoint)
        pointer(desktopPoint, mask: 1)
        pointer(desktopPoint, mask: 0)
    }

    @objc private func handleRightClick(_ recognizer: UITapGestureRecognizer) {
        #if DEBUG
        recordInputCallback("rightClick")
        #endif
        guard recognizer.state == .ended else { return }
        let viewPoint = recognizer.location(in: self)
        let desktopPoint = viewPointToDesktopPoint(viewPoint)
        if !isFirstResponder { _ = becomeFirstResponder() }
        pointer(desktopPoint, mask: 4)
        pointer(desktopPoint, mask: 0)
    }

    @objc private func handleViewportPan(_ recognizer: UIPanGestureRecognizer) {
        let delta = recognizer.translation(in: self)
        panOffset.x += delta.x; panOffset.y += delta.y
        recognizer.setTranslation(.zero, in: self)
        pointerInteraction.invalidate()
        updatePointerMarker()
        setNeedsDisplay()
    }

    @objc private func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
        if recognizer.state == .changed {
            let center = recognizer.location(in: self)
            let previous = zoomScale
            zoomScale *= recognizer.scale
            zoomScale = max(0.5, min(zoomScale, 5.0))
            let ratio = zoomScale / previous
            panOffset = CGPoint(x: center.x - (center.x - panOffset.x) * ratio,
                                y: center.y - (center.y - panOffset.y) * ratio)
            recognizer.scale = 1.0
            pointerInteraction.invalidate()
            updatePointerMarker()
            setNeedsDisplay()
        }
    }

    @objc private func handleScroll(_ recognizer: UIPanGestureRecognizer) {
        let identifier = ObjectIdentifier(recognizer)
        guard recognizer.state == .began || recognizer.state == .changed else {
            scrollRemainders.removeValue(forKey: identifier)
            recognizer.setTranslation(.zero, in: self)
            return
        }
        if recognizer.state == .began { scrollRemainders.removeValue(forKey: identifier) }
        let delta = recognizer.translation(in: self).y
        recognizer.setTranslation(.zero, in: self)
        guard delta.isFinite else {
            scrollRemainders.removeValue(forKey: identifier)
            return
        }
        pointerPoint = viewPointToDesktopPoint(recognizer.location(in: self))
        hasPointerPosition = true
        updatePointerMarker()
        // Bound each callback to 32 wheel ticks so malformed or huge deltas
        // cannot stall the UI or flood the remote input queue.
        let pointsPerTick = 20 / scrollSensitivity.multiplier
        let boundedDelta = max(-32 * pointsPerTick, min(delta, 32 * pointsPerTick))
        let accumulated = (scrollRemainders[identifier] ?? 0) + boundedDelta
        let ticks = Int(accumulated / pointsPerTick)
        scrollRemainders[identifier] = accumulated - CGFloat(ticks) * pointsPerTick
        let mask: UInt8 = ticks > 0 ? 8 : 16
        for _ in 0..<abs(ticks) {
            onPointer?(pointerPoint, pointerMask | mask)
            onPointer?(pointerPoint, pointerMask)
        }
    }

    @objc private func handleDrag(_ recognizer: UIPanGestureRecognizer) {
        let viewPoint = recognizer.location(in: self)
        let desktopPoint = viewPointToDesktopPoint(viewPoint)

        switch recognizer.state {
        case .began:
            if !isFirstResponder { _ = becomeFirstResponder() }
            // Recognition starts after movement (and tap failure). Press at
            // the original touch point before forwarding that first movement.
            let translation = recognizer.translation(in: self)
            let origin = viewPointToDesktopPoint(CGPoint(
                x: viewPoint.x - translation.x, y: viewPoint.y - translation.y))
            pointer(origin, mask: 0)
            pointer(origin, mask: 1)
            pointer(desktopPoint, mask: 1)
        case .changed:
            pointer(desktopPoint)
        case .ended:
            // Sparse event streams may have no changed callback, or may carry
            // their final movement only on ended. Move while still pressed.
            pointer(desktopPoint)
            pointer(desktopPoint, mask: 0)
        case .cancelled:
            pointer(desktopPoint, mask: 0)
        default:
            break
        }
    }

    // MARK: - Keyboard Input

    /// Determine whether a key press should be handled directly as a VNC key event
    /// rather than routed through the iOS text input system.
    /// Modifier keys, special keys, and keyboard shortcuts (Ctrl/Alt/Cmd+key)
    /// are handled directly. Printable characters without command modifiers are
    /// routed through the text input system so that IME composition (Korean, etc.) works.
    func handlesDirectly(code: UIKeyboardHIDUsage, modifiers: UIKeyModifierFlags) -> Bool {
        // Hardware Korean composition can use insert/delete callbacks without marked text.
        // Let UIKit decompose the active syllable before forwarding its replacement.
        if code == .keyboardDeleteOrBackspace,
           _markedText != nil || modifiers.intersection([.control, .alternate, .command]).isEmpty {
            return false
        }
        return Self.keysym(for: code) != nil || !modifiers.intersection([.control, .alternate, .command]).isEmpty
    }
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        #if DEBUG
        recordInputCallback("pressesBegan")
        #endif
        var unhandled = Set<UIPress>()
        for press in presses {
            #if DEBUG
            if let key = press.key {
                VNCControlDiagnostics.logger.notice("ui hardware modifiers=\(key.modifierFlags.rawValue)")
            }
            #endif
            guard let key = press.key, handlesDirectly(code: key.keyCode, modifiers: key.modifierFlags) else {
                unhandled.insert(press); continue
            }
            let symbol = Self.keysym(for: key.keyCode) ?? key.charactersIgnoringModifiers.unicodeScalars.first.map { $0.value <= 255 ? $0.value : 0x01000000 | $0.value }
            guard let symbol else { unhandled.insert(press); continue }
            keyDown(code: key.keyCode, keysym: symbol)
            // UIKit owns printable text/IME, so it must see both Shift edges.
            // Also retain remote Shift for selection and modified shortcuts.
            if Self.isShift(key.keyCode) { unhandled.insert(press) }
        }
        if !unhandled.isEmpty { super.pressesBegan(unhandled, with: event) }
    }
    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let unhandled = releaseHardwarePresses(presses)
        if !unhandled.isEmpty { super.pressesEnded(unhandled, with: event) }
    }
    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let unhandled = releaseHardwarePresses(presses)
        if !unhandled.isEmpty { super.pressesCancelled(unhandled, with: event) }
    }
    private func releaseHardwarePresses(_ presses: Set<UIPress>) -> Set<UIPress> {
        var unhandled = Set<UIPress>()
        for press in presses {
            if let code = press.key?.keyCode, let symbol = pressedKeys.removeValue(forKey: code) {
                onKey?(symbol, false)
                if Self.isShift(code) { unhandled.insert(press) }
            } else { unhandled.insert(press) }
        }
        return unhandled
    }
    private static func isShift(_ code: UIKeyboardHIDUsage) -> Bool {
        code == .keyboardLeftShift || code == .keyboardRightShift
    }

    private static func keysym(for code: UIKeyboardHIDUsage) -> UInt32? {
        switch code {
        case .keyboardLeftControl: return 0xffe3
        case .keyboardRightControl: return 0xffe4
        case .keyboardLeftShift: return 0xffe1
        case .keyboardRightShift: return 0xffe2
        case .keyboardLeftAlt: return 0xffe9
        case .keyboardRightAlt: return 0xffea
        case .keyboardLeftGUI: return 0xffeb
        case .keyboardRightGUI: return 0xffec
        case .keyboardReturnOrEnter: return 0xff0d
        case .keypadEnter: return 0xff8d
        case .keyboardTab: return 0xff09
        case .keyboardEscape: return 0xff1b
        case .keyboardDeleteOrBackspace: return 0xff08
        case .keyboardDeleteForward: return 0xffff
        case .keyboardHome: return 0xff50
        case .keyboardEnd: return 0xff57
        case .keyboardPageUp: return 0xff55
        case .keyboardPageDown: return 0xff56
        case .keyboardLeftArrow: return 0xff51
        case .keyboardUpArrow: return 0xff52
        case .keyboardRightArrow: return 0xff53
        case .keyboardDownArrow: return 0xff54
        default:
            if (58...69).contains(code.rawValue) { return 0xffbe + UInt32(code.rawValue - 58) }
            return nil
        }
    }

}

// MARK: - UIGestureRecognizerDelegate

extension RemoteDesktopUIView: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        // Prevent the indirect scroll recognizer from responding to direct touches.
        // Scroll events (trackpad/mouse) bypass this method and are still handled.
        if gestureRecognizer === indirectScrollRecognizer {
            return false
        }
        return true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        // Allow indirect scroll to coexist with other recognizers (e.g. hover)
        if gestureRecognizer === indirectScrollRecognizer {
            return true
        }
        return false
    }
}

// MARK: - UITextInput (Keyboard & IME)

extension RemoteDesktopUIView: UITextInput {

    // MARK: UIKeyInput

    var hasText: Bool { true }

    private var localTextLength: Int { (_markedText ?? "").utf16.count }

    private func updateComposition(_ text: String?, selection: NSRange) {
        _inputDelegate?.textWillChange(self)
        _inputDelegate?.selectionWillChange(self)
        _markedText = text
        let length = localTextLength
        let location = min(max(0, selection.location), length)
        _markedSelection = NSRange(location: location, length: min(max(0, selection.length), length - location))
        _inputDelegate?.selectionDidChange(self)
        _inputDelegate?.textDidChange(self)
    }

    func insertText(_ text: String) {
        inputLanguageDidChange()
        #if DEBUG
        recordCompositionCallback("insertText", text: text)
        #endif
        updateComposition(nil, selection: NSRange(location: 0, length: 0))
        sendText(text)
    }

    func deleteBackward() {
        guard let marked = _markedText else {
            onKey?(0xff08, true); onKey?(0xff08, false)
            return
        }
        var deletion = _markedSelection
        if deletion.length == 0 {
            guard deletion.location > 0 else { return }
            deletion = (marked as NSString).rangeOfComposedCharacterSequence(at: deletion.location - 1)
        }
        let text = (marked as NSString).replacingCharacters(in: deletion, with: "")
        updateComposition(text, selection: NSRange(location: deletion.location, length: 0))
    }

    // MARK: Marked Text (IME Composition)

    func setMarkedText(_ markedText: String?, selectedRange: NSRange) {
        inputLanguageDidChange()
        #if DEBUG
        recordCompositionCallback("setMarkedText", text: markedText)
        #endif
        updateComposition(markedText, selection: selectedRange)
    }

    func unmarkText() {
        #if DEBUG
        recordCompositionCallback("unmarkText", text: _markedText)
        #endif
        let text = _markedText
        updateComposition(nil, selection: NSRange(location: 0, length: 0))
        if let text, !text.isEmpty {
            sendText(text)
        }
    }

    var markedTextRange: UITextRange? {
        guard _markedText != nil else { return nil }
        return SimpleTextRange(start: 0, end: localTextLength)
    }

    var markedTextStyle: [NSAttributedString.Key: Any]? {
        get { nil }
        set {}
    }

    // MARK: Selection & Document Positions (UTF-16)

    var selectedTextRange: UITextRange? {
        get { SimpleTextRange(start: _markedSelection.location, end: NSMaxRange(_markedSelection)) }
        set {
            guard let newValue, let range = localRange(newValue) else { return }
            _inputDelegate?.selectionWillChange(self)
            _markedSelection = range
            _inputDelegate?.selectionDidChange(self)
        }
    }

    var beginningOfDocument: UITextPosition { SimpleTextPosition(0) }
    var endOfDocument: UITextPosition { SimpleTextPosition(localTextLength) }

    // MARK: Text & Range Queries

    private func localRange(_ range: UITextRange) -> NSRange? {
        guard let start = range.start as? SimpleTextPosition,
              let end = range.end as? SimpleTextPosition,
              start.index >= 0, end.index >= start.index,
              end.index <= localTextLength else { return nil }
        return NSRange(location: start.index, length: end.index - start.index)
    }

    func text(in range: UITextRange) -> String? {
        guard let range = localRange(range) else { return nil }
        return ((_markedText ?? "") as NSString).substring(with: range)
    }

    func replace(_ range: UITextRange, withText text: String) {
        guard let range = localRange(range) else { return }
        guard let marked = _markedText else {
            if !text.isEmpty { sendText(text) }
            return
        }
        let updated = (marked as NSString).replacingCharacters(in: range, with: text)
        updateComposition(updated, selection: NSRange(location: range.location + text.utf16.count, length: 0))
    }

    func textRange(from fromPosition: UITextPosition, to toPosition: UITextPosition) -> UITextRange? {
        guard let from = fromPosition as? SimpleTextPosition,
              let to = toPosition as? SimpleTextPosition,
              from.index >= 0, from.index <= localTextLength,
              to.index >= 0, to.index <= localTextLength else { return nil }
        return SimpleTextRange(start: min(from.index, to.index), end: max(from.index, to.index))
    }

    func position(from position: UITextPosition, offset: Int) -> UITextPosition? {
        guard let pos = position as? SimpleTextPosition else { return nil }
        let (target, overflow) = pos.index.addingReportingOverflow(offset)
        guard !overflow, target >= 0, target <= localTextLength else { return nil }
        return SimpleTextPosition(target)
    }

    func position(from position: UITextPosition, in direction: UITextLayoutDirection, offset: Int) -> UITextPosition? {
        guard offset != Int.min else { return nil }
        return self.position(from: position, offset: (direction == .left || direction == .up) ? -offset : offset)
    }

    func compare(_ position: UITextPosition, to other: UITextPosition) -> ComparisonResult {
        guard let a = position as? SimpleTextPosition,
              let b = other as? SimpleTextPosition else { return .orderedSame }
        if a.index < b.index { return .orderedAscending }
        if a.index > b.index { return .orderedDescending }
        return .orderedSame
    }

    func offset(from: UITextPosition, to toPosition: UITextPosition) -> Int {
        guard let a = from as? SimpleTextPosition,
              let b = toPosition as? SimpleTextPosition else { return 0 }
        return b.index - a.index
    }

    // MARK: Input Delegate & Tokenizer

    var inputDelegate: (any UITextInputDelegate)? {
        get { _inputDelegate }
        set { _inputDelegate = newValue }
    }

    var tokenizer: any UITextInputTokenizer { _tokenizer }

    // MARK: Layout & Geometry (stubs)

    func position(within range: UITextRange, farthestIn direction: UITextLayoutDirection) -> UITextPosition? {
        guard let r = range as? SimpleTextRange else { return nil }
        return (direction == .left || direction == .up) ? r.start : r.end
    }

    func characterRange(byExtending position: UITextPosition, in direction: UITextLayoutDirection) -> UITextRange? {
        guard let pos = position as? SimpleTextPosition else { return nil }
        return SimpleTextRange(start: pos.index, end: pos.index)
    }

    func baseWritingDirection(for position: UITextPosition, in direction: UITextStorageDirection) -> NSWritingDirection {
        .leftToRight
    }

    func setBaseWritingDirection(_ writingDirection: NSWritingDirection, for range: UITextRange) {}

    func firstRect(for range: UITextRange) -> CGRect { .zero }

    func caretRect(for position: UITextPosition) -> CGRect { .zero }

    func selectionRects(for range: UITextRange) -> [UITextSelectionRect] { [] }

    func closestPosition(to point: CGPoint) -> UITextPosition? { SimpleTextPosition(0) }

    func closestPosition(to point: CGPoint, within range: UITextRange) -> UITextPosition? { range.start }

    func characterRange(at point: CGPoint) -> UITextRange? { nil }

    // MARK: UITextInputTraits

    var autocorrectionType: UITextAutocorrectionType {
        get { .no }
        set {}
    }

    var autocapitalizationType: UITextAutocapitalizationType {
        get { .none }
        set {}
    }

    var spellCheckingType: UITextSpellCheckingType {
        get { .no }
        set {}
    }

    var smartQuotesType: UITextSmartQuotesType {
        get { .no }
        set {}
    }

    var smartDashesType: UITextSmartDashesType {
        get { .no }
        set {}
    }

    var smartInsertDeleteType: UITextSmartInsertDeleteType {
        get { .no }
        set {}
    }
}

// MARK: - Native mouse / trackpad cursor

extension RemoteDesktopUIView: UIPointerInteractionDelegate {
    func pointerInteraction(_ interaction: UIPointerInteraction, regionFor request: UIPointerRegionRequest,
                            defaultRegion: UIPointerRegion) -> UIPointerRegion? {
        guard desktopSize.width > 0, desktopSize.height > 0,
              visibleDesktopRect.contains(request.location) else { return nil }
        return UIPointerRegion(rect: visibleDesktopRect, identifier: "remote-desktop" as NSString)
    }

    func pointerInteraction(_ interaction: UIPointerInteraction, styleFor region: UIPointerRegion) -> UIPointerStyle? {
        guard let cursor = cursorPresentation else { return nil }
        if let shape = cursor.nativeShape { return UIPointerStyle(shape: shape, constrainedAxes: []) }
        // Explicitly empty cursors and precise bitmap fallback both hide the
        // system cursor only in our desktop region. UIKit restores it on exit.
        return .hidden()
    }
}
