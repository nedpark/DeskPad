import UIKit

@MainActor
final class InputManager {

    private weak var connection: VNCConnection?

    // Pointer state
    private var buttonMask: UInt8 = 0
    private var pointerX: UInt16 = 0
    private var pointerY: UInt16 = 0

    init(connection: VNCConnection) {
        self.connection = connection
    }

    // MARK: - Keyboard Events

    func keyDown(_ key: UIKey) {
        guard let keysym = KeySymMapping.keysym(for: key) else { return }
        connection?.sendKeyEvent(downFlag: true, keysym: keysym)
    }

    func keyUp(_ key: UIKey) {
        guard let keysym = KeySymMapping.keysym(for: key) else { return }
        connection?.sendKeyEvent(downFlag: false, keysym: keysym)
    }

    // MARK: - Pointer Events

    func pointerMoved(x: UInt16, y: UInt16) {
        pointerX = x
        pointerY = y
        sendPointerEvent()
    }

    func mouseDown(button: Int, x: UInt16, y: UInt16) {
        pointerX = x
        pointerY = y
        buttonMask |= UInt8(1 << button)
        sendPointerEvent()
    }

    func mouseUp(button: Int, x: UInt16, y: UInt16) {
        pointerX = x
        pointerY = y
        buttonMask &= ~UInt8(1 << button)
        sendPointerEvent()
    }

    func scrollWheel(deltaY: CGFloat) {
        // VNC scroll: button 4 (scroll up) and button 5 (scroll down)
        if deltaY < 0 {
            buttonMask |= (1 << 3) // button 4 = scroll up
            sendPointerEvent()
            buttonMask &= ~(1 << 3)
            sendPointerEvent()
        } else if deltaY > 0 {
            buttonMask |= (1 << 4) // button 5 = scroll down
            sendPointerEvent()
            buttonMask &= ~(1 << 4)
            sendPointerEvent()
        }
    }

    private func sendPointerEvent() {
        connection?.sendPointerEvent(buttonMask: buttonMask, x: pointerX, y: pointerY)
    }
}
