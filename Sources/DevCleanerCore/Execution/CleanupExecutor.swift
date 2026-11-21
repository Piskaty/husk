import Darwin
import Foundation

public struct CleanupExecutor: Sendable {
    public let safetyInspector: SafetyInspector
    public let auditStore: AuditLogStore
    public let customTrashDirectory: URL?

    public init(
        safetyInspector: SafetyInspector = SafetyInspector(),
        auditStore: AuditLogStore = AuditLogStore(),
        customTrashDirectory: URL? = nil
    ) {
        self.safetyInspector = safetyInspector
        self.auditStore = auditStore
        self.customTrashDirectory = customTrashDirectory
    }

    public func buildDryRunManifest(items: [CleanupItem], mode: DeletionMode) -> DryRunManifest {
        DryRunManifest(items: items, mode: mode)
    }

    public func execute(
        items: [CleanupItem],
        mode: DeletionMode,
        dryRun: Bool = false,
        allowedWorkspaceRoots: [URL],
        allowIrreversibleToolTasks: Bool = false
    ) throws -> CleanupSessionRecord {
        let fm = FileManager.default
        var records: [CleanedItemRecord] = []
        var totalReclaimed: Int64 = 0
        let selectedWorktrees = Set(items.filter { $0.worktree?.isPrunable == false }.map(\.path))

        for item in items {
            func record(size: Int64, trashedPath: String? = nil, error: Error? = nil) -> CleanedItemRecord {
                CleanedItemRecord(
                    title: item.title,
                    projectName: item.projectName,
                    category: item.category,
                    ecosystem: item.ecosystem,
                    originalPath: item.path.path,
                    trashedPath: trashedPath,
                    sizeBytes: size,
                    isRestored: false,
                    errorDescription: error?.localizedDescription,
                    rebuildCommand: item.rebuildCommand,
                    wasToolCommand: item.actionKind.isToolCommand
                )
            }

            do {
                if let worktree = item.containingWorktreePath, selectedWorktrees.contains(worktree) {
                    throw Failure.overlappingWorktreeSelection
                }
                try validateCurrentTarget(item, allowedWorkspaceRoots: allowedWorkspaceRoots, checkContents: dryRun)
                if dryRun {
                    records.append(record(size: item.allocatedSizeBytes))
                    totalReclaimed += item.allocatedSizeBytes
                    continue
                }

                switch item.actionKind {
                case .toolCommand(let executable, let arguments, _):
                    guard allowIrreversibleToolTasks else { throw Failure.unconfirmedToolTask }
                    let measuredPath = measurementPath(for: item)
                    let before = APFSBlockScanner.measureDirectory(at: measuredPath).allocatedBytes
                    let volumeProbe = measuredPath.deletingLastPathComponent()
                    let freeBefore = availableBytes(at: volumeProbe)
                    try validateCurrentTarget(item, allowedWorkspaceRoots: allowedWorkspaceRoots)
                    try CommandRunner.run(executable, arguments: arguments, timeout: 120)
                    let after = APFSBlockScanner.measureDirectory(at: measuredPath).allocatedBytes
                    let removed = max(0, before - after)
                    totalReclaimed += freeSpaceGain(before: freeBefore, at: volumeProbe, upTo: removed)
                    records.append(record(size: removed))

                case .filesystem:
                    let volumeProbe = item.path.deletingLastPathComponent()
                    let freeBefore = availableBytes(at: volumeProbe)
                    try validateCurrentTarget(item, allowedWorkspaceRoots: allowedWorkspaceRoots)
                    switch mode {
                    case .moveToTrash:
                        let destination = try moveItemToTrash(at: item.path)
                        records.append(record(size: item.allocatedSizeBytes, trashedPath: destination?.path))
                    case .permanentDelete:
                        try fm.removeItem(at: item.path)
                        totalReclaimed += freeSpaceGain(before: freeBefore, at: volumeProbe, upTo: item.allocatedSizeBytes)
                        records.append(record(size: item.allocatedSizeBytes))
                    }
                }
            } catch {
                records.append(record(size: 0, error: error))
            }
        }

        let session = CleanupSessionRecord(
            mode: mode,
            wasDryRun: dryRun,
            totalBytesReclaimed: totalReclaimed,
            items: records,
            usesObservedFreeSpace: true
        )
        try auditStore.recordSession(session)
        return session
    }

