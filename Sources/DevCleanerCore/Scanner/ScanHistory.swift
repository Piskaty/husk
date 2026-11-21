import Foundation

public struct ScanSnapshot: Codable, Equatable, Sendable {
    public struct Scope: Codable, Equatable, Sendable {
        let workspacePaths: [String]
        let excludedPaths: [String]
        let includeGlobalCaches: Bool
        let maxWorkspaceDepth: Int
        let gitGCMinimumBytes: Int64

        public init(configuration: ScanConfiguration, excludedPaths: [String]) {
            workspacePaths = Set(configuration.workspaceRoots.map(SafetyInspector.platformPath)).sorted()
            self.excludedPaths = Set(excludedPaths).sorted()
            includeGlobalCaches = configuration.includeGlobalCaches
            maxWorkspaceDepth = configuration.maxWorkspaceDepth
            gitGCMinimumBytes = configuration.gitGCMinimumBytes
        }
    }

    struct Entry: Codable, Equatable, Sendable {
        let id: String
        let projectID: String
        let projectName: String
        let title: String
        let path: String
        let bytes: Int64

        init(_ item: CleanupItem) {
            id = item.id
            let projectRoot = item.worktree.map { URL(fileURLWithPath: $0.mainRepoPath) } ?? item.projectRootPath
            projectID = projectRoot.map(SafetyInspector.platformPath)
                ?? "cache:\(item.category.rawValue):\(item.projectName)"
            projectName = item.projectName
            title = item.title
            path = item.path.path
            bytes = item.allocatedSizeBytes
        }
    }

    let scope: Scope
    let startedAt: Date
    let entries: [Entry]

    public init(scope: Scope, startedAt: Date, items: [CleanupItem]) {
        self.scope = scope
        self.startedAt = startedAt
        var seen = Set<String>()
        entries = items.filter { $0.containingWorktreePath == nil && seen.insert($0.id).inserted }.map(Entry.init)
    }
}

public struct ScanComparison: Equatable, Sendable {
    public struct ArtifactChange: Identifiable, Equatable, Sendable {
        public let id: String
        public let title: String
        public let path: String
        public let bytesAdded: Int64
        public let isNew: Bool
    }

    public struct ProjectChange: Identifiable, Equatable, Sendable {
        public let id: String
        public let title: String
        public let bytesAdded: Int64
        public let growingArtifacts: [ArtifactChange]
    }

    public let previousScanDate: Date
    public let currentScanDate: Date
    public let growingProjects: [ProjectChange]

    init(previous: ScanSnapshot, current: ScanSnapshot) {
        previousScanDate = previous.startedAt
        currentScanDate = current.startedAt

        let previousEntries = Dictionary(previous.entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let previousProjects = Dictionary(grouping: previous.entries, by: \.projectID)
        let currentProjects = Dictionary(grouping: current.entries, by: \.projectID)
        growingProjects = currentProjects.compactMap { projectID, entries in
            guard let first = entries.first else { return nil }
            let bytesBefore = (previousProjects[projectID] ?? []).reduce(0) { $0 + $1.bytes }
            let bytesAfter = entries.reduce(0) { $0 + $1.bytes }
            let growth = entries.compactMap { entry -> ArtifactChange? in
                let before = previousEntries[entry.id]
                let added = entry.bytes - (before?.bytes ?? 0)
                guard added > 0 else { return nil }
                return ArtifactChange(id: entry.id, title: entry.title, path: entry.path, bytesAdded: added, isNew: before == nil)
            }.sorted { $0.bytesAdded > $1.bytesAdded }
            guard !growth.isEmpty else { return nil }
            return ProjectChange(id: projectID, title: first.projectName, bytesAdded: bytesAfter - bytesBefore,
                                 growingArtifacts: growth)
        }.sorted { $0.bytesAdded == $1.bytesAdded ? $0.id < $1.id : $0.bytesAdded > $1.bytesAdded }
    }
}

public actor ScanHistoryStore {
    private let fileURL: URL

    public init(storageDirectory: URL) {
        fileURL = storageDirectory.appendingPathComponent("scan-history.json")
    }

    public func record(_ snapshot: ScanSnapshot) throws -> ScanComparison? {
        try Task.checkCancellation()
        let history = (try? Data(contentsOf: fileURL))
            .flatMap { try? JSONDecoder().decode([ScanSnapshot].self, from: $0) } ?? []
        let previous = history.first.flatMap { $0.scope == snapshot.scope ? $0 : nil }
        let updated = [snapshot] + [previous].compactMap { $0 }
        let data = try JSONEncoder().encode(updated)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Task.checkCancellation()
        try data.write(to: fileURL, options: .atomic)
        return previous.map { ScanComparison(previous: $0, current: snapshot) }
    }
}
