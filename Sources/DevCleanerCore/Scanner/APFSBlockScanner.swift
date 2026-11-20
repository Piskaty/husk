import Foundation

public struct ScanProgressUpdate: Sendable {
    public let currentPath: String
    public let discoveredCount: Int
    public let totalAllocatedBytes: Int64

    public init(currentPath: String, discoveredCount: Int, totalAllocatedBytes: Int64) {
        self.currentPath = currentPath
        self.discoveredCount = discoveredCount
        self.totalAllocatedBytes = totalAllocatedBytes
    }
}

public struct ScanConfiguration: Sendable {
    public var workspaceRoots: [URL]
    public var homeDirectory: URL
    public var includeGlobalCaches: Bool
    public var maxWorkspaceDepth: Int
    public var activeShieldWindowDays: Int
    public var runGitStatusProcess: Bool
    /// Minimum `.git/objects` size in bytes to suggest `git gc --prune=now` (default: 60 MB).
    public var gitGCMinimumBytes: Int64
    public var now: Date

    public init(
        workspaceRoots: [URL] = CleanupRuleRegistry.defaultWorkspaceRoots(),
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        includeGlobalCaches: Bool = true,
        maxWorkspaceDepth: Int = 6,
        activeShieldWindowDays: Int = 7,
        runGitStatusProcess: Bool = true,
        gitGCMinimumBytes: Int64 = 60 * 1024 * 1024,
        now: Date = Date()
    ) {
        self.workspaceRoots = workspaceRoots.map(\.standardizedFileURL)
        self.homeDirectory = homeDirectory.standardizedFileURL
        self.includeGlobalCaches = includeGlobalCaches
        self.maxWorkspaceDepth = maxWorkspaceDepth
        self.activeShieldWindowDays = activeShieldWindowDays
        self.runGitStatusProcess = runGitStatusProcess
        self.gitGCMinimumBytes = gitGCMinimumBytes
        self.now = now
    }
}

public struct DirectoryMetrics: Sendable {
    public let allocatedBytes: Int64
    public let fileCount: Int
    public let latestModificationDate: Date
}

public struct APFSBlockScanner: Sendable {
    private static let skippedTraversalDirectories: Set<String> = [
        ".git",
        ".hg",
        ".svn",
        ".idea",
        ".vscode",
        "Library",
        "Applications"
    ]

    public init() {}

