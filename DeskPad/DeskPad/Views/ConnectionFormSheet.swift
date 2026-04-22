import SwiftUI

struct ConnectionFormSheet: View {
    enum Mode {
        case add
        case edit(SavedConnection)
    }

    let mode: Mode
    let onSave: (SavedConnection) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var host: String
    @State private var port: String
    @State private var username: String
    @State private var password: String

    private let existingID: UUID?

    init(mode: Mode, onSave: @escaping (SavedConnection) -> Void) {
        self.mode = mode
        self.onSave = onSave

        switch mode {
        case .add:
            existingID = nil
            _name = State(initialValue: "")
            _host = State(initialValue: "")
            _port = State(initialValue: "5900")
            _username = State(initialValue: "")
            _password = State(initialValue: "")
        case .edit(let connection):
            existingID = connection.id
            _name = State(initialValue: connection.name)
            _host = State(initialValue: connection.host)
            _port = State(initialValue: String(connection.port))
            _username = State(initialValue: connection.username)
            _password = State(initialValue: connection.password)
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Display Name (optional)", text: $name)
                        .autocorrectionDisabled()
                }

                Section("Server") {
                    TextField("IP Address or Hostname", text: $host)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)

                    TextField("Port", text: $port)
                        .keyboardType(.numberPad)
                }

                Section("Authentication") {
                    TextField("Username (optional)", text: $username)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)

                    SecureField("Password (optional)", text: $password)
                }
            }
            .navigationTitle(isEditing ? "Edit Connection" : "New Connection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(host.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private var isEditing: Bool {
        if case .edit = mode { return true }
        return false
    }

    private func save() {
        let portNumber = UInt16(port) ?? 5900
        let connection = SavedConnection(
            id: existingID ?? UUID(),
            name: name.trimmingCharacters(in: .whitespaces),
            host: host.trimmingCharacters(in: .whitespaces),
            port: portNumber,
            username: username.trimmingCharacters(in: .whitespaces),
            password: password
        )
        onSave(connection)
        dismiss()
    }
}
