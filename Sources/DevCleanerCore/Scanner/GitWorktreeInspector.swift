import Foundation

public enum GitWorktreeInspector {
    private struct RawWorktreeEntry {
        var path: String = ""
        var headSHA: String? = nil
        var branchName: String? = nil
        var isBare: Bool = false
        var isLocked: Bool = false
        var isPrunable: Bool = false
    }

    /// Discovers all linked git worktrees belonging to `mainRepoDir` (never returns the main worktree itself).
    public static func discoverLinkedWorktrees(
        forMainRepo mainRepoDir: URL,
        workspaceRoot: URL,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        activeShieldWindowDays: Int = 7,
        now: Date = Date()
    ) -> [CleanupItem] {
        let fm = FileManager.default
        let standardizedMain = mainRepoDir.standardizedFileURL
        let worktreesMetaDir = standardizedMain.appendingPathComponent(".git/worktrees", isDirectory: true)

        // O(1) fast path: skip repos that have no .git/worktrees metadata directory
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: worktreesMetaDir.path, isDirectory: &isDir),
              isDir.boolValue,
              let metaEntries = try? fm.contentsOfDirectory(atPath: worktreesMetaDir.path),
              !metaEntries.isEmpty else {
            return []
        }

        guard let porcelainOutput = runGit(
            in: standardizedMain,
            arguments: ["worktree", "list", "--porcelain"],
            timeout: 2.0
        ) else {
            return []
        }

        let entries = parsePorcelain(porcelainOutput)
        guard entries.count > 1 else { return [] }

        let repoDisplayName = formatRepoName(repoDir: standardizedMain, workspaceRoot: workspaceRoot)
        let homePath = homeDirectory.standardizedFileURL.path
        var results: [CleanupItem] = []

        for (index, entry) in entries.enumerated() {
            // Index 0 is always the main worktree; also double-check canonical path
            if index == 0 || entry.isBare { continue }
            let worktreeURL = URL(fileURLWithPath: entry.path).standardizedFileURL
            if worktreeURL.path == standardizedMain.path { continue }

            let branchDisplay = entry.branchName ?? (entry.headSHA.map { String($0.prefix(7)) } ?? "detached")
            let folderLabel = worktreeURL.lastPathComponent
            let title = entry.branchName != nil ? "\(folderLabel) (\(branchDisplay))" : folderLabel

            let existsOnDisk = fm.fileExists(atPath: worktreeURL.path)
            if entry.isPrunable || !existsOnDisk {
                let metaMetrics = APFSBlockScanner.measureDirectory(at: worktreesMetaDir)
                let sizeBytes = max(Int64(4096), metaMetrics.allocatedBytes)
                let metadata = WorktreeMetadata(
                    mainRepoPath: standardizedMain.path,
                    branchName: entry.branchName,
                    isMergedIntoMain: true,
                    isLocked: false,
                    isPrunable: true
                )
                let protection = ProjectProtectionState(
                    isGitRepo: true,
                    hasUncommittedChanges: false,
                    daysSinceLastActivity: 999,
                    hasActiveProcess: false,
                    activeShieldWindowDays: activeShieldWindowDays,
                    gitBranch: entry.branchName
                )
                results.append(
                    CleanupItem(
                        id: "worktree.prune:\(standardizedMain.path):\(worktreeURL.path)",
                        ruleId: "git.worktree.prune",
                        title: "\(title) · stale metadata",
                        projectName: repoDisplayName,
                        projectRootPath: standardizedMain,
                        path: worktreeURL,
                        category: .projectArtifacts,
                        ecosystem: .git,
                        baseSafetyTier: .safeRebuildable,
                        allocatedSizeBytes: sizeBytes,
                        fileCount: max(1, metaMetrics.fileCount),
                        lastModified: metaMetrics.latestModificationDate,
                        protection: protection,
                        regenerateHint: "Directory already deleted; cleans stale metadata via 'git worktree prune'",
                        rebuildCommand: nil,
                        actionKind: .toolCommand(
                            executable: "/usr/bin/git",
                            arguments: ["-C", standardizedMain.path, "worktree", "prune"],
                            displayCommand: "git worktree prune"
                        ),
                        worktree: metadata
                    )
                )
                continue
            }

            // Linked worktree exists on disk — measure APFS size & run safety checks
            let metrics = APFSBlockScanner.measureDirectory(at: worktreeURL)
            let isDirty = checkWorktreeDirty(at: worktreeURL)
            let isMerged: Bool = {
                guard let sha = entry.headSHA, !sha.isEmpty else { return false }
                return checkCommitMergedIntoMain(sha: sha, inMainRepo: standardizedMain)
            }()

            let daysSinceActivity = max(0, Int(now.timeIntervalSince(metrics.latestModificationDate) / 86_400.0))
            let hasLockFile = fm.fileExists(atPath: worktreeURL.appendingPathComponent(".git/index.lock").path)

            let protection = ProjectProtectionState(
                isGitRepo: true,
                hasUncommittedChanges: isDirty,
                daysSinceLastActivity: daysSinceActivity,
                hasActiveProcess: hasLockFile,
                activeShieldWindowDays: activeShieldWindowDays,
                gitBranch: entry.branchName,
                isReadOnlyClone: false
            )

            let metadata = WorktreeMetadata(
                mainRepoPath: standardizedMain.path,
                branchName: entry.branchName,
                isMergedIntoMain: isMerged,
                isLocked: entry.isLocked,
                isPrunable: false
            )

            let baseTier: SafetyTier = (entry.isLocked || !isMerged) ? .protectedManual : .safeRebuildable
            let shortWorktreePath = worktreeURL.path.hasPrefix(homePath)
                ? "~" + worktreeURL.path.dropFirst(homePath.count)
                : worktreeURL.path
            let shortMainPath = standardizedMain.path.hasPrefix(homePath)
                ? "~" + standardizedMain.path.dropFirst(homePath.count)
                : standardizedMain.path

            let rebuildCmd: String? = entry.branchName.map { branch in
                "git -C \(shellQuote(shortMainPath)) worktree add \(shellQuote(shortWorktreePath)) \(branch)"
            }

            let hint: String
            if entry.isLocked {
                hint = "Locked git worktree; unlock with 'git worktree unlock' before removing"
            } else if isDirty {
                hint = "Has uncommitted or untracked changes; commit or stash before removing"
            } else if !isMerged {
                hint = "Contains commits not merged into main HEAD; review branch '\(branchDisplay)' before removing"
            } else {
                hint = "Merged & clean git worktree; safely removed via 'git worktree remove'"
            }

            results.append(
                CleanupItem(
                    id: "worktree.remove:\(worktreeURL.path)",
                    ruleId: "git.worktree",
                    title: title,
                    projectName: repoDisplayName,
                    projectRootPath: worktreeURL,
                    path: worktreeURL,
                    category: .projectArtifacts,
                    ecosystem: .git,
                    baseSafetyTier: baseTier,
                    allocatedSizeBytes: max(Int64(4096), metrics.allocatedBytes),
                    fileCount: metrics.fileCount,
                    lastModified: metrics.latestModificationDate,
                    protection: protection,
                    regenerateHint: hint,
                    rebuildCommand: rebuildCmd,
                    actionKind: .toolCommand(
                        executable: "/usr/bin/git",
                        arguments: ["-C", standardizedMain.path, "worktree", "remove", worktreeURL.path],
                        displayCommand: "git worktree remove \(shortWorktreePath)"
                    ),
                    worktree: metadata
                )
            )
        }

