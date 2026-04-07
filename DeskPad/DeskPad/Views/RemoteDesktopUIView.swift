import UIKit

protocol RemoteDesktopUIViewDelegate: AnyObject {
    func remoteDesktopView(_ view: RemoteDesktopUIView, keyDown key: UIKey)
    func remoteDesktopView(_ view: RemoteDesktopUIView, keyUp key: UIKey)
    func remoteDesktopView(_ view: RemoteDesktopUIView, didInsertText text: String)
    func remoteDesktopViewDidDeleteBackward(_ view: RemoteDesktopUIView)
    func remoteDesktopView(_ view: RemoteDesktopUIView, pointerMovedTo desktopPoint: CGPoint)
    func remoteDesktopView(_ view: RemoteDesktopUIView, mouseDown button: Int, at desktopPoint: CGPoint)
    func remoteDesktopView(_ view: RemoteDesktopUIView, mouseUp button: Int, at desktopPoint: CGPoint)
    func remoteDesktopView(_ view: RemoteDesktopUIView, scrollDeltaY: CGFloat)
}

final class RemoteDesktopUIView: UIView {

    weak var delegate: RemoteDesktopUIViewDelegate?

    /// The remote desktop image to render
    var desktopImage: CGImage? {
        didSet { setNeedsDisplay() }
    }

    /// Remote desktop pixel dimensions for coordinate mapping
    var desktopSize: CGSize = .zero

    // Zoom/pan state
    private var zoomScale: CGFloat = 1.0
    private var panOffset: CGPoint = .zero

    // Virtual keyboard state
    private var wantsVirtualKeyboard = false
    private static let emptyInputView = UIView(frame: .zero)

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        isMultipleTouchEnabled = true
        setupGestureRecognizers()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        backgroundColor = .black
        isMultipleTouchEnabled = true
        setupGestureRecognizers()
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
            resignFirstResponder()
            becomeFirstResponder()
        } else {
            becomeFirstResponder()
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

        // Draw image
        UIImage(cgImage: image).draw(in: displayRect)

        ctx.restoreGState()
    }

    // MARK: - Coordinate Mapping

    /// Convert a point in view coordinates to remote desktop coordinates
    func viewPointToDesktopPoint(_ viewPoint: CGPoint) -> CGPoint {
        guard desktopSize.width > 0 && desktopSize.height > 0 else { return .zero }

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
        addGestureRecognizer(tap)

        // Two-finger tap = right click
        let rightClick = UITapGestureRecognizer(target: self, action: #selector(handleRightClick))
        rightClick.numberOfTouchesRequired = 2
        addGestureRecognizer(rightClick)

        // Pinch to zoom
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch))
        addGestureRecognizer(pinch)

        // Two-finger pan for scroll
        let scroll = UIPanGestureRecognizer(target: self, action: #selector(handleScroll))
        scroll.minimumNumberOfTouches = 2
        scroll.maximumNumberOfTouches = 2
        scroll.allowedScrollTypesMask = .continuous
        addGestureRecognizer(scroll)

        // Single finger drag for pointer movement (touch)
        let drag = UIPanGestureRecognizer(target: self, action: #selector(handleDrag))
        drag.minimumNumberOfTouches = 1
        drag.maximumNumberOfTouches = 1
        addGestureRecognizer(drag)
    }

    @objc private func handleHover(_ recognizer: UIHoverGestureRecognizer) {
        let viewPoint = recognizer.location(in: self)
        let desktopPoint = viewPointToDesktopPoint(viewPoint)
        delegate?.remoteDesktopView(self, pointerMovedTo: desktopPoint)
    }

    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended else { return }
        let viewPoint = recognizer.location(in: self)
        let desktopPoint = viewPointToDesktopPoint(viewPoint)
        
        // Ensure we are first responder to keep receiving keyboard events
        if !isFirstResponder {
            becomeFirstResponder()
        }
        
        delegate?.remoteDesktopView(self, mouseDown: 0, at: desktopPoint)
        delegate?.remoteDesktopView(self, mouseUp: 0, at: desktopPoint)
    }

    @objc private func handleRightClick(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended else { return }
        let viewPoint = recognizer.location(in: self)
        let desktopPoint = viewPointToDesktopPoint(viewPoint)
        delegate?.remoteDesktopView(self, mouseDown: 2, at: desktopPoint)
        delegate?.remoteDesktopView(self, mouseUp: 2, at: desktopPoint)
    }

    @objc private func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
        if recognizer.state == .changed {
            zoomScale *= recognizer.scale
            zoomScale = max(0.5, min(zoomScale, 5.0))
            recognizer.scale = 1.0
            setNeedsDisplay()
        }
    }

    @objc private func handleScroll(_ recognizer: UIPanGestureRecognizer) {
        let translation = recognizer.translation(in: self)
        delegate?.remoteDesktopView(self, scrollDeltaY: translation.y)
        recognizer.setTranslation(.zero, in: self)
    }

    @objc private func handleDrag(_ recognizer: UIPanGestureRecognizer) {
        let viewPoint = recognizer.location(in: self)
        let desktopPoint = viewPointToDesktopPoint(viewPoint)

        switch recognizer.state {
        case .began:
            delegate?.remoteDesktopView(self, mouseDown: 0, at: desktopPoint)
        case .changed:
            delegate?.remoteDesktopView(self, pointerMovedTo: desktopPoint)
        case .ended, .cancelled:
            delegate?.remoteDesktopView(self, mouseUp: 0, at: desktopPoint)
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
    private func shouldDirectlyHandle(_ key: UIKey) -> Bool {
        if KeySymMapping.isNonPrintableKey(key.keyCode) { return true }
        let shortcutModifiers: UIKeyModifierFlags = [.control, .alternate, .command]
        return !key.modifierFlags.intersection(shortcutModifiers).isEmpty
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var unhandledPresses = Set<UIPress>()
        for press in presses {
            guard let key = press.key else {
                unhandledPresses.insert(press)
                continue
            }
            if shouldDirectlyHandle(key) {
                delegate?.remoteDesktopView(self, keyDown: key)
            } else {
                unhandledPresses.insert(press)
            }
        }
        if !unhandledPresses.isEmpty {
            super.pressesBegan(unhandledPresses, with: event)
        }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var unhandledPresses = Set<UIPress>()
        for press in presses {
            guard let key = press.key else {
                unhandledPresses.insert(press)
                continue
            }
            if shouldDirectlyHandle(key) {
                delegate?.remoteDesktopView(self, keyUp: key)
            } else {
                unhandledPresses.insert(press)
            }
        }
        if !unhandledPresses.isEmpty {
            super.pressesEnded(unhandledPresses, with: event)
        }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var unhandledPresses = Set<UIPress>()
        for press in presses {
            guard let key = press.key else {
                unhandledPresses.insert(press)
                continue
            }
            if shouldDirectlyHandle(key) {
                delegate?.remoteDesktopView(self, keyUp: key)
            } else {
                unhandledPresses.insert(press)
            }
        }
        if !unhandledPresses.isEmpty {
            super.pressesCancelled(unhandledPresses, with: event)
        }
    }
}

// MARK: - UIKeyInput (Virtual Keyboard)

extension RemoteDesktopUIView: UIKeyInput {

    var hasText: Bool { true }

    func insertText(_ text: String) {
        delegate?.remoteDesktopView(self, didInsertText: text)
    }

    func deleteBackward() {
        delegate?.remoteDesktopViewDidDeleteBackward(self)
    }

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
