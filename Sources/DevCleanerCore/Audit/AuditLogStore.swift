import Foundation

public struct AuditLogStore: Sendable {
    public let storageDirectory: URL

    public init(storageDirectory: URL? = nil) {
        if let storageDirectory {
            self.storageDirectory = storageDirectory.standardizedFileURL
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
            self.storageDirectory = appSupport
                .appendingPathComponent("Husk/audit-logs", isDirectory: true)
                .standardizedFileURL
        }
    }

    public var indexFileURL: URL {
        storageDirectory.appendingPathComponent("sessions.json")
    }

    public func loadSessions() -> [CleanupSessionRecord] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: indexFileURL.path),
              let data = try? Data(contentsOf: indexFileURL) else {
            return []
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let sessions = (try? decoder.decode([CleanupSessionRecord].self, from: data)) ?? []
        return sessions.sorted(by: { $0.timestamp > $1.timestamp })
    }

    public func recordSession(_ session: CleanupSessionRecord) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: storageDirectory, withIntermediateDirectories: true)

        var existing = loadSessions()
        existing.removeAll { $0.id == session.id }
        existing.insert(session, at: 0)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let jsonData = try encoder.encode(existing)
        try jsonData.write(to: indexFileURL, options: .atomic)

        // Write human-readable Markdown audit log
        let mdURL = storageDirectory.appendingPathComponent("session-\(session.id.uuidString.prefix(8)).md")
        let mdContent = Self.renderMarkdown(for: session)
        try mdContent.write(to: mdURL, atomically: true, encoding: .utf8)
    }

    public func updateSession(_ updated: CleanupSessionRecord) throws {
        try recordSession(updated)
    }

    public static func renderMarkdown(for session: CleanupSessionRecord) -> String {
        let formatter = ISO8601DateFormatter()
        var lines: [String] = []
        lines.append("# Husk Audit Log — Session `\(session.id.uuidString.prefix(8))`")
        lines.append("- **Timestamp**: \(formatter.string(from: session.timestamp))")
        lines.append("- **Mode**: \(session.mode.title)")
        lines.append("- **Dry-Run Only**: \(session.wasDryRun ? "Yes" : "No")")
        lines.append("- **Storage**: \(session.storageSummary)")
        lines.append("")
        lines.append("## Items Processed (\(session.items.count))")
        lines.append("| Project | Artifact | Size | Original Path | Trashed / Status |")
        lines.append("| :--- | :--- | ---: | :--- | :--- |")
        for item in session.items {
            let status: String
            if let err = item.errorDescription {
                status = "Error: \(err)"
            } else if item.isRestored {
                status = "Restored to original path"
            } else if let trashed = item.trashedPath {
                status = "Moved to Trash (`\(trashed)`)"
            } else if session.wasDryRun {
                status = "Dry-Run Preview"
            } else if item.wasToolCommand == true {
                status = "Tool task completed"
            } else {
                status = session.mode == .moveToTrash && item.wasToolCommand == false
                    ? "Moved to Trash" : "Deleted permanently"
            }
            lines.append("| \(item.projectName) | `\(item.title)` | \(ByteFormatting.string(from: item.sizeBytes)) | `\(item.originalPath)` | \(status) |")
        }
        return lines.joined(separator: "\n")
    }
}
