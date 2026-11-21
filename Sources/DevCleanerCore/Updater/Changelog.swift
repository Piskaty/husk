import Foundation

public struct ChangelogRelease: Identifiable, Equatable, Sendable {
    public let version: SemanticVersion
    public let date: String
    public let changes: [String]

    public var id: String { version.description }

    public static func parse(_ markdown: String) -> [Self] {
        let sections = markdown.components(separatedBy: "\n## ").dropFirst()
        return sections.compactMap { section in
            let lines = section.split(whereSeparator: \.isNewline)
            guard let header = lines.first else { return nil }
            let fields = header.components(separatedBy: " — ")
            guard fields.count == 2, let version = SemanticVersion(string: fields[0]) else { return nil }
            let changes = lines.dropFirst().filter { $0.hasPrefix("- ") }.map { String($0.dropFirst(2)) }
            guard !changes.isEmpty else { return nil }
            return Self(version: version, date: fields[1], changes: changes)
        }.sorted { $0.version > $1.version }
    }

    public static func whatsNew(in releases: [Self], current: SemanticVersion, previous: SemanticVersion?) -> [Self] {
        releases.filter { release in
            guard let previous else { return release.version == current }
            return release.version > previous && release.version <= current
        }
    }
}