    public func scan(
        configuration: ScanConfiguration,
        onProgress: (@Sendable (ScanProgressUpdate) -> Void)? = nil
    ) async -> [CleanupItem] {
        let gitCache = GitInspectionCache()
        let inspector = SafetyInspector(
            activeShieldWindowDays: configuration.activeShieldWindowDays,
            homeDirectory: configuration.homeDirectory,
            gitCache: gitCache
        )

        // 1. Discover candidate targets (workspace artifact folders + git roots + fixed global cache folders)
        var projectCandidates: [(artifactURL: URL, projectDir: URL, workspaceRoot: URL, rule: ProjectArtifactRule)] = []
        var gitRepoCandidates: [(gitObjectsURL: URL, repoDir: URL, workspaceRoot: URL)] = []

        for root in configuration.workspaceRoots {
            let discovered = discoverProjectCandidates(
                in: root,
                maxDepth: configuration.maxWorkspaceDepth
            )
            projectCandidates.append(contentsOf: discovered.artifacts)
            gitRepoCandidates.append(contentsOf: discovered.gitRepos)
        }

        var fixedCandidates: [(targetURL: URL, displayTitle: String, rule: FixedCacheRule)] = []
        if configuration.includeGlobalCaches {
            fixedCandidates = discoverFixedCacheCandidates(homeDirectory: configuration.homeDirectory)
        }

        // 2. Measure APFS disk block usage & inspect project safety concurrently
        var results: [CleanupItem] = []
        var totalBytes: Int64 = 0

        await withTaskGroup(of: CleanupItem?.self) { group in
            for candidate in projectCandidates {
                group.addTask {
                    guard !Task.isCancelled else { return nil }
                    let metrics = Self.measureDirectory(at: candidate.artifactURL)
                    guard metrics.allocatedBytes > 0 else { return nil }

                    let protection = await inspector.inspectProjectProtection(
                        projectDirectory: candidate.projectDir,
                        artifactURL: candidate.artifactURL,
                        artifactLastModified: metrics.latestModificationDate,
                        stopAtRoot: candidate.workspaceRoot,
                        runGitProcess: configuration.runGitStatusProcess,
                        now: configuration.now
                    )

                    let projectName = Self.formatProjectName(
                        projectDir: candidate.projectDir,
                        workspaceRoot: candidate.workspaceRoot
                    )

                    let rebuildCommand = SafetyInspector.inferRebuildCommand(
                        for: candidate.projectDir,
                        ecosystem: candidate.rule.ecosystem,
                        homeDirectory: configuration.homeDirectory
                    )

                    return CleanupItem(
                        ruleId: candidate.rule.id,
                        title: candidate.rule.displayTitle,
                        projectName: projectName,
                        projectRootPath: candidate.projectDir,
                        path: candidate.artifactURL,
                        category: .projectArtifacts,
                        ecosystem: candidate.rule.ecosystem,
                        baseSafetyTier: candidate.rule.safetyTier,
                        allocatedSizeBytes: metrics.allocatedBytes,
                        fileCount: metrics.fileCount,
                        lastModified: metrics.latestModificationDate,
                        protection: protection,
                        regenerateHint: candidate.rule.regenerateHint,
                        rebuildCommand: rebuildCommand,
                        actionKind: .filesystem
                    )
                }
            }

            // Native Tool Subcommand Cleaner 1: Bloated Git Object Packfiles (`git gc --prune=now`)
            for gitCandidate in gitRepoCandidates {
                group.addTask {
                    guard !Task.isCancelled else { return nil }
                    let metrics = Self.measureDirectory(at: gitCandidate.gitObjectsURL)
                    guard metrics.allocatedBytes >= configuration.gitGCMinimumBytes else { return nil }

                    let protection = await inspector.inspectProjectProtection(
                        projectDirectory: gitCandidate.repoDir,
                        artifactURL: gitCandidate.gitObjectsURL,
                        artifactLastModified: metrics.latestModificationDate,
                        stopAtRoot: gitCandidate.workspaceRoot,
                        runGitProcess: configuration.runGitStatusProcess,
                        now: configuration.now
                    )

                    let projectName = Self.formatProjectName(
                        projectDir: gitCandidate.repoDir,
                        workspaceRoot: gitCandidate.workspaceRoot
                    )

                    return CleanupItem(
                        id: "tool.git_gc:\(gitCandidate.gitObjectsURL.path)",
                        ruleId: "git.gc",
                        title: ".git/objects (git gc)",
                        projectName: projectName,
                        projectRootPath: gitCandidate.repoDir,
                        path: gitCandidate.gitObjectsURL,
                        category: .projectArtifacts,
                        ecosystem: .git,
                        baseSafetyTier: .cautionRedownload,
                        allocatedSizeBytes: metrics.allocatedBytes,
                        fileCount: metrics.fileCount,
                        lastModified: metrics.latestModificationDate,
                        protection: protection,
                        regenerateHint: "Compacts git packfiles safely via 'git gc --prune=now'",
                        rebuildCommand: nil,
                        actionKind: .toolCommand(
                            executable: "/usr/bin/git",
                            arguments: ["-C", gitCandidate.repoDir.path, "gc", "--prune=now", "--quiet"],
                            displayCommand: "git gc --prune=now"
                        )
                    )
                }
            }

            for fixed in fixedCandidates {
                group.addTask {
                    guard !Task.isCancelled else { return nil }
                    let metrics = Self.measureDirectory(at: fixed.targetURL)
                    guard metrics.allocatedBytes > 0 else { return nil }

                    let daysOld = max(0, Int(configuration.now.timeIntervalSince(metrics.latestModificationDate) / 86_400.0))
                    let protection = ProjectProtectionState(
                        isGitRepo: false,
                        hasUncommittedChanges: false,
                        daysSinceLastActivity: daysOld,
                        hasActiveProcess: false,
                        activeShieldWindowDays: configuration.activeShieldWindowDays,
                        gitBranch: nil,
                        isReadOnlyClone: false
                    )

                    // Native Tool Subcommand Cleaner 2: Homebrew CLI cleanup when brew binary is installed
                    var actionKind: CleanupActionKind = .filesystem
                    if fixed.rule.id == "cache.homebrew",
                       let brewBin = Self.findExecutable(candidates: ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]) {
                        actionKind = .toolCommand(
                            executable: brewBin,
                            arguments: ["cleanup", "--prune=all", "-s"],
                            displayCommand: "brew cleanup --prune=all -s"
                        )
                    }

                    return CleanupItem(
                        ruleId: fixed.rule.id,
                        title: fixed.displayTitle,
                        projectName: fixed.rule.projectName,
                        projectRootPath: nil,
                        path: fixed.targetURL,
                        category: fixed.rule.category,
                        ecosystem: fixed.rule.ecosystem,
                        baseSafetyTier: fixed.rule.safetyTier,
                        allocatedSizeBytes: metrics.allocatedBytes,
                        fileCount: metrics.fileCount,
                        lastModified: metrics.latestModificationDate,
                        protection: protection,
                        regenerateHint: fixed.rule.regenerateHint,
                        rebuildCommand: nil,
                        actionKind: actionKind
                    )
                }
            }

            // Native Tool Subcommand Cleaner 3: Unavailable iOS Simulators (`xcrun simctl delete unavailable`)
            if configuration.includeGlobalCaches {
                group.addTask {
                    guard !Task.isCancelled else { return nil }
                    return Self.discoverUnavailableSimulatorsItem(
                        homeDirectory: configuration.homeDirectory,
                        activeShieldWindowDays: configuration.activeShieldWindowDays,
                        now: configuration.now
                    )
                }
            }

            for await maybeItem in group {
                guard let item = maybeItem else { continue }
                results.append(item)
                totalBytes += item.allocatedSizeBytes
                onProgress?(
                    ScanProgressUpdate(
                        currentPath: item.displayPath,
                        discoveredCount: results.count,
                        totalAllocatedBytes: totalBytes
                    )
                )
            }
        }

