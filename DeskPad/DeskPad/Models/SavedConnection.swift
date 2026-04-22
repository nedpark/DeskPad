import Foundation

struct SavedConnection: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var host: String
    var port: UInt16
    var username: String
    var password: String
    var lastConnected: Date?
    var thumbnailFilename: String?

    init(
        id: UUID = UUID(),
        name: String = "",
        host: String,
        port: UInt16 = 5900,
        username: String = "",
        password: String = "",
        lastConnected: Date? = nil,
        thumbnailFilename: String? = nil
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.lastConnected = lastConnected
        self.thumbnailFilename = thumbnailFilename
    }

    var displayName: String {
        if !name.isEmpty { return name }
        return port == 5900 ? host : "\(host):\(port)"
    }
}
