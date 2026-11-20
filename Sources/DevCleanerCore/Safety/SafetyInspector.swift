import Foundation

public actor GitInspectionCache {
    public struct CachedGitState: Sendable {
        public let isGitRepo: Bool
        public let hasUncommittedChanges: Bool
        public let gitBranch: String?
        public let latestGitTimestamp: Date?
        public let isReadOnlyClone: Bool
    }

    private var cache: [String: CachedGitState] = [:]

    public init() {}

    public func state(for gitRoot: URL, runGitProcess: Bool = true) -> CachedGitState {
        let key = gitRoot.standardizedFileURL.path
        if let existing = cache[key] {
            return existing
        }
        let computed = Self.computeGitState(at: gitRoot, runGitProcess: runGitProcess)
        cache[key] = computed
        return computed
    }

    public func clear() {
        cache.removeAll()
    }

    private static func computeGitState(at gitRoot: URL, runGitProcess: Bool) -> CachedGitState {
        let fm = FileManager.default
        let gitDir = gitRoot.appendingPathComponent(".git")
        guard fm.fileExists(atPath: gitDir.path) else {
            return CachedGitState(
                isGitRepo: false,
                hasUncommittedChanges: false,
                gitBranch: nil,
                latestGitTimestamp: nil,
                isReadOnlyClone: false
            )
        }

        // Parse branch name from .git/HEAD without spawning a process
        var branchName: String? = nil
        let headFile = gitDir.appendingPathComponent("HEAD")
        if let headContents = try? String(contentsOf: headFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) {
            if headContents.hasPrefix("ref: refs/heads/") {
                branchName = String(headContents.dropFirst("ref: refs/heads/".count))
            } else if headContents.count >= 7 {
                branchName = String(headContents.prefix(7))
            }
        }

        // Check if .git/logs/HEAD indicates a repository that was cloned once and never committed to
        var isReadOnlyClone = false
        let headLogFile = gitDir.appendingPathComponent("logs/HEAD")
        if let logContents = try? String(contentsOf: headLogFile, encoding: .utf8) {
            let lines = logContents
                .split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            if lines.count == 1, let onlyLine = lines.first, onlyLine.contains("clone: from") {
                isReadOnlyClone = true
            } else if !lines.isEmpty && lines.allSatisfy({ !$0.contains("commit:") && !$0.contains("commit (") }) {
                isReadOnlyClone = true
            }
        }

        // Gather latest timestamp from key git metadata files
        let metadataCandidates = [
            gitDir.appendingPathComponent("index"),
            gitDir.appendingPathComponent("HEAD"),
            gitDir.appendingPathComponent("logs/HEAD"),
            gitDir.appendingPathComponent("FETCH_HEAD")
        ]
        var latestDate: Date? = nil
        for candidate in metadataCandidates {
            if let attrs = try? fm.attributesOfItem(atPath: candidate.path),
               let mtime = attrs[.modificationDate] as? Date {
                if latestDate == nil || mtime > latestDate! {
                    latestDate = mtime
                }
            }
        }

        var isDirty = false
        if runGitProcess {
            isDirty = checkGitDirtyStatus(at: gitRoot)
        }
        if isDirty {
            isReadOnlyClone = false
        }

        return CachedGitState(
            isGitRepo: true,
            hasUncommittedChanges: isDirty,
            gitBranch: branchName,
            latestGitTimestamp: latestDate,
            isReadOnlyClone: isReadOnlyClone
        )
    }

    private static func checkGitDirtyStatus(at gitRoot: URL) -> Bool {
        let gitExecutable = URL(fileURLWithPath: "/usr/bin/git")
        guard FileManager.default.isExecutableFile(atPath: gitExecutable.path) else {
            return false
        }

        let process = Process()
        process.executableURL = gitExecutable
        process.arguments = [
            "-C", gitRoot.path,
            "--no-optional-locks",
            "status",
            "--porcelain",
            "--untracked-files=no"
        ]

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

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

        guard process.terminationStatus == 0 else {
            return false
        }

        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else {
            return false
        }
        return !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

public struct SafetyInspector: Sendable {
    public let activeShieldWindowDays: Int
    public let homeDirectory: URL
    private let gitCache: GitInspectionCache

    private static let forbiddenAbsolutePrefixes: [String] = [
        "/System",
        "/Library",
        "/Applications",
        "/usr",
        "/bin",
        "/sbin",
        "/dev",
        "/etc",
        "/private/etc",
        "/private/var/db",
        "/private/var/root",
        "/Volumes"
    ]

    private static let forbiddenHomeRelativePaths: [String] = [
        ".ssh",
        ".gnupg",
        ".aws",
        ".kube",
        "Documents",
        "Desktop",
        "Pictures",
        "Music",
        "Movies",
        "Downloads",
        ".Trash"
    ]

    public init(
        activeShieldWindowDays: Int = 7,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        gitCache: GitInspectionCache = GitInspectionCache()
    ) {
        self.activeShieldWindowDays = activeShieldWindowDays
        self.homeDirectory = homeDirectory.standardizedFileURL
        self.gitCache = gitCache
    }

    // MARK: - Layer 1: Boundary & Symlink Guard

    public static func isSymbolicLink(at url: URL) -> Bool {
        let path = url.path
        if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
           let fileType = attrs[.type] as? FileAttributeType {
            return fileType == .typeSymbolicLink
        }
        if let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey]),
           let isSymlink = values.isSymbolicLink {
            return isSymlink
        }
        return false
    }

    public func isForbiddenPath(_ url: URL) -> Bool {
        let standardized = url.standardizedFileURL.path
        if standardized == "/" || standardized == homeDirectory.path {
            return true
        }

        for prefix in Self.forbiddenAbsolutePrefixes {
            if standardized == prefix || standardized.hasPrefix(prefix + "/") {
                return true
            }
        }

        for rel in Self.forbiddenHomeRelativePaths {
            let full = homeDirectory.appendingPathComponent(rel).standardizedFileURL.path
            if standardized == full || standardized.hasPrefix(full + "/") {
                return true
            }
        }

        return false
    }

    public func validateDeletionTarget(_ targetURL: URL, allowedWorkspaceRoots: [URL]) -> Result<Void, SafetyValidationError> {
        if Self.isSymbolicLink(at: targetURL) {
            return .failure(.symbolicLinkRejected(targetURL.path))
        }

        let standardized = targetURL.standardizedFileURL
        if isForbiddenPath(standardized) {
            return .failure(.forbiddenSystemOrPersonalPath(standardized.path))
        }

        for root in allowedWorkspaceRoots {
            let rootPath = root.standardizedFileURL.path
            if standardized.path == rootPath {
                return .failure(.cannotDeleteScanRootItself(standardized.path))
            }
        }

        let isInsideWorkspace = allowedWorkspaceRoots.contains { root in
            let rootPrefix = root.standardizedFileURL.path.hasSuffix("/")
                ? root.standardizedFileURL.path
                : root.standardizedFileURL.path + "/"
            return standardized.path.hasPrefix(rootPrefix)
        }

        let isKnownFixedCache = CleanupRuleRegistry.fixedCacheRules.contains { rule in
            let cacheURL = homeDirectory.appendingPathComponent(rule.relativePathFromHome).standardizedFileURL
            if standardized.path == cacheURL.path {
                return true
            }
            let prefix = cacheURL.path.hasSuffix("/") ? cacheURL.path : cacheURL.path + "/"
            return standardized.path.hasPrefix(prefix)
        }

        let simDevicesURL = homeDirectory.appendingPathComponent("Library/Developer/CoreSimulator/Devices").standardizedFileURL
        let isSimDevices = standardized.path == simDevicesURL.path || standardized.path.hasPrefix(simDevicesURL.path + "/")

        guard isInsideWorkspace || isKnownFixedCache || isSimDevices else {
            return .failure(.outsideAllowedBoundaries(standardized.path))
        }

        return .success(())
    }

    /// Validates a `CleanupItem`, including linked git worktrees whose main repository resides in `allowedWorkspaceRoots`.
    public func validateDeletionItem(_ item: CleanupItem, allowedWorkspaceRoots: [URL]) -> Result<Void, SafetyValidationError> {
        if let worktree = item.worktree {
            let target = item.path.standardizedFileURL
            if Self.isSymbolicLink(at: target) {
                return .failure(.symbolicLinkRejected(target.path))
            }
            if isForbiddenPath(target) {
                return .failure(.forbiddenSystemOrPersonalPath(target.path))
            }
            let mainURL = URL(fileURLWithPath: worktree.mainRepoPath).standardizedFileURL
            if target.path == mainURL.path {
                return .failure(.cannotDeleteScanRootItself(target.path))
            }
            let mainInWorkspace = allowedWorkspaceRoots.contains { root in
                let rootPrefix = root.standardizedFileURL.path.hasSuffix("/")
                    ? root.standardizedFileURL.path
                    : root.standardizedFileURL.path + "/"
                return mainURL.path.hasPrefix(rootPrefix) || mainURL.path == root.standardizedFileURL.path
            }
            guard mainInWorkspace else {
                return .failure(.outsideAllowedBoundaries(target.path))
            }
            return .success(())
        }
        return validateDeletionTarget(item.path, allowedWorkspaceRoots: allowedWorkspaceRoots)
    }

    // MARK: - Layer 2: Parent-Manifest Verification

    public static func matchingProjectRule(forFolderNamed folderName: String, inParent parentDirectory: URL) -> ProjectArtifactRule? {
        guard let candidates = CleanupRuleRegistry.rulesByFolderName[folderName] else {
            return nil
        }
        let fm = FileManager.default
        for rule in candidates {
            let hasManifest = rule.requiredSiblingManifests.contains { manifestName in
                let manifestPath = parentDirectory.appendingPathComponent(manifestName).path
                var isDir: ObjCBool = false
                return fm.fileExists(atPath: manifestPath, isDirectory: &isDir) && !isDir.boolValue
            }
            if hasManifest {
                return rule
            }
        }
        return nil
    }

    // MARK: - Context-Aware Rebuild Command Generator

    public static func inferRebuildCommand(for projectDirectory: URL, ecosystem: Ecosystem, homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> String {
        let fm = FileManager.default
        let homePath = homeDirectory.standardizedFileURL.path
        let rawPath = projectDirectory.standardizedFileURL.path
        let displayDir = rawPath.hasPrefix(homePath)
            ? "~" + rawPath.dropFirst(homePath.count)
            : rawPath
        let quotedDir = displayDir.contains(" ") ? "\"\(displayDir)\"" : displayDir

        switch ecosystem {
        case .node:
            if fm.fileExists(atPath: projectDirectory.appendingPathComponent("bun.lockb").path)
                || fm.fileExists(atPath: projectDirectory.appendingPathComponent("bun.lock").path) {
                return "cd \(quotedDir) && bun install"
            } else if fm.fileExists(atPath: projectDirectory.appendingPathComponent("pnpm-lock.yaml").path) {
                return "cd \(quotedDir) && pnpm install"
            } else if fm.fileExists(atPath: projectDirectory.appendingPathComponent("yarn.lock").path) {
                return "cd \(quotedDir) && yarn install"
            } else {
                return "cd \(quotedDir) && npm install"
            }
        case .rust:
            return "cd \(quotedDir) && cargo build"
        case .swift:
            return "cd \(quotedDir) && swift build"
        case .python:
            if fm.fileExists(atPath: projectDirectory.appendingPathComponent("uv.lock").path) {
                return "cd \(quotedDir) && uv sync"
            } else if fm.fileExists(atPath: projectDirectory.appendingPathComponent("poetry.lock").path) {
                return "cd \(quotedDir) && poetry install"
            } else if fm.fileExists(atPath: projectDirectory.appendingPathComponent("requirements.txt").path) {
                return "cd \(quotedDir) && python3 -m venv .venv && .venv/bin/pip install -r requirements.txt"
            } else {
                return "cd \(quotedDir) && python3 -m venv .venv"
            }
        case .jvm:
            return "cd \(quotedDir) && ./gradlew build"
        case .xcode, .homebrew, .docker, .aiModels, .git:
            return "cd \(quotedDir)"
        }
    }

    // MARK: - Layer 3: Active-Project Shield & Dormant Clone Detection

    public func inspectProjectProtection(
        projectDirectory: URL,
        artifactURL: URL,
        artifactLastModified: Date,
        stopAtRoot: URL? = nil,
        runGitProcess: Bool = true,
        now: Date = Date()
    ) async -> ProjectProtectionState {
        let fm = FileManager.default
        let gitRoot = Self.findEnclosingGitRoot(startingAt: projectDirectory, stopAt: stopAtRoot ?? homeDirectory)

        var latestActivity = artifactLastModified

        let activityProbeNames = [
            "package.json", "Cargo.toml", "Cargo.lock", "Package.swift", "Package.resolved",
            "pyproject.toml", "uv.lock", "requirements.txt", "build.gradle", "build.gradle.kts",
            "src", "Sources", "app", "pages", "components", "lib"
        ]
        for probe in activityProbeNames {
            let probeURL = projectDirectory.appendingPathComponent(probe)
            if let attrs = try? fm.attributesOfItem(atPath: probeURL.path),
               let mtime = attrs[.modificationDate] as? Date,
               mtime > latestActivity {
                latestActivity = mtime
            }
        }

        var isGitRepo = false
        var hasUncommittedChanges = false
        var gitBranch: String? = nil
        var isReadOnlyClone = false

        if let gitRoot {
            let gitState = await gitCache.state(for: gitRoot, runGitProcess: runGitProcess)
            isGitRepo = gitState.isGitRepo
            hasUncommittedChanges = gitState.hasUncommittedChanges
            gitBranch = gitState.gitBranch
            isReadOnlyClone = gitState.isReadOnlyClone
            if let gitTime = gitState.latestGitTimestamp, gitTime > latestActivity {
                latestActivity = gitTime
            }
        }

        let hasActiveProcess = Self.detectActiveLockFiles(projectDirectory: projectDirectory, artifactURL: artifactURL, gitRoot: gitRoot, now: now)

        let secondsElapsed = max(0, now.timeIntervalSince(latestActivity))
        let daysSinceLastActivity = Int(secondsElapsed / 86_400.0)

        return ProjectProtectionState(
            isGitRepo: isGitRepo,
            hasUncommittedChanges: hasUncommittedChanges,
            daysSinceLastActivity: daysSinceLastActivity,
            hasActiveProcess: hasActiveProcess,
            activeShieldWindowDays: activeShieldWindowDays,
            gitBranch: gitBranch,
            isReadOnlyClone: isReadOnlyClone
        )
    }

    private static func findEnclosingGitRoot(startingAt directory: URL, stopAt boundary: URL) -> URL? {
        let fm = FileManager.default
        var current = directory.standardizedFileURL
        let boundaryPath = boundary.standardizedFileURL.path

        for _ in 0..<6 {
            let gitCandidate = current.appendingPathComponent(".git")
            if fm.fileExists(atPath: gitCandidate.path) {
                return current
            }
            if current.path == boundaryPath || current.path == "/" {
                break
            }
            let parent = current.deletingLastPathComponent().standardizedFileURL
            if parent.path == current.path {
                break
            }
            current = parent
        }
        return nil
    }

    private static func detectActiveLockFiles(projectDirectory: URL, artifactURL: URL, gitRoot: URL?, now: Date) -> Bool {
        let fm = FileManager.default
        var lockCandidates: [URL] = [
            artifactURL.appendingPathComponent("lock"),
            artifactURL.appendingPathComponent(".lock"),
            projectDirectory.appendingPathComponent(".next/lock")
        ]
        if let gitRoot {
            lockCandidates.append(gitRoot.appendingPathComponent(".git/index.lock"))
        }

        for candidate in lockCandidates {
            if fm.fileExists(atPath: candidate.path) {
                return true
            }
        }

        let recentBuildMarkers = [
            artifactURL.appendingPathComponent(".cargo-lock"),
            artifactURL.appendingPathComponent("debug/.cargo-lock"),
            artifactURL.appendingPathComponent("release/.cargo-lock"),
            artifactURL.appendingPathComponent("build.db")
        ]
        for marker in recentBuildMarkers {
            if let attrs = try? fm.attributesOfItem(atPath: marker.path),
               let mtime = attrs[.modificationDate] as? Date,
               now.timeIntervalSince(mtime) < 45 {
                return true
            }
        }

        return false
    }
}

public enum SafetyValidationError: Error, LocalizedError, Sendable, Equatable {
    case symbolicLinkRejected(String)
    case forbiddenSystemOrPersonalPath(String)
    case cannotDeleteScanRootItself(String)
    case outsideAllowedBoundaries(String)

    public var errorDescription: String? {
        switch self {
        case .symbolicLinkRejected(let path):
            return "Refused to touch symbolic link: \(path)"
        case .forbiddenSystemOrPersonalPath(let path):
            return "Path is inside a protected system or personal directory: \(path)"
        case .cannotDeleteScanRootItself(let path):
            return "Cannot delete a root workspace folder itself: \(path)"
        case .outsideAllowedBoundaries(let path):
            return "Path is outside configured workspace and cache boundaries: \(path)"
        }
    }
}
