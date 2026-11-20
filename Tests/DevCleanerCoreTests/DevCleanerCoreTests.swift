import Foundation
import Testing
@testable import DevCleanerCore

@Suite("DevCleanerCore Safety & Scanner Suite")
struct DevCleanerCoreTests {

    private struct TestSandbox {
        let sandboxRoot: URL
        let workspaceRoot: URL
        let fakeHomeRoot: URL
        let trashRoot: URL
        let auditRoot: URL

        init() throws {
            let base = FileManager.default.temporaryDirectory
                .appendingPathComponent("DevCleanerTests-\(UUID().uuidString)", isDirectory: true)
                .standardizedFileURL
            sandboxRoot = base
            workspaceRoot = base.appendingPathComponent("Projects", isDirectory: true)
            fakeHomeRoot = base.appendingPathComponent("Home", isDirectory: true)
            trashRoot = base.appendingPathComponent("Trash", isDirectory: true)
            auditRoot = base.appendingPathComponent("AuditLogs", isDirectory: true)

            let fm = FileManager.default
            try fm.createDirectory(at: workspaceRoot, withIntermediateDirectories: true)
            try fm.createDirectory(at: fakeHomeRoot, withIntermediateDirectories: true)
            try fm.createDirectory(at: trashRoot, withIntermediateDirectories: true)
            try fm.createDirectory(at: auditRoot, withIntermediateDirectories: true)
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: sandboxRoot)
        }
    }

    // MARK: - 1. Parent-Manifest Verification Tests

    @Test("Folders named target or build without sibling manifest are never flagged")
    func unpairedTargetOrBuildFolderIsNeverFlagged() async throws {
        let box = try TestSandbox()
        defer { box.cleanup() }

        let marketingProject = box.workspaceRoot.appendingPathComponent("marketing-assets", isDirectory: true)
        let unpairedTarget = marketingProject.appendingPathComponent("target", isDirectory: true)
        let unpairedBuild = marketingProject.appendingPathComponent("build", isDirectory: true)

        try writeDummyFile(at: unpairedTarget.appendingPathComponent("logo.png"), sizeBytes: 16_384)
        try writeDummyFile(at: unpairedBuild.appendingPathComponent("deck.pdf"), sizeBytes: 16_384)

        let scanner = APFSBlockScanner()
        let config = ScanConfiguration(
            workspaceRoots: [box.workspaceRoot],
            homeDirectory: box.fakeHomeRoot,
            includeGlobalCaches: false,
            runGitStatusProcess: false
        )
        let items = await scanner.scan(configuration: config)
        #expect(items.isEmpty)
    }

    @Test("Paired manifests discover Rust, Swift, and Python project artifacts")
    func pairedManifestsDiscoverRustSwiftAndPythonArtifacts() async throws {
        let box = try TestSandbox()
        defer { box.cleanup() }

        // 1. Rust project (Cargo.toml + target/)
        let rustProj = box.workspaceRoot.appendingPathComponent("hyper-engine", isDirectory: true)
        try writeDummyFile(at: rustProj.appendingPathComponent("Cargo.toml"), sizeBytes: 256)
        try writeDummyFile(at: rustProj.appendingPathComponent("target/debug/libengine.rlib"), sizeBytes: 32_768)

        // 2. Swift project (Package.swift + .build/)
        let swiftProj = box.workspaceRoot.appendingPathComponent("swift-kit", isDirectory: true)
        try writeDummyFile(at: swiftProj.appendingPathComponent("Package.swift"), sizeBytes: 256)
        try writeDummyFile(at: swiftProj.appendingPathComponent(".build/arm64-apple-macosx/debug/SwiftKit"), sizeBytes: 24_576)

        // 3. Python project (pyproject.toml + .venv/)
        let pyProj = box.workspaceRoot.appendingPathComponent("ml-trainer", isDirectory: true)
        try writeDummyFile(at: pyProj.appendingPathComponent("pyproject.toml"), sizeBytes: 256)
        try writeDummyFile(at: pyProj.appendingPathComponent(".venv/lib/site.py"), sizeBytes: 12_288)

        let scanner = APFSBlockScanner()
        let config = ScanConfiguration(
            workspaceRoots: [box.workspaceRoot],
            homeDirectory: box.fakeHomeRoot,
            includeGlobalCaches: false,
            runGitStatusProcess: false
        )

        let items = await scanner.scan(configuration: config)
        #expect(items.count == 3)

        let ecosystems = Set(items.map(\.ecosystem))
        #expect(ecosystems == [.rust, .swift, .python])
    }

    // MARK: - 2. Nested Monorepo Deduplication Tests

    @Test("Nested node_modules inside parent node_modules is never double-counted")
    func nestedNodeModulesInsideNodeModulesIsNeverDoubleCounted() async throws {
        let box = try TestSandbox()
        defer { box.cleanup() }

        let webApp = box.workspaceRoot.appendingPathComponent("next-dashboard", isDirectory: true)
        try writeDummyFile(at: webApp.appendingPathComponent("package.json"), sizeBytes: 200)

        let rootNM = webApp.appendingPathComponent("node_modules", isDirectory: true)
        try writeDummyFile(at: rootNM.appendingPathComponent("react/index.js"), sizeBytes: 16_384)

        // Nested node_modules with its own package.json inside parent node_modules
        let nestedPkg = rootNM.appendingPathComponent("foo-pkg", isDirectory: true)
        try writeDummyFile(at: nestedPkg.appendingPathComponent("package.json"), sizeBytes: 200)
        try writeDummyFile(at: nestedPkg.appendingPathComponent("node_modules/bar/index.js"), sizeBytes: 16_384)

        let scanner = APFSBlockScanner()
        let config = ScanConfiguration(
            workspaceRoots: [box.workspaceRoot],
            homeDirectory: box.fakeHomeRoot,
            includeGlobalCaches: false,
            runGitStatusProcess: false
        )

        let items = await scanner.scan(configuration: config)
        #expect(items.count == 1)
        #expect(items.first?.path == rootNM.standardizedFileURL)
        #expect(items.first?.fileCount == 3)
    }

    // MARK: - 3. Active-Project Shield & Safe Sweep Eligibility Tests

    @Test("Active-Project Shield protects recent repos and allows stale clean projects for Safe Sweep")
    func activeProjectShieldAndSafeSweepEligibility() async throws {
        let box = try TestSandbox()
        defer { box.cleanup() }

        let now = Date()
        let staleDate = now.addingTimeInterval(-45 * 86_400) // 45 days ago

        // Project A: Active today with .git repo -> Should be shielded
        let activeProj = box.workspaceRoot.appendingPathComponent("active-app", isDirectory: true)
        try FileManager.default.createDirectory(at: activeProj.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try writeDummyFile(at: activeProj.appendingPathComponent(".git/HEAD"), content: "ref: refs/heads/main\n")
        try writeDummyFile(at: activeProj.appendingPathComponent("package.json"), sizeBytes: 128)
        try writeDummyFile(at: activeProj.appendingPathComponent("node_modules/pkg/a.js"), sizeBytes: 16_384)

        // Project B: Stale (>45 days old) clean git repo -> Unshielded & eligible for 1-Click Safe Sweep
        let staleProj = box.workspaceRoot.appendingPathComponent("legacy-service", isDirectory: true)
        let staleGit = staleProj.appendingPathComponent(".git", isDirectory: true)
        try FileManager.default.createDirectory(at: staleGit, withIntermediateDirectories: true)
        let staleHead = staleGit.appendingPathComponent("HEAD")
        try writeDummyFile(at: staleHead, content: "ref: refs/heads/develop\n", modificationDate: staleDate)
        let staleManifest = staleProj.appendingPathComponent("Cargo.toml")
        try writeDummyFile(at: staleManifest, sizeBytes: 128, modificationDate: staleDate)
        let staleTarget = staleProj.appendingPathComponent("target", isDirectory: true)
        let staleBin = staleTarget.appendingPathComponent("debug/app")
        try writeDummyFile(at: staleBin, sizeBytes: 32_768, modificationDate: staleDate)
        try setModificationDate(staleDate, for: staleTarget)
        try setModificationDate(staleDate, for: staleTarget.appendingPathComponent("debug"))
        try setModificationDate(staleDate, for: staleGit)
        try setModificationDate(staleDate, for: staleProj)

        let scanner = APFSBlockScanner()
        let config = ScanConfiguration(
            workspaceRoots: [box.workspaceRoot],
            homeDirectory: box.fakeHomeRoot,
            includeGlobalCaches: false,
            activeShieldWindowDays: 7,
            runGitStatusProcess: false,
            now: now
        )

        let items = await scanner.scan(configuration: config)
        #expect(items.count == 2)

        let activeItem = try #require(items.first { $0.projectName == "active-app" })
        #expect(activeItem.protection.isShielded == true)
        #expect(activeItem.protection.gitBranch == "main")
        #expect(activeItem.effectiveSafetyTier == .protectedManual)
        #expect(activeItem.isEligibleForSafeSweep(minimumStaleDays: 30) == false)

        let staleItem = try #require(items.first { $0.projectName == "legacy-service" })
        #expect(staleItem.protection.isShielded == false)
        #expect(staleItem.protection.gitBranch == "develop")
        #expect(staleItem.effectiveSafetyTier == .safeRebuildable)
        #expect(staleItem.isEligibleForSafeSweep(minimumStaleDays: 30) == true)
    }

    // MARK: - 4. Symlink & Boundary Guard Tests

    @Test("Symlinks, system paths, personal folders, and workspace roots are rejected")
    func symlinkAndSystemBoundariesAreStrictlyRejected() throws {
        let box = try TestSandbox()
        defer { box.cleanup() }

        let inspector = SafetyInspector(homeDirectory: box.fakeHomeRoot)

        #expect(inspector.isForbiddenPath(URL(fileURLWithPath: "/System/Library")))
        #expect(inspector.isForbiddenPath(URL(fileURLWithPath: "/Applications/Xcode.app")))
        #expect(inspector.isForbiddenPath(box.fakeHomeRoot.appendingPathComponent(".ssh/id_ed25519")))
        #expect(inspector.isForbiddenPath(box.fakeHomeRoot.appendingPathComponent("Documents/taxes.pdf")))

        let rootValidation = inspector.validateDeletionTarget(box.workspaceRoot, allowedWorkspaceRoots: [box.workspaceRoot])
        if case .failure(let err) = rootValidation {
            #expect(err == .cannotDeleteScanRootItself(box.workspaceRoot.path))
        } else {
            Issue.record("Workspace scan root itself must never pass deletion validation")
        }

        let realOutsideDir = box.sandboxRoot.appendingPathComponent("OutsideSecret", isDirectory: true)
        try FileManager.default.createDirectory(at: realOutsideDir, withIntermediateDirectories: true)
        let symlinkInsideWorkspace = box.workspaceRoot.appendingPathComponent("node_modules")
        try FileManager.default.createSymbolicLink(at: symlinkInsideWorkspace, withDestinationURL: realOutsideDir)

        let symlinkValidation = inspector.validateDeletionTarget(symlinkInsideWorkspace, allowedWorkspaceRoots: [box.workspaceRoot])
        if case .failure(let err) = symlinkValidation {
            #expect(err == .symbolicLinkRejected(symlinkInsideWorkspace.path))
        } else {
            Issue.record("Symbolic link must never pass deletion validation")
        }
    }

    // MARK: - 5. Dry-Run, Trash Relocation, Audit Log & 1-Click Undo Tests

    @Test("Dry-run makes zero filesystem mutations and Trash cleanup is 1-click undoable")
    func dryRunMakesZeroChangesAndTrashCleanupCanBeUndone() async throws {
        let box = try TestSandbox()
        defer { box.cleanup() }

        let proj = box.workspaceRoot.appendingPathComponent("demo-api", isDirectory: true)
        try writeDummyFile(at: proj.appendingPathComponent("package.json"), sizeBytes: 128)
        let nodeModules = proj.appendingPathComponent("node_modules", isDirectory: true)
        let sampleFile = nodeModules.appendingPathComponent("express/index.js")
        try writeDummyFile(at: sampleFile, sizeBytes: 24_576)

        let scanner = APFSBlockScanner()
        let config = ScanConfiguration(
            workspaceRoots: [box.workspaceRoot],
            homeDirectory: box.fakeHomeRoot,
            includeGlobalCaches: false,
            runGitStatusProcess: false
        )
        let items = await scanner.scan(configuration: config)
        #expect(items.count == 1)

        let inspector = SafetyInspector(homeDirectory: box.fakeHomeRoot)
        let auditStore = AuditLogStore(storageDirectory: box.auditRoot)
        let executor = CleanupExecutor(
            safetyInspector: inspector,
            auditStore: auditStore,
            customTrashDirectory: box.trashRoot
        )

        // 1. Dry-Run -> Files untouched
        let dryRunSession = try executor.execute(
            items: items,
            mode: .moveToTrash,
            dryRun: true,
            allowedWorkspaceRoots: [box.workspaceRoot]
        )
        #expect(dryRunSession.wasDryRun == true)
        #expect(FileManager.default.fileExists(atPath: sampleFile.path) == true)

        // 2. Live Trash Cleanup -> Moved to trash
        let liveSession = try executor.execute(
            items: items,
            mode: .moveToTrash,
            dryRun: false,
            allowedWorkspaceRoots: [box.workspaceRoot]
        )
        #expect(liveSession.wasDryRun == false)
        #expect(liveSession.restorableItemCount == 1)
        #expect(FileManager.default.fileExists(atPath: nodeModules.path) == false)

        let trashedPath = try #require(liveSession.items.first?.trashedPath)
        #expect(FileManager.default.fileExists(atPath: trashedPath) == true)

        // 3. 1-Click Undo -> Restored back to original path
        let restoredSession = try executor.undoSession(liveSession)
        #expect(restoredSession.restorableItemCount == 0)
        #expect(restoredSession.items.first?.isRestored == true)
        #expect(FileManager.default.fileExists(atPath: sampleFile.path) == true)

        // 4. Verify AuditLogStore persisted both sessions
        let persistedSessions = auditStore.loadSessions()
        #expect(persistedSessions.count == 2)

        // 5. Verify Rebuild Shell Script generation (Feature #7)
        let rebuildScript = try #require(liveSession.rebuildShellScript)
        #expect(rebuildScript.contains("npm install"))
    }

    // MARK: - 6. Dormant & Read-Only Clone Detection + Rebuild Command Inference + Git GC Tool Task

    @Test("Detects read-only git clones, infers lockfile-specific rebuild commands, and discovers bloated git packfiles")
    func detectsReadOnlyClonesRebuildCommandsAndGitGC() async throws {
        let box = try TestSandbox()
        defer { box.cleanup() }

        let now = Date()
        let monthAgo = now.addingTimeInterval(-35 * 86_400)

        let clonedRepo = box.workspaceRoot.appendingPathComponent("oss-clone", isDirectory: true)
        let gitDir = clonedRepo.appendingPathComponent(".git", isDirectory: true)
        try FileManager.default.createDirectory(at: gitDir.appendingPathComponent("logs"), withIntermediateDirectories: true)
        try writeDummyFile(at: gitDir.appendingPathComponent("HEAD"), content: "ref: refs/heads/main\n", modificationDate: monthAgo)
        try writeDummyFile(
            at: gitDir.appendingPathComponent("logs/HEAD"),
            content: "0000000 1111111 Dev <dev@example.com> 1700000000 +0000\tclone: from https://github.com/org/oss-clone.git\n",
            modificationDate: monthAgo
        )
        // Add bun.lockb + package.json so rebuild command infers 'bun install'
        try writeDummyFile(at: clonedRepo.appendingPathComponent("package.json"), sizeBytes: 128, modificationDate: monthAgo)
        try writeDummyFile(at: clonedRepo.appendingPathComponent("bun.lockb"), sizeBytes: 128, modificationDate: monthAgo)
        let nm = clonedRepo.appendingPathComponent("node_modules", isDirectory: true)
        try writeDummyFile(at: nm.appendingPathComponent("pkg/index.js"), sizeBytes: 16_384, modificationDate: monthAgo)
        // Add a .git/objects packfile and set gitGCMinimumBytes low so git gc task is discovered
        let packFile = gitDir.appendingPathComponent("objects/pack/pack-123.pack")
        try writeDummyFile(at: packFile, sizeBytes: 32_768, modificationDate: monthAgo)

        try setModificationDate(monthAgo, for: nm)
        try setModificationDate(monthAgo, for: gitDir.appendingPathComponent("objects"))
        try setModificationDate(monthAgo, for: gitDir)
        try setModificationDate(monthAgo, for: clonedRepo)

        let scanner = APFSBlockScanner()
        let config = ScanConfiguration(
            workspaceRoots: [box.workspaceRoot],
            homeDirectory: box.fakeHomeRoot,
            includeGlobalCaches: false,
            activeShieldWindowDays: 7,
            runGitStatusProcess: false,
            gitGCMinimumBytes: 16_384,
            now: now
        )

        let items = await scanner.scan(configuration: config)
        #expect(items.count == 2)

        let nodeItem = try #require(items.first { $0.ruleId == "node.node_modules" })
        #expect(nodeItem.protection.isReadOnlyClone == true)
        #expect(nodeItem.protection.isDormantOrOrphaned == true)
        #expect(nodeItem.protection.dormantBadgeText == "Read-Only Clone")
        #expect(nodeItem.rebuildCommand?.hasSuffix("&& bun install") == true)

        let gitGCItem = try #require(items.first { $0.ruleId == "git.gc" })
        #expect(gitGCItem.actionKind.isToolCommand == true)
        #expect(gitGCItem.actionKind.displayCommandString == "git gc --prune=now")

        let disk = DiskSpaceSnapshot.current()
        #expect(disk.totalBytes > 0)
    }

    // MARK: - 7. UpdateService & SemanticVersion Tests (GitHub Releases + Website Manifest)

    @Test("Parses GitHub Releases API and website latest.json manifests and compares semantic versions")
    func parsesGitHubReleasesAndWebsiteUpdateManifests() throws {
        #expect(SemanticVersion(string: "v1.2.0")! > SemanticVersion(string: "1.1.9")!)
        #expect(SemanticVersion(string: "1.0.0")! > SemanticVersion(string: "1.0.0-beta.1")!)
        #expect(SemanticVersion(string: "v1.0.0") == SemanticVersion(string: "1.0.0"))

        let fallbackURL = URL(string: "https://example.com/releases")!

        // 1. GitHub Releases API payload
        let githubJSON = """
        {
          "tag_name": "v1.2.0",
          "html_url": "https://github.com/stabil/husk/releases/tag/v1.2.0",
          "body": "Added Liquid Glass settings and automatic updates.",
          "published_at": "2026-11-20T10:00:00Z",
          "assets": [
            {
              "name": "Husk-1.2.0-macos-arm64.zip",
              "browser_download_url": "https://github.com/stabil/husk/releases/download/v1.2.0/Husk-1.2.0-macos-arm64.zip"
            },
            {
              "name": "Husk-1.2.0-macos-arm64.dmg",
              "browser_download_url": "https://github.com/stabil/husk/releases/download/v1.2.0/Husk-1.2.0-macos-arm64.dmg"
            }
          ]
        }
        """.data(using: .utf8)!

        let ghRelease = try UpdateService.parseReleasePayload(data: githubJSON, fallbackURL: fallbackURL)
        #expect(ghRelease.version == "v1.2.0")
        #expect(ghRelease.downloadURL.absoluteString.hasSuffix(".zip"))
        let ghStatus = UpdateService.compare(release: ghRelease, againstCurrentVersion: "1.0.0")
        if case .updateAvailable(let rel, let current) = ghStatus {
            #expect(rel.version == "v1.2.0")
            #expect(current == "1.0.0")
        } else {
            Issue.record("Expected updateAvailable for v1.2.0 vs 1.0.0")
        }

        // 2. Website latest.json payload
        let websiteJSON = """
        {
          "version": "1.0.0",
          "downloadURL": "https://husk.app/downloads/Husk-1.0.0-macos-arm64.dmg",
          "releaseNotes": "Initial stable release.",
          "sha256": "abc123def456"
        }
        """.data(using: .utf8)!

        let webRelease = try UpdateService.parseReleasePayload(data: websiteJSON, fallbackURL: fallbackURL)
        #expect(webRelease.sha256 == "abc123def456")
        let webStatus = UpdateService.compare(release: webRelease, againstCurrentVersion: "1.0.0")
        if case .upToDate(let current, _) = webStatus {
            #expect(current == "1.0.0")
        } else {
            Issue.record("Expected upToDate when versions match")
        }
    }

    // MARK: - 8. Git Worktree Discovery, Safety Inspection & Cleanup Tests

    @Test("Discovers linked git worktrees, distinguishes merged/clean vs unmerged/dirty, and removes cleanly via git worktree remove")
    func discoversAndSafelyRemovesGitWorktrees() async throws {
        let box = try TestSandbox()
        defer { box.cleanup() }

        let mainRepo = box.workspaceRoot.appendingPathComponent("core-app", isDirectory: true)
        try FileManager.default.createDirectory(at: mainRepo, withIntermediateDirectories: true)

        func runGit(_ args: [String], in dir: URL) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", dir.path] + args
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            try process.run()
            process.waitUntilExit()
            #expect(process.terminationStatus == 0)
        }

        try runGit(["init", "-b", "main"], in: mainRepo)
        try runGit(["config", "user.name", "Husk Test"], in: mainRepo)
        try runGit(["config", "user.email", "test@husk.app"], in: mainRepo)
        try writeDummyFile(at: mainRepo.appendingPathComponent("README.md"), content: "# Core App\n")
        try runGit(["add", "."], in: mainRepo)
        try runGit(["commit", "-m", "initial commit"], in: mainRepo)

        // Worktree 1: Merged & Clean (points to same commit as main)
        let mergedWT = box.sandboxRoot.appendingPathComponent("wt-merged", isDirectory: true)
        try runGit(["worktree", "add", "-b", "feat/merged-ui", mergedWT.path, "main"], in: mainRepo)

        // Backdate files inside mergedWT so it's inactive (> 7 days)
        let now = Date()
        let oldDate = now.addingTimeInterval(-20 * 86_400)
        try setModificationDate(oldDate, for: mergedWT.appendingPathComponent("README.md"))
        try setModificationDate(oldDate, for: mergedWT.appendingPathComponent(".git"))
        try setModificationDate(oldDate, for: mergedWT)

        // Worktree 2: Unmerged commit + Dirty untracked file
        let dirtyWT = box.sandboxRoot.appendingPathComponent("wt-dirty", isDirectory: true)
        try runGit(["worktree", "add", "-b", "feat/wip-branch", dirtyWT.path, "main"], in: mainRepo)
        try writeDummyFile(at: dirtyWT.appendingPathComponent("feature.swift"), content: "let x = 1\n")
        try runGit(["add", "feature.swift"], in: dirtyWT)
        try runGit(["commit", "-m", "wip unmerged commit"], in: dirtyWT)
        try writeDummyFile(at: dirtyWT.appendingPathComponent("untracked-notes.txt"), content: "do not lose me\n")

        let scanner = APFSBlockScanner()
        let config = ScanConfiguration(
            workspaceRoots: [box.workspaceRoot],
            homeDirectory: box.fakeHomeRoot,
            includeGlobalCaches: false,
            activeShieldWindowDays: 7,
            runGitStatusProcess: true,
            now: now
        )

        let items = await scanner.scan(configuration: config)
        let worktrees = items.filter { $0.worktree != nil }
        #expect(worktrees.count == 2)

        let mergedItem = try #require(worktrees.first { $0.path.lastPathComponent == "wt-merged" })
        #expect(mergedItem.worktree?.isMergedIntoMain == true)
        #expect(mergedItem.protection.hasUncommittedChanges == false)
        #expect(mergedItem.protection.isShielded == false)
        #expect(mergedItem.effectiveSafetyTier == .safeRebuildable)
        #expect(mergedItem.worktree?.statusBadgeText == "Merged")

        let dirtyItem = try #require(worktrees.first { $0.path.lastPathComponent == "wt-dirty" })
        #expect(dirtyItem.worktree?.isMergedIntoMain == false)
        #expect(dirtyItem.protection.hasUncommittedChanges == true)
        #expect(dirtyItem.protection.isShielded == true)
        #expect(dirtyItem.effectiveSafetyTier == .protectedManual)
        #expect(dirtyItem.worktree?.statusBadgeText == "Unmerged")

        // Execute cleanup on the merged & clean worktree via CleanupExecutor (`git worktree remove`)
        let inspector = SafetyInspector(homeDirectory: box.fakeHomeRoot)
        let auditStore = AuditLogStore(storageDirectory: box.auditRoot)
        let executor = CleanupExecutor(
            safetyInspector: inspector,
            auditStore: auditStore,
            customTrashDirectory: box.trashRoot
        )

        let session = try executor.execute(
            items: [mergedItem],
            mode: .moveToTrash,
            dryRun: false,
            allowedWorkspaceRoots: [box.workspaceRoot]
        )
        #expect(session.items.first?.errorDescription == nil)
        #expect(FileManager.default.fileExists(atPath: mergedWT.path) == false)
        #expect(FileManager.default.fileExists(atPath: dirtyWT.path) == true)
    }

    // MARK: - Helpers

    private func writeDummyFile(
        at fileURL: URL,
        sizeBytes: Int = 1024,
        content: String? = nil,
        modificationDate: Date? = nil
    ) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let content {
            try content.data(using: .utf8)?.write(to: fileURL)
        } else {
            let data = Data(repeating: 0x41, count: sizeBytes)
            try data.write(to: fileURL)
        }
        if let modificationDate {
            try setModificationDate(modificationDate, for: fileURL)
        }
    }

    private func setModificationDate(_ date: Date, for url: URL) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }
}