        return results
    }

    // MARK: - Helpers

    private static func parsePorcelain(_ output: String) -> [RawWorktreeEntry] {
        var entries: [RawWorktreeEntry] = []
        var current = RawWorktreeEntry()

        func flush() {
            if !current.path.isEmpty {
                entries.append(current)
                current = RawWorktreeEntry()
            }
        }

        for rawLine in output.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                flush()
                continue
            }
            if line.hasPrefix("worktree ") {
                current.path = String(line.dropFirst("worktree ".count))
            } else if line.hasPrefix("HEAD ") {
                current.headSHA = String(line.dropFirst("HEAD ".count))
            } else if line.hasPrefix("branch refs/heads/") {
                current.branchName = String(line.dropFirst("branch refs/heads/".count))
            } else if line.hasPrefix("branch ") {
                current.branchName = String(line.dropFirst("branch ".count))
            } else if line == "bare" {
                current.isBare = true
            } else if line == "locked" || line.hasPrefix("locked ") {
                current.isLocked = true
            } else if line == "prunable" || line.hasPrefix("prunable ") {
                current.isPrunable = true
            }
        }
        flush()
        return entries
    }

    /// Checks BOTH modified tracked files AND untracked files in a worktree (since `git worktree remove` deletes untracked files).
    private static func checkWorktreeDirty(at worktreeURL: URL) -> Bool {
        guard let output = runGit(
            in: worktreeURL,
            arguments: ["--no-optional-locks", "status", "--porcelain"],
            timeout: 2.0
        ) else {
            return true // Err on the side of safety if git status fails
        }
        return !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func checkCommitMergedIntoMain(sha: String, inMainRepo mainRepo: URL) -> Bool {
        let gitURL = URL(fileURLWithPath: "/usr/bin/git")
        guard FileManager.default.isExecutableFile(atPath: gitURL.path) else { return false }

        let process = Process()
        process.executableURL = gitURL
        process.arguments = ["-C", mainRepo.path, "merge-base", "--is-ancestor", sha, "HEAD"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return false
        }

        let deadline = Date().addingTimeInterval(1.5)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if process.isRunning {
            process.terminate()
            return false
        }
        return process.terminationStatus == 0
    }

    private static func runGit(in directory: URL, arguments: [String], timeout: TimeInterval) -> String? {
        let gitURL = URL(fileURLWithPath: "/usr/bin/git")
        guard FileManager.default.isExecutableFile(atPath: gitURL.path) else { return nil }

        let process = Process()
        process.executableURL = gitURL
        process.arguments = ["-C", directory.path] + arguments
        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return nil
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if process.isRunning {
            process.terminate()
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }

        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }

    private static func formatRepoName(repoDir: URL, workspaceRoot: URL) -> String {
        let rootPath = workspaceRoot.standardizedFileURL.path
        let repoPath = repoDir.standardizedFileURL.path
        guard repoPath.hasPrefix(rootPath + "/") else {
            return repoDir.lastPathComponent
        }
        let relative = String(repoPath.dropFirst(rootPath.count + 1))
        let components = relative.split(separator: "/").map(String.init)
        if components.count <= 1 {
            return repoDir.lastPathComponent
        }
        return "\(components.first!) / \(components.last!)"
    }

    private static func shellQuote(_ value: String) -> String {
        value.contains(" ") ? "\"\(value)\"" : value
    }
}