    private func validateCurrentTarget(_ item: CleanupItem, allowedWorkspaceRoots: [URL], checkContents: Bool = true) throws {
        try safetyInspector.validateDeletionItem(item, allowedWorkspaceRoots: allowedWorkspaceRoots).get()
        let currentIdentity = CleanupTargetIdentity.read(at: item.path)

        if item.worktree?.isPrunable == true {
            guard item.targetIdentity == nil, currentIdentity == nil,
                  !FileManager.default.fileExists(atPath: item.path.path) else {
                throw SafetyValidationError.targetChanged(item.path.path)
            }
            return
        }

        guard let currentIdentity, currentIdentity == item.targetIdentity else {
            throw SafetyValidationError.targetChanged(item.path.path)
        }

        guard checkContents else { return }

        if item.category == .projectArtifacts && !item.actionKind.isToolCommand {
            if let worktree = item.containingWorktreePath {
                guard SafetyInspector.matchingProjectRule(forFolderNamed: item.path.lastPathComponent,
                    inParent: item.path.deletingLastPathComponent())?.id == item.ruleId,
                    GitWorktreeInspector.canCleanArtifact(item.path, in: worktree) else {
                    throw Failure.unsafeWorktreeArtifact
                }
            }
            if let error = SafetyInspector.projectArtifactTreeError(for: item.path) { throw error }
            try safetyInspector.validateDeletionItem(item, allowedWorkspaceRoots: allowedWorkspaceRoots).get()
            guard CleanupTargetIdentity.read(at: item.path) == currentIdentity else {
                throw SafetyValidationError.targetChanged(item.path.path)
            }
        }

        if let worktree = item.worktree {
            let mainRepo = URL(fileURLWithPath: worktree.mainRepoPath, isDirectory: true)
            guard GitWorktreeInspector.canRemove(item.path, from: mainRepo) else {
                throw Failure.unsafeWorktree
            }
            try safetyInspector.validateDeletionItem(item, allowedWorkspaceRoots: allowedWorkspaceRoots).get()
            guard CleanupTargetIdentity.read(at: item.path) == currentIdentity else {
                throw SafetyValidationError.targetChanged(item.path.path)
            }
        }
    }

    private func measurementPath(for item: CleanupItem) -> URL {
        if let worktree = item.worktree, worktree.isPrunable {
            return URL(fileURLWithPath: worktree.mainRepoPath).appendingPathComponent(".git/worktrees")
        }
        return item.path
    }

    private func availableBytes(at url: URL) -> Int64? {
        var info = statfs()
        guard statfs(url.path, &info) == 0 else { return nil }
        return Int64(clamping: info.f_bavail * UInt64(info.f_bsize))
    }

    private func freeSpaceGain(before: Int64?, at url: URL, upTo removed: Int64) -> Int64 {
        guard removed > 0, let before, let after = availableBytes(at: url) else { return 0 }
        return min(removed, max(0, after - before))
    }

    private enum Failure: LocalizedError {
        case unconfirmedToolTask
        case unsafeWorktree
        case unsafeWorktreeArtifact
        case overlappingWorktreeSelection

        var errorDescription: String? {
            switch self {
            case .unconfirmedToolTask:
                return "Running irreversible tool tasks requires explicit confirmation."
            case .unsafeWorktree:
                return "The worktree must be merged, unlocked, and free of modified, untracked, or ignored files."
            case .unsafeWorktreeArtifact:
                return "The folder must match a build rule and contain no Git-tracked files. Rescan to review it."
            case .overlappingWorktreeSelection:
                return "Select the worktree or its build folders individually."
            }
        }
    }

    @discardableResult
    public func undoSession(_ session: CleanupSessionRecord) throws -> CleanupSessionRecord {
        let fm = FileManager.default
        var updatedSession = session

        for index in updatedSession.items.indices {
            let record = updatedSession.items[index]
            guard let trashedURL = record.existingTrashURL else {
                continue
            }
            let originalURL = URL(fileURLWithPath: record.originalPath)

            guard !fm.fileExists(atPath: originalURL.path) else {
                continue
            }

            if let error = SafetyInspector.pathComponentError(for: originalURL)
                ?? SafetyInspector.pathComponentError(for: trashedURL) {
                throw error
            }
            let parentDir = originalURL.deletingLastPathComponent()
            try fm.createDirectory(at: parentDir, withIntermediateDirectories: true)
            guard record.existingTrashURL == trashedURL else { continue }
            try fm.moveItem(at: trashedURL, to: originalURL)
            updatedSession.items[index].isRestored = true
        }

        try auditStore.updateSession(updatedSession)
        return updatedSession
    }

    private func moveItemToTrash(at sourceURL: URL) throws -> URL? {
        let fm = FileManager.default
        if let customTrashDirectory {
            try fm.createDirectory(at: customTrashDirectory, withIntermediateDirectories: true)
            let uniqueName = "\(UUID().uuidString.prefix(8))-\(sourceURL.lastPathComponent)"
            let destURL = customTrashDirectory.appendingPathComponent(uniqueName).standardizedFileURL
            try fm.moveItem(at: sourceURL, to: destURL)
            return destURL
        }

        var resultingNSURL: NSURL?
        do {
            try fm.trashItem(at: sourceURL, resultingItemURL: &resultingNSURL)
            if let resultingURL = resultingNSURL as URL? {
                return resultingURL.standardizedFileURL
            }
        } catch {
            let fallbackTrash = safetyInspector.homeDirectory.appendingPathComponent(".Trash", isDirectory: true)
            try fm.createDirectory(at: fallbackTrash, withIntermediateDirectories: true)
            let uniqueName = "\(sourceURL.lastPathComponent)-\(UUID().uuidString.prefix(8))"
            let destURL = fallbackTrash.appendingPathComponent(uniqueName).standardizedFileURL
            try fm.moveItem(at: sourceURL, to: destURL)
            return destURL
        }

        return nil
    }
}
