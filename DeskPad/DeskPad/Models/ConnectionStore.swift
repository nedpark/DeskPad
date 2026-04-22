import Foundation
import CoreGraphics
import UIKit
import SwiftUI

@MainActor
@Observable
final class ConnectionStore {

    private(set) var connections: [SavedConnection] = []

    private static let filename = "connections.json"

    // MARK: - File Paths

    private static var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    private static var connectionsFileURL: URL {
        documentsDirectory.appendingPathComponent(filename)
    }

    private static var thumbnailsDirectory: URL {
        let url = documentsDirectory.appendingPathComponent("thumbnails")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - Init

    init() {
        load()
    }

    // MARK: - CRUD

    func add(_ connection: SavedConnection) {
        connections.append(connection)
        save()
    }

    func update(_ connection: SavedConnection) {
        guard let index = connections.firstIndex(where: { $0.id == connection.id }) else { return }
        var updated = connection
        updated.lastConnected = connections[index].lastConnected
        updated.thumbnailFilename = connections[index].thumbnailFilename
        connections[index] = updated
        save()
    }

    func delete(at offsets: IndexSet) {
        let toDelete = offsets.map { connections[$0] }
        for conn in toDelete {
            deleteThumbnail(for: conn)
        }
        connections.remove(atOffsets: offsets)
        save()
    }

    func delete(id: UUID) {
        guard let index = connections.firstIndex(where: { $0.id == id }) else { return }
        deleteThumbnail(for: connections[index])
        connections.remove(at: index)
        save()
    }

    func markConnected(id: UUID) {
        guard let index = connections.firstIndex(where: { $0.id == id }) else { return }
        connections[index].lastConnected = Date()
        save()
    }

    // MARK: - Thumbnail Management

    func saveThumbnail(_ image: CGImage, for connectionID: UUID) {
        let filename = "\(connectionID.uuidString).jpg"
        let url = Self.thumbnailsDirectory.appendingPathComponent(filename)

        let uiImage = UIImage(cgImage: image)
        let maxDimension: CGFloat = 480
        let scale = min(maxDimension / CGFloat(image.width), maxDimension / CGFloat(image.height), 1.0)
        let newSize = CGSize(
            width: CGFloat(image.width) * scale,
            height: CGFloat(image.height) * scale
        )
        let renderer = UIGraphicsImageRenderer(size: newSize)
        let thumbnailData = renderer.jpegData(withCompressionQuality: 0.7) { context in
            uiImage.draw(in: CGRect(origin: .zero, size: newSize))
        }

        try? thumbnailData.write(to: url)

        if let index = connections.firstIndex(where: { $0.id == connectionID }) {
            connections[index].thumbnailFilename = filename
            save()
        }
    }

    func thumbnailURL(for connection: SavedConnection) -> URL? {
        guard let filename = connection.thumbnailFilename else { return nil }
        let url = Self.thumbnailsDirectory.appendingPathComponent(filename)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func deleteThumbnail(for connection: SavedConnection) {
        guard let filename = connection.thumbnailFilename else { return }
        let url = Self.thumbnailsDirectory.appendingPathComponent(filename)
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Persistence

    private func save() {
        do {
            let data = try JSONEncoder().encode(connections)
            try data.write(to: Self.connectionsFileURL, options: .atomic)
        } catch {
            print("Failed to save connections: \(error)")
        }
    }

    private func load() {
        do {
            let data = try Data(contentsOf: Self.connectionsFileURL)
            connections = try JSONDecoder().decode([SavedConnection].self, from: data)
        } catch {
            connections = []
        }
    }

    // MARK: - Migration from AppStorage

    func migrateFromAppStorage() {
        guard connections.isEmpty else { return }
        let defaults = UserDefaults.standard
        guard let host = defaults.string(forKey: "lastHost"), !host.isEmpty else { return }

        let port = UInt16(defaults.string(forKey: "lastPort") ?? "5900") ?? 5900
        let username = defaults.string(forKey: "lastUsername") ?? ""
        let password = defaults.string(forKey: "lastPassword") ?? ""

        let migrated = SavedConnection(
            host: host,
            port: port,
            username: username,
            password: password
        )
        add(migrated)

        defaults.removeObject(forKey: "lastHost")
        defaults.removeObject(forKey: "lastPort")
        defaults.removeObject(forKey: "lastUsername")
        defaults.removeObject(forKey: "lastPassword")
    }
}