        // 3. Discover Linked Git Worktrees across all discovered main repositories
        var worktreeItems: [CleanupItem] = []
        await withTaskGroup(of: [CleanupItem].self) { group in
            for gitCandidate in gitRepoCandidates {
                group.addTask {
                    guard !Task.isCancelled else { return [] }
                    return GitWorktreeInspector.discoverLinkedWorktrees(
                        forMainRepo: gitCandidate.repoDir,
                        workspaceRoot: gitCandidate.workspaceRoot,
                        homeDirectory: configuration.homeDirectory,
                        activeShieldWindowDays: configuration.activeShieldWindowDays,
                        now: configuration.now
                    )
                }
            }
            for await batch in group {
                for item in batch {
                    worktreeItems.append(item)
                    totalBytes += item.allocatedSizeBytes
                    onProgress?(
                        ScanProgressUpdate(
                            currentPath: item.displayPath,
                            discoveredCount: results.count + worktreeItems.count,
                            totalAllocatedBytes: totalBytes
                        )
                    )
                }
            }
        }

        // Avoid double-counting project artifacts that reside inside a discovered linked worktree
        let worktreePaths = worktreeItems
            .filter { $0.worktree?.isPrunable != true }
            .map { $0.path.standardizedFileURL.path }

        if !worktreePaths.isEmpty {
            results.removeAll { item in
                guard item.worktree == nil, item.category == .projectArtifacts else { return false }
                let itemPath = item.path.standardizedFileURL.path
                return worktreePaths.contains { wtPath in
                    itemPath == wtPath || itemPath.hasPrefix(wtPath + "/")
                }
            }
        }
        results.append(contentsOf: worktreeItems)

