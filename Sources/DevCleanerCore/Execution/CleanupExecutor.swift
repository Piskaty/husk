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
        allowedWorkspaceRoots: [URL]
    ) throws -> CleanupSessionRecord {
        let fm = FileManager.default
        var records: [CleanedItemRecord] = []
        var totalReclaimed: Int64 = 0

        for item in items {
            switch safetyInspector.validateDeletionItem(item, allowedWorkspaceRoots: allowedWorkspaceRoots) {
            case .failure(let safetyError):
                records.append(
                    CleanedItemRecord(
                        title: item.title,
                        projectName: item.projectName,
                        category: item.category,
                        ecosystem: item.ecosystem,
                        originalPath: item.path.path,
                        trashedPath: nil,
                        sizeBytes: 0,
                        isRestored: false,
                        errorDescription: safetyError.localizedDescription,
                        rebuildCommand: item.rebuildCommand
                    )
                )
                continue
            case .success:
                break
            }

            if dryRun {
                records.append(
                    CleanedItemRecord(
                        title: item.title,
                        projectName: item.projectName,
                        category: item.category,
                        ecosystem: item.ecosystem,
                        originalPath: item.path.path,
                        trashedPath: nil,
                        sizeBytes: item.allocatedSizeBytes,
                        isRestored: false,
                        errorDescription: nil,
                        rebuildCommand: item.rebuildCommand
                    )
                )
                totalReclaimed += item.allocatedSizeBytes
                continue
            }

            do {
                switch item.actionKind {
                case .toolCommand(let executable, let arguments, _):
                    let bytesBefore = item.allocatedSizeBytes
                    try runToolSubcommand(executable: executable, arguments: arguments)
                    let bytesAfter = APFSBlockScanner.measureDirectory(at: item.path).allocatedBytes
                    let saved = max(0, bytesBefore - bytesAfter)
                    let effectiveReclaimed = saved > 0 ? saved : bytesBefore

                    totalReclaimed += effectiveReclaimed
                    records.append(
                        CleanedItemRecord(
                            title: item.title,
                            projectName: item.projectName,
                            category: item.category,
                            ecosystem: item.ecosystem,
                            originalPath: item.path.path,
                            trashedPath: nil,
                            sizeBytes: effectiveReclaimed,
                            isRestored: false,
                            errorDescription: nil,
                            rebuildCommand: item.rebuildCommand
                        )
                    )

                case .filesystem:
                    guard fm.fileExists(atPath: item.path.path) else {
                        continue
                    }

                    var trashedPath: String? = nil
                    switch mode {
                    case .moveToTrash:
                        let destinationURL = try moveItemToTrash(at: item.path)
                        trashedPath = destinationURL.path
                    case .permanentDelete:
                        try fm.removeItem(at: item.path)
                    }

                    totalReclaimed += item.allocatedSizeBytes
                    records.append(
                        CleanedItemRecord(
                            title: item.title,
                            projectName: item.projectName,
                            category: item.category,
                            ecosystem: item.ecosystem,
                            originalPath: item.path.path,
                            trashedPath: trashedPath,
                            sizeBytes: item.allocatedSizeBytes,
                            isRestored: false,
                            errorDescription: nil,
                            rebuildCommand: item.rebuildCommand
                        )
                    )
                }
            } catch {
                records.append(
                    CleanedItemRecord(
                        title: item.title,
                        projectName: item.projectName,
                        category: item.category,
                        ecosystem: item.ecosystem,
                        originalPath: item.path.path,
                        trashedPath: nil,
                        sizeBytes: 0,
                        isRestored: false,
                        errorDescription: error.localizedDescription,
                        rebuildCommand: item.rebuildCommand
                    )
                )
            }
        }

        let session = CleanupSessionRecord(
            mode: mode,
            wasDryRun: dryRun,
            totalBytesReclaimed: totalReclaimed,
            items: records
        )
        try auditStore.recordSession(session)
        return session
    }

    @discardableResult
    public func undoSession(_ session: CleanupSessionRecord) throws -> CleanupSessionRecord {
        let fm = FileManager.default
        var updatedSession = session

        for index in updatedSession.items.indices {
            let record = updatedSession.items[index]
            guard record.canRestore, let trashedPath = record.trashedPath else {
                continue
            }
            let trashedURL = URL(fileURLWithPath: trashedPath)
            let originalURL = URL(fileURLWithPath: record.originalPath)

            guard fm.fileExists(atPath: trashedURL.path),
                  !fm.fileExists(atPath: originalURL.path) else {
                continue
            }

            let parentDir = originalURL.deletingLastPathComponent()
            try fm.createDirectory(at: parentDir, withIntermediateDirectories: true)
            try fm.moveItem(at: trashedURL, to: originalURL)
            updatedSession.items[index].isRestored = true
        }

        try auditStore.updateSession(updatedSession)
        return updatedSession
    }

    private func runToolSubcommand(executable: String, arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let errPipe = Pipe()
        process.standardOutput = Pipe()
        process.standardError = errPipe

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let errMsg = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Command exited with status \(process.terminationStatus)"
            throw NSError(domain: "HuskToolCommandError", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: errMsg])
        }
    }

    private func moveItemToTrash(at sourceURL: URL) throws -> URL {
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

        return sourceURL
    }
}
