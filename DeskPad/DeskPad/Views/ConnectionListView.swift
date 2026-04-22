import SwiftUI

struct ConnectionListView: View {
    var store: ConnectionStore
    let onConnect: (SavedConnection) -> Void

    @State private var showingAddSheet = false
    @State private var editingConnection: SavedConnection?

    var body: some View {
        NavigationStack {
            Group {
                if store.connections.isEmpty {
                    emptyStateView
                } else {
                    connectionList
                }
            }
            .navigationTitle("DeskPad")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !store.connections.isEmpty {
                        EditButton()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingAddSheet = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showingAddSheet) {
                ConnectionFormSheet(mode: .add) { newConnection in
                    store.add(newConnection)
                }
            }
            .sheet(item: $editingConnection) { connection in
                ConnectionFormSheet(mode: .edit(connection)) { updated in
                    store.update(updated)
                }
            }
        }
    }

    private var connectionList: some View {
        List {
            ForEach(store.connections) { connection in
                ConnectionRow(connection: connection, store: store)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        onConnect(connection)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            store.delete(id: connection.id)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        Button {
                            editingConnection = connection
                        } label: {
                            Label("Edit", systemImage: "pencil")
                        }
                        .tint(.blue)
                    }
            }
            .onDelete { offsets in
                store.delete(at: offsets)
            }
        }
        .listStyle(.insetGrouped)
    }

    private var emptyStateView: some View {
        ContentUnavailableView {
            Label("No Connections", systemImage: "desktopcomputer")
        } description: {
            Text("Tap + to add a VNC server connection.")
        } actions: {
            Button("Add Connection") {
                showingAddSheet = true
            }
            .buttonStyle(.borderedProminent)
        }
    }
}