        // Deduplicate by item.id and sort descending by physical allocated bytes
        var seen = Set<String>()
        var unique: [CleanupItem] = []
        for item in results.sorted(by: { $0.allocatedSizeBytes > $1.allocatedSizeBytes }) {
            if !seen.contains(item.id) {
                seen.insert(item.id)
                unique.append(item)
            }
        }
        return unique
    }

    // MARK: - Candidate Discovery

    private func discoverProjectCandidates(
        in workspaceRoot: URL,
        maxDepth: Int
    ) -> (
        artifacts: [(artifactURL: URL, projectDir: URL, workspaceRoot: URL, rule: ProjectArtifactRule)],
        gitRepos: [(gitObjectsURL: URL, repoDir: URL, workspaceRoot: URL)]
    ) {
        let fm = FileManager.default
        let rootURL = workspaceRoot.standardizedFileURL
        guard !SafetyInspector.isSymbolicLink(at: rootURL) else { return ([], []) }

        var matches: [(artifactURL: URL, projectDir: URL, workspaceRoot: URL, rule: ProjectArtifactRule)] = []
        var gitRepos: [(gitObjectsURL: URL, repoDir: URL, workspaceRoot: URL)] = []
        var queue: [(url: URL, depth: Int)] = [(rootURL, 0)]

        while !queue.isEmpty {
            let current = queue.removeFirst()
            if current.depth >= maxDepth {
                continue
            }

            guard let childURLs = try? fm.contentsOfDirectory(
                at: current.url,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsPackageDescendants]
            ) else {
                continue
            }

            for childURL in childURLs {
                let name = childURL.lastPathComponent
                if name == ".DS_Store" {
                    continue
                }
                if SafetyInspector.isSymbolicLink(at: childURL) {
                    continue
                }

                // Check for .git/objects packfiles before skipping .git directory traversal
                if name == ".git" {
                    let objectsURL = childURL.appendingPathComponent("objects", isDirectory: true).standardizedFileURL
                    var isDir: ObjCBool = false
                    if fm.fileExists(atPath: objectsURL.path, isDirectory: &isDir), isDir.boolValue {
                        gitRepos.append((
                            gitObjectsURL: objectsURL,
                            repoDir: current.url.standardizedFileURL,
                            workspaceRoot: rootURL
                        ))
                    }
                    continue
                }

                if Self.skippedTraversalDirectories.contains(name) {
                    continue
                }

                guard let values = try? childURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                      values.isDirectory == true,
                      values.isSymbolicLink != true else {
                    continue
                }

                // Check if this folder matches a ProjectArtifactRule with a valid parent manifest
                if let rule = SafetyInspector.matchingProjectRule(forFolderNamed: name, inParent: current.url) {
                    matches.append((
                        artifactURL: childURL.standardizedFileURL,
                        projectDir: current.url.standardizedFileURL,
                        workspaceRoot: rootURL,
                        rule: rule
                    ))
                    continue
                }

                if name == "node_modules" || name == ".venv" || name == "__pycache__" {
                    continue
                }

                if name.hasPrefix(".") && CleanupRuleRegistry.rulesByFolderName[name] == nil {
                    continue
                }

                queue.append((childURL, current.depth + 1))
            }
        }

        return (matches, gitRepos)
    }

    private func discoverFixedCacheCandidates(
        homeDirectory: URL
    ) -> [(targetURL: URL, displayTitle: String, rule: FixedCacheRule)] {
        let fm = FileManager.default
        var results: [(targetURL: URL, displayTitle: String, rule: FixedCacheRule)] = []

        for rule in CleanupRuleRegistry.fixedCacheRules {
            let baseURL = homeDirectory.appendingPathComponent(rule.relativePathFromHome).standardizedFileURL
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: baseURL.path, isDirectory: &isDir), isDir.boolValue else {
                continue
            }
            guard !SafetyInspector.isSymbolicLink(at: baseURL) else {
                continue
            }

            if rule.expandTopLevelChildren {
                guard let children = try? fm.contentsOfDirectory(
                    at: baseURL,
                    includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                    options: []
                ) else {
                    continue
                }

                for child in children {
                    let childName = child.lastPathComponent
                    if childName == ".DS_Store" || SafetyInspector.isSymbolicLink(at: child) {
                        continue
                    }
                    let formattedTitle = Self.formatExpandedChildTitle(childName: childName, rule: rule)
                    results.append((
                        targetURL: child.standardizedFileURL,
                        displayTitle: formattedTitle,
                        rule: rule
                    ))
                }
            } else {
                results.append((
                    targetURL: baseURL,
                    displayTitle: rule.title,
                    rule: rule
                ))
            }
        }

        return results
    }

    // MARK: - Unavailable iOS Simulators Detector

    private static func discoverUnavailableSimulatorsItem(
        homeDirectory: URL,
        activeShieldWindowDays: Int,
        now: Date
    ) -> CleanupItem? {
        let devicesDir = homeDirectory.appendingPathComponent("Library/Developer/CoreSimulator/Devices", isDirectory: true).standardizedFileURL
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: devicesDir.path, isDirectory: &isDir), isDir.boolValue else {
            return nil
        }
        guard fm.isExecutableFile(atPath: "/usr/bin/xcrun") else {
            return nil
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["simctl", "list", "devices", "unavailable", "-j"]
        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return nil
        }

        let deadline = Date().addingTimeInterval(2.0)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if process.isRunning {
            process.terminate()
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }

        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let devicesByRuntime = json["devices"] as? [String: [[String: Any]]] else {
            return nil
        }

        var unavailableUDIDs: [String] = []
        for (_, deviceList) in devicesByRuntime {
            for device in deviceList {
                if let udid = device["udid"] as? String {
                    unavailableUDIDs.append(udid)
                }
            }
        }
        guard !unavailableUDIDs.isEmpty else { return nil }

        var totalBytes: Int64 = 0
        var totalFiles: Int = 0
        var latestDate: Date = .distantPast

        for udid in unavailableUDIDs {
            let udidURL = devicesDir.appendingPathComponent(udid, isDirectory: true)
            let metrics = measureDirectory(at: udidURL)
            totalBytes += metrics.allocatedBytes
            totalFiles += metrics.fileCount
            if metrics.latestModificationDate > latestDate {
                latestDate = metrics.latestModificationDate
            }
        }

        guard totalBytes > 0 else { return nil }
        let daysOld = max(0, Int(now.timeIntervalSince(latestDate) / 86_400.0))

        return CleanupItem(
            id: "tool.simctl_unavailable:\(devicesDir.path)",
            ruleId: "xcode.unavailable_simulators",
            title: "Unavailable Simulators (\(unavailableUDIDs.count))",
            projectName: "Xcode Simulators",
            projectRootPath: nil,
            path: devicesDir,
            category: .xcodeClutter,
            ecosystem: .xcode,
            baseSafetyTier: .cautionRedownload,
            allocatedSizeBytes: totalBytes,
            fileCount: totalFiles,
            lastModified: latestDate == .distantPast ? now : latestDate,
            protection: ProjectProtectionState(
                isGitRepo: false,
                hasUncommittedChanges: false,
                daysSinceLastActivity: daysOld,
                hasActiveProcess: false,
                activeShieldWindowDays: activeShieldWindowDays
            ),
            regenerateHint: "Removes dead simulator instances via 'xcrun simctl delete unavailable'",
            rebuildCommand: nil,
            actionKind: .toolCommand(
                executable: "/usr/bin/xcrun",
                arguments: ["simctl", "delete", "unavailable"],
                displayCommand: "xcrun simctl delete unavailable"
            )
        )
    }

    private static func findExecutable(candidates: [String]) -> String? {
        let fm = FileManager.default
        return candidates.first { fm.isExecutableFile(atPath: $0) }
    }

    // MARK: - APFS Physical Disk Block Measurement

    public static func measureDirectory(at directoryURL: URL) -> DirectoryMetrics {
        let fm = FileManager.default
        guard !SafetyInspector.isSymbolicLink(at: directoryURL) else {
            return DirectoryMetrics(allocatedBytes: 0, fileCount: 0, latestModificationDate: .distantPast)
        }

        let fallbackModDate: Date = (try? fm.attributesOfItem(atPath: directoryURL.path)[.modificationDate] as? Date) ?? Date()
        var latestModDate: Date = .distantPast

        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: directoryURL.path, isDirectory: &isDir) else {
            return DirectoryMetrics(allocatedBytes: 0, fileCount: 0, latestModificationDate: fallbackModDate)
        }
        if !isDir.boolValue {
            let size = singleFileAllocatedBytes(at: directoryURL)
            return DirectoryMetrics(allocatedBytes: size, fileCount: 1, latestModificationDate: fallbackModDate)
        }

        let keys: [URLResourceKey] = [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .totalFileAllocatedSizeKey,
            .fileAllocatedSizeKey,
            .fileSizeKey,
            .contentModificationDateKey,
            .linkCountKey,
            .fileResourceIdentifierKey
        ]

        guard let enumerator = fm.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: { _, _ in true }
        ) else {
            return DirectoryMetrics(allocatedBytes: 0, fileCount: 0, latestModificationDate: fallbackModDate)
        }

        var totalBytes: Int64 = 0
        var fileCount: Int = 0
        var seenHardLinkIDs: Set<Data> = []

        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: Set(keys)) else {
                continue
            }

            if values.isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }

            guard values.isRegularFile == true else {
                continue
            }

            if let mtime = values.contentModificationDate, mtime > latestModDate {
                latestModDate = mtime
            }

            if let linkCount = values.linkCount, linkCount > 1,
               let resourceID = values.fileResourceIdentifier as? Data {
                if seenHardLinkIDs.contains(resourceID) {
                    fileCount += 1
                    continue
                }
                seenHardLinkIDs.insert(resourceID)
            }

            let allocated = values.totalFileAllocatedSize
                ?? values.fileAllocatedSize
                ?? values.fileSize
                ?? 0

            totalBytes += Int64(allocated)
            fileCount += 1
        }

        return DirectoryMetrics(
            allocatedBytes: totalBytes,
            fileCount: fileCount,
            latestModificationDate: latestModDate == .distantPast ? fallbackModDate : latestModDate
        )
    }

    private static func singleFileAllocatedBytes(at fileURL: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey]
        if let values = try? fileURL.resourceValues(forKeys: keys) {
            let bytes = values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values.fileSize ?? 0
            return Int64(bytes)
        }
        return 0
    }

    private static func formatProjectName(projectDir: URL, workspaceRoot: URL) -> String {
        let rootPath = workspaceRoot.standardizedFileURL.path
        let projPath = projectDir.standardizedFileURL.path
        guard projPath.hasPrefix(rootPath + "/") else {
            return projectDir.lastPathComponent
        }
        let relative = String(projPath.dropFirst(rootPath.count + 1))
        let components = relative.split(separator: "/").map(String.init)
        if components.count <= 1 {
            return projectDir.lastPathComponent
        }
        return "\(components.first!) / \(components.last!)"
    }

    private static func formatExpandedChildTitle(childName: String, rule: FixedCacheRule) -> String {
        if rule.id == "ai.huggingface_hub" {
            if childName.hasPrefix("models--") {
                let trimmed = childName.dropFirst("models--".count)
                return trimmed.replacingOccurrences(of: "--", with: "/")
            } else if childName.hasPrefix("datasets--") {
                let trimmed = childName.dropFirst("datasets--".count)
                return "dataset: " + trimmed.replacingOccurrences(of: "--", with: "/")
            }
        } else if rule.id == "xcode.derived_data" {
            let parts = childName.split(separator: "-")
            if parts.count >= 2, let last = parts.last, last.count >= 12 {
                let prefix = parts.dropLast().joined(separator: "-")
                return "\(prefix) (DerivedData)"
            }
        }
        return childName
    }
}
