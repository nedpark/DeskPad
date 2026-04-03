import SwiftUI

struct ConnectionView: View {
    @AppStorage("lastHost") private var host: String = ""
    @AppStorage("lastPort") private var port: String = "5900"
    @AppStorage("lastUsername") private var username: String = ""
    @AppStorage("lastPassword") private var password: String = ""

    let onConnect: (String, UInt16, String, String) -> Void

    var body: some View {
        NavigationStack {
            Form {
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

                Section {
                    Button(action: connect) {
                        Text("Connect")
                            .frame(maxWidth: .infinity)
                            .fontWeight(.semibold)
                    }
                    .disabled(host.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .navigationTitle("DeskPad")
        }
    }

    private func connect() {
        let portNumber = UInt16(port) ?? 5900
        onConnect(host.trimmingCharacters(in: .whitespaces), portNumber, username.trimmingCharacters(in: .whitespaces), password)
    }
}
