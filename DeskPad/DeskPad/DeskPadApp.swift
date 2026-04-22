import SwiftUI

@main
struct DeskPadApp: App {
    @State private var connection = VNCConnection()
    @State private var store = ConnectionStore()

    var body: some Scene {
        WindowGroup {
            ContentView(connection: connection, store: store)
                .onAppear {
                    store.migrateFromAppStorage()
                }
        }
    }
}
