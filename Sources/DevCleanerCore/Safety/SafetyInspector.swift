import Darwin
import Foundation

struct CleanupTargetIdentity: Codable, Equatable, Sendable {
    let device: UInt64
    let inode: UInt64
    let creationDate: Date?

    static func read(at url: URL) -> Self? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let device = attributes[.systemNumber] as? NSNumber,
              let inode = attributes[.systemFileNumber] as? NSNumber else { return nil }
        return Self(device: device.uint64Value, inode: inode.uint64Value,
                    creationDate: attributes[.creationDate] as? Date)
    }
}

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

        let isDirty = runGitProcess && checkGitDirtyStatus(at: gitRoot)
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
        let arguments = [
            "-C", gitRoot.path,
            "--no-optional-locks",
            "status",
            "--porcelain",
            "--untracked-files=no"
        ]

        guard let output = try? CommandRunner.run(gitExecutable.path, arguments: arguments,
                                                  timeout: 5, captureOutput: true) else { return true }
        return !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

public struct SafetyInspector: Sendable {
    public let activeShieldWindowDays: Int
    public let homeDirectory: URL
    private let gitCache: GitInspectionCache

    private static let forbiddenAbsolutePrefixes: [String] = [
        "/system",
        "/library",
        "/applications",
        "/usr",
        "/bin",
        "/sbin",
        "/dev",
        "/etc",
        "/private/etc",
        "/private/var/db",
        "/private/var/root",
        "/volumes"
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
        let standardized = Self.platformPath(url).lowercased()
        if standardized == "/" || standardized == Self.platformPath(homeDirectory).lowercased() {
            return true
        }

        for prefix in Self.forbiddenAbsolutePrefixes {
            if standardized == prefix || standardized.hasPrefix(prefix + "/") {
                return true
            }
        }

        for rel in Self.forbiddenHomeRelativePaths {
            let full = Self.platformPath(homeDirectory.appendingPathComponent(rel)).lowercased()
            if standardized == full || standardized.hasPrefix(full + "/") {
                return true
            }
        }

        return false
    }

    public func validateDeletionTarget(_ targetURL: URL, allowedWorkspaceRoots: [URL]) -> Result<Void, SafetyValidationError> {
        if case .failure(let error) = validatePath(targetURL, protectedRoots: allowedWorkspaceRoots) {
            return .failure(error)
        }

        let path = Self.platformPath(targetURL)
        let isInsideWorkspace = allowedWorkspaceRoots.contains { root in
            Self.contains(path, in: Self.platformPath(root))
        }

        let isKnownFixedCache = CleanupRuleRegistry.fixedCacheRules.contains { rule in
            Self.contains(path, in: Self.platformPath(homeDirectory.appendingPathComponent(rule.relativePathFromHome)))
        }

        let simDevicesURL = homeDirectory.appendingPathComponent("Library/Developer/CoreSimulator/Devices")
        let isSimDevices = Self.contains(path, in: Self.platformPath(simDevicesURL))

        guard isInsideWorkspace || isKnownFixedCache || isSimDevices else {
            return .failure(.outsideAllowedBoundaries(targetURL.path))
        }

        return .success(())
    }

    /// Validates a `CleanupItem`, including linked git worktrees whose main repository resides in `allowedWorkspaceRoots`.
    public func validateDeletionItem(_ item: CleanupItem, allowedWorkspaceRoots: [URL]) -> Result<Void, SafetyValidationError> {
        if let worktree = item.worktree {
            let mainURL = URL(fileURLWithPath: worktree.mainRepoPath, isDirectory: true)
            if case .failure(let error) = validatePath(item.path, protectedRoots: allowedWorkspaceRoots + [mainURL]) {
                return .failure(error)
            }
            if case .failure(let error) = validatePath(mainURL.appendingPathComponent(".git/worktrees"), protectedRoots: []) {
                return .failure(error)
            }
            let mainInWorkspace = allowedWorkspaceRoots.contains { root in
                Self.contains(Self.platformPath(mainURL), in: Self.platformPath(root))
            }
            return mainInWorkspace ? .success(()) : .failure(.outsideAllowedBoundaries(item.path.path))
        }
        return validateDeletionTarget(item.path, allowedWorkspaceRoots: allowedWorkspaceRoots)
    }

    private func validatePath(_ url: URL, protectedRoots: [URL]) -> Result<Void, SafetyValidationError> {
        let path = Self.platformPath(url)
        if let error = Self.pathComponentError(for: url) {
            return .failure(error)
        }
        if isForbiddenPath(url) {
            return .failure(.forbiddenSystemOrPersonalPath(url.path))
        }
        let identity = CleanupTargetIdentity.read(at: url)
        if protectedRoots.contains(where: {
            Self.contains(Self.platformPath($0), in: path) ||
                (identity != nil && CleanupTargetIdentity.read(at: $0) == identity)
        }) {
            return .failure(.cannotDeleteScanRootItself(url.path))
        }
        return .success(())
    }

    static func pathComponentError(for url: URL) -> SafetyValidationError? {
        var path = ""
        for component in platformPath(url).split(separator: "/") {
            path += "/" + component
            var info = stat()
            if lstat(path, &info) == 0 {
                if info.st_mode & S_IFMT == S_IFLNK {
                    return .symbolicLinkRejected(url.path)
                }
            } else if errno == ENOENT {
                return nil  // Missing leaf/descendants have no symlinks to traverse.
            } else {
                return .targetChanged(url.path)
            }
        }
        return nil
    }

    static func platformPath(_ url: URL) -> String {
        let path = url.standardizedFileURL.path
        // These macOS aliases have stable system-owned targets.
        if ["/var", "/tmp", "/etc"].contains(where: { contains(path, in: $0) }) {
            return "/private" + path
        }
        return path
    }

    private static func contains(_ path: String, in root: String) -> Bool {
        path == root || path.hasPrefix(root == "/" ? "/" : root + "/")
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
    case targetChanged(String)

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
        case .targetChanged(let path):
            return "The target changed since the scan or is inaccessible. Rescan before cleaning: \(path)"
        }
    }
}
