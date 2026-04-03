import SwiftUI

struct RemoteDesktopView: UIViewRepresentable {

    let desktopImage: CGImage?
    let desktopSize: CGSize
    let inputManager: InputManager

    func makeUIView(context: Context) -> RemoteDesktopUIView {
        let view = RemoteDesktopUIView(frame: .zero)
        view.delegate = context.coordinator
        view.desktopSize = desktopSize
        // Become first responder for keyboard input
        DispatchQueue.main.async {
            view.becomeFirstResponder()
        }
        return view
    }

    func updateUIView(_ uiView: RemoteDesktopUIView, context: Context) {
        uiView.desktopImage = desktopImage
        uiView.desktopSize = desktopSize
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(inputManager: inputManager)
    }

    class Coordinator: NSObject, RemoteDesktopUIViewDelegate {
        let inputManager: InputManager

        init(inputManager: InputManager) {
            self.inputManager = inputManager
        }

        func remoteDesktopView(_ view: RemoteDesktopUIView, keyDown key: UIKey) {
            inputManager.keyDown(key)
        }

        func remoteDesktopView(_ view: RemoteDesktopUIView, keyUp key: UIKey) {
            inputManager.keyUp(key)
        }

        func remoteDesktopView(_ view: RemoteDesktopUIView, pointerMovedTo desktopPoint: CGPoint) {
            inputManager.pointerMoved(
                x: UInt16(clamping: Int(desktopPoint.x)),
                y: UInt16(clamping: Int(desktopPoint.y))
            )
        }

        func remoteDesktopView(_ view: RemoteDesktopUIView, mouseDown button: Int, at desktopPoint: CGPoint) {
            inputManager.mouseDown(
                button: button,
                x: UInt16(clamping: Int(desktopPoint.x)),
                y: UInt16(clamping: Int(desktopPoint.y))
            )
        }

        func remoteDesktopView(_ view: RemoteDesktopUIView, mouseUp button: Int, at desktopPoint: CGPoint) {
            inputManager.mouseUp(
                button: button,
                x: UInt16(clamping: Int(desktopPoint.x)),
                y: UInt16(clamping: Int(desktopPoint.y))
            )
        }

        func remoteDesktopView(_ view: RemoteDesktopUIView, scrollDeltaY: CGFloat) {
            inputManager.scrollWheel(deltaY: scrollDeltaY)
        }
    }
}
