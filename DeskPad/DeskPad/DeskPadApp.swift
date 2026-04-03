import SwiftUI

@main
struct DeskPadApp: App {
    @State private var connection = VNCConnection()

    var body: some Scene {
        WindowGroup {
            ContentView(connection: connection)
        }
    }
}
