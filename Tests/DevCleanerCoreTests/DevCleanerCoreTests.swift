import CryptoKit
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
        #expect(liveSession.totalBytesReclaimed == 0)
        #expect(liveSession.totalBytesMovedToTrash > 0)
        #expect(liveSession.remainingTrash.estimatedBytes == liveSession.totalBytesMovedToTrash)
        #expect(FileManager.default.fileExists(atPath: nodeModules.path) == false)

        let trashedPath = try #require(liveSession.items.first?.trashedPath)
        #expect(FileManager.default.fileExists(atPath: trashedPath) == true)
        #expect(liveSession.remainingTrash.urls.map(\.path) == [trashedPath])
        let recordedLiveSession = try #require(auditStore.loadSessions().first { $0.id == liveSession.id })
        #expect(recordedLiveSession.remainingTrash.urls.map(\.path) == [trashedPath])

        // 3. 1-Click Undo -> Restored back to original path
        let restoredSession = try executor.undoSession(liveSession)
        #expect(restoredSession.restorableItemCount == 0)
        #expect(restoredSession.items.first?.isRestored == true)
        #expect(FileManager.default.fileExists(atPath: sampleFile.path) == true)
        #expect(liveSession.remainingTrash.urls.isEmpty)
        #expect(restoredSession.remainingTrash.estimatedBytes == 0)

        // 4. Verify AuditLogStore persisted both sessions
        let persistedSessions = auditStore.loadSessions()
        #expect(persistedSessions.count == 2)

        try writeDummyFile(at: URL(fileURLWithPath: trashedPath), content: "a different Trash item")
        #expect(recordedLiveSession.remainingTrash.urls.isEmpty)

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
              "name": "Husk-1.2.0-macos-arm64.zip.sig",
              "browser_download_url": "https://github.com/stabil/husk/releases/download/v1.2.0/Husk-1.2.0-macos-arm64.zip.sig"
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
        #expect(ghRelease.canInstallInApp)
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
        #expect(!webRelease.canInstallInApp)
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
        try writeDummyFile(at: mainRepo.appendingPathComponent(".gitignore"), content: ".env\nnode_modules/\n.next/\n")
        try writeDummyFile(at: mainRepo.appendingPathComponent("package.json"), content: "{}")
        try runGit(["add", "."], in: mainRepo)
        try runGit(["commit", "-m", "initial commit"], in: mainRepo)

        // Worktree 1: Merged & Clean (points to same commit as main)
        let mergedWT = box.sandboxRoot.appendingPathComponent("wt-merged", isDirectory: true)
        try runGit(["worktree", "add", "-b", "feat/merged-ui", mergedWT.path, "main"], in: mainRepo)

        // Backdate files inside mergedWT so it's inactive (> 7 days)
        let now = Date()
        let oldDate = now.addingTimeInterval(-20 * 86_400)
        try setModificationDate(oldDate, for: mergedWT.appendingPathComponent("README.md"))
        try setModificationDate(oldDate, for: mergedWT.appendingPathComponent(".gitignore"))
        try setModificationDate(oldDate, for: mergedWT.appendingPathComponent("package.json"))
        try setModificationDate(oldDate, for: mergedWT.appendingPathComponent(".git"))
        try setModificationDate(oldDate, for: mergedWT)

        // Worktree 2: Unmerged commit + Dirty untracked file
        let dirtyWT = box.workspaceRoot.appendingPathComponent("wt-dirty", isDirectory: true)
        try runGit(["worktree", "add", "-b", "feat/wip-branch", dirtyWT.path, "main"], in: mainRepo)
        try writeDummyFile(at: dirtyWT.appendingPathComponent("feature.swift"), content: "let x = 1\n")
        let trackedBuildFile = dirtyWT.appendingPathComponent(".next/keep.js")
        try writeDummyFile(at: trackedBuildFile)
        try runGit(["add", "feature.swift"], in: dirtyWT)
        try runGit(["add", "-f", ".next/keep.js"], in: dirtyWT)
        try runGit(["commit", "-m", "wip unmerged commit"], in: dirtyWT)
        try writeDummyFile(at: dirtyWT.appendingPathComponent("untracked-notes.txt"), content: "do not lose me\n")
        let artifactFile = dirtyWT.appendingPathComponent("node_modules/cache.js")
        try writeDummyFile(at: artifactFile)

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
        #expect(!mergedItem.isEligibleForSafeSweep())
        #expect(mergedItem.worktree?.statusBadgeText == "Merged")

        let dirtyItem = try #require(worktrees.first { $0.path.lastPathComponent == "wt-dirty" })
        #expect(dirtyItem.worktree?.isMergedIntoMain == false)
        #expect(dirtyItem.protection.hasUncommittedChanges == true)
        #expect(dirtyItem.protection.isShielded == true)
        #expect(dirtyItem.effectiveSafetyTier == .protectedManual)
        #expect(dirtyItem.worktree?.statusBadgeText == "Unmerged")
        let buildFolder = try #require(dirtyItem.worktreeArtifacts?.first)
        #expect(dirtyItem.worktreeArtifacts?.count == 1)
        #expect(buildFolder.path.lastPathComponent == "node_modules")
        #expect(buildFolder.containingWorktreePath == dirtyItem.path)
        #expect(buildFolder.effectiveSafetyTier == .protectedManual)
        #expect(!buildFolder.isEligibleForSafeSweep(minimumStaleDays: 0))
        #expect(items.allSatisfy { $0.id != buildFolder.id })

        // Execute cleanup on the merged & clean worktree via CleanupExecutor (`git worktree remove`)
        let inspector = SafetyInspector(homeDirectory: box.fakeHomeRoot)
        let auditStore = AuditLogStore(storageDirectory: box.auditRoot)
        let executor = CleanupExecutor(
            safetyInspector: inspector,
            auditStore: auditStore,
            customTrashDirectory: box.trashRoot
        )

        let overlap = try executor.execute(
            items: [dirtyItem, buildFolder], mode: .moveToTrash, dryRun: true,
            allowedWorkspaceRoots: [box.workspaceRoot]
        )
        #expect(overlap.items.last?.errorDescription != nil)

        try runGit(["add", "-f", "node_modules/cache.js"], in: dirtyWT)
        let newlyTracked = try executor.execute(
            items: [buildFolder], mode: .moveToTrash, allowedWorkspaceRoots: [box.workspaceRoot]
        )
        #expect(newlyTracked.items.first?.errorDescription != nil)
        #expect(FileManager.default.fileExists(atPath: artifactFile.path))
        try runGit(["reset", "HEAD", "--", "node_modules/cache.js"], in: dirtyWT)

        let partialCleanup = try executor.execute(
            items: [buildFolder], mode: .moveToTrash, allowedWorkspaceRoots: [box.workspaceRoot]
        )
        #expect(partialCleanup.items.first?.errorDescription == nil)
        #expect(partialCleanup.restorableItemCount == 1)
        #expect(!FileManager.default.fileExists(atPath: artifactFile.path))
        #expect(FileManager.default.fileExists(atPath: trackedBuildFile.path))
        #expect(FileManager.default.fileExists(atPath: dirtyWT.appendingPathComponent("untracked-notes.txt").path))

        let unconfirmed = try executor.execute(
            items: [mergedItem],
            mode: .moveToTrash,
            allowedWorkspaceRoots: [box.workspaceRoot]
        )
        #expect(unconfirmed.items.first?.errorDescription != nil)
        #expect(FileManager.default.fileExists(atPath: mergedWT.path))

        let ignoredFile = mergedWT.appendingPathComponent(".env")
        try writeDummyFile(at: ignoredFile, content: "LOCAL_TEST_DATA=1")
        let protected = try executor.execute(
            items: [mergedItem],
            mode: .moveToTrash,
            allowedWorkspaceRoots: [box.workspaceRoot],
            allowIrreversibleToolTasks: true
        )
        #expect(protected.items.first?.errorDescription != nil)
        #expect(FileManager.default.fileExists(atPath: ignoredFile.path))
        try FileManager.default.removeItem(at: ignoredFile)

        let session = try executor.execute(
            items: [mergedItem],
            mode: .moveToTrash,
            allowedWorkspaceRoots: [box.workspaceRoot],
            allowIrreversibleToolTasks: true
        )
        #expect(session.items.first?.errorDescription == nil)
        #expect(session.restorableItemCount == 0)
        #expect(FileManager.default.fileExists(atPath: mergedWT.path) == false)
        #expect(FileManager.default.fileExists(atPath: dirtyWT.path) == true)
    }

    @Test("Build folders with embedded Git checkouts are omitted and stale selections are blocked")
    func protectsEmbeddedGitCheckouts() async throws {
        let box = try TestSandbox()
        defer { box.cleanup() }

        let mainRepo = box.workspaceRoot.appendingPathComponent("main", isDirectory: true)
        try writeDummyFile(at: mainRepo.appendingPathComponent("package.json"), content: "{}")
        try writeDummyFile(at: mainRepo.appendingPathComponent(".gitignore"), content: "node_modules/\n.next/\n")
        func runGit(_ arguments: [String], in directory: URL) throws {
            try CommandRunner.run("/usr/bin/git", arguments: ["-C", directory.path] + arguments, timeout: 5)
        }
        try runGit(["init", "-b", "main"], in: mainRepo)
        try runGit(["add", "package.json", ".gitignore"], in: mainRepo)
        try runGit(["-c", "user.name=Husk Test", "-c", "user.email=test@husk.app",
                    "-c", "commit.gpgsign=false", "commit", "-m", "initial"], in: mainRepo)

        let outer = box.workspaceRoot.appendingPathComponent("outer", isDirectory: true)
        try runGit(["worktree", "add", "-b", "outer", outer.path], in: mainRepo)
        let worktreeArtifact = outer.appendingPathComponent("node_modules", isDirectory: true)
        let standardArtifact = mainRepo.appendingPathComponent(".next", isDirectory: true)
        try writeDummyFile(at: worktreeArtifact.appendingPathComponent("generated.js"))
        try writeDummyFile(at: standardArtifact.appendingPathComponent("generated.js"))

        let config = ScanConfiguration(workspaceRoots: [box.workspaceRoot], homeDirectory: box.fakeHomeRoot,
                                       includeGlobalCaches: false)
        let scanner = APFSBlockScanner()
        let initialItems = await scanner.scan(configuration: config)
        let outerItem = try #require(initialItems.first { $0.worktree != nil && $0.path.lastPathComponent == "outer" })
        let selectedWorktreeArtifact = try #require(outerItem.worktreeArtifacts?.first)
        let selectedStandardArtifact = try #require(initialItems.first { $0.path == standardArtifact.standardizedFileURL })

        let embeddedWorktree = worktreeArtifact.appendingPathComponent(".embedded", isDirectory: true)
        try runGit(["worktree", "add", "-b", "embedded", embeddedWorktree.path], in: mainRepo)
        let worktreeNotes = embeddedWorktree.appendingPathComponent("local-notes.txt")
        try writeDummyFile(at: worktreeNotes, content: "Work in progress")

        let embeddedRepo = standardArtifact.appendingPathComponent("local-repository", isDirectory: true)
        let repositoryNotes = embeddedRepo.appendingPathComponent("notes.txt")
        try writeDummyFile(at: repositoryNotes, content: "Keep these files")
        try runGit(["init"], in: embeddedRepo)

        let rescanned = await scanner.scan(configuration: config)
        let rescannedOuter = try #require(rescanned.first { $0.id == outerItem.id })
        #expect(rescannedOuter.worktreeArtifacts?.isEmpty != false)
        #expect(rescanned.allSatisfy { $0.path != standardArtifact.standardizedFileURL })
        #expect(rescanned.contains { $0.worktree != nil && $0.path.lastPathComponent == ".embedded" })

        let executor = CleanupExecutor(safetyInspector: SafetyInspector(homeDirectory: box.fakeHomeRoot),
                                       auditStore: AuditLogStore(storageDirectory: box.auditRoot),
                                       customTrashDirectory: box.trashRoot)
        let staleSelection = [selectedWorktreeArtifact, selectedStandardArtifact]
        let dryRun = try executor.execute(items: staleSelection, mode: .permanentDelete, dryRun: true,
                                         allowedWorkspaceRoots: [box.workspaceRoot])
        let trashAttempt = try executor.execute(items: staleSelection, mode: .moveToTrash,
                                               allowedWorkspaceRoots: [box.workspaceRoot])
        #expect(dryRun.items.count == 2)
        #expect(trashAttempt.items.count == 2)
        #expect((dryRun.items + trashAttempt.items).allSatisfy {
            $0.errorDescription?.contains("contains a Git checkout") == true
        })
        #expect(FileManager.default.fileExists(atPath: worktreeNotes.path))
        #expect(FileManager.default.fileExists(atPath: repositoryNotes.path))
    }

    @Test("Old Trash records cannot claim or restore an item at a reused path")
    func refusesUnverifiedTrashRecords() throws {
        let box = try TestSandbox()
        defer { box.cleanup() }

        let reusedPath = box.trashRoot.appendingPathComponent("node_modules")
        try writeDummyFile(at: reusedPath, content: "Current item")
        let currentOrigin = box.workspaceRoot.appendingPathComponent("current/node_modules")
        let legacyOrigin = box.workspaceRoot.appendingPathComponent("old/node_modules")
        let current = CleanedItemRecord(title: "node_modules", projectName: "Current", category: .projectArtifacts,
                                       ecosystem: .node, originalPath: currentOrigin.path, trashedPath: reusedPath.path,
                                       sizeBytes: 256)
        let encodedLegacy = try JSONEncoder().encode(
            CleanedItemRecord(title: "node_modules", projectName: "Old", category: .projectArtifacts, ecosystem: .node,
                              originalPath: legacyOrigin.path, trashedPath: reusedPath.path, sizeBytes: 1_024)
        )
        var oldFields = try #require(JSONSerialization.jsonObject(with: encodedLegacy) as? [String: Any])
        oldFields.removeValue(forKey: "trashedIdentity")
        let legacy = try JSONDecoder().decode(CleanedItemRecord.self, from: JSONSerialization.data(withJSONObject: oldFields))

        let legacySession = CleanupSessionRecord(mode: .moveToTrash, wasDryRun: false, totalBytesReclaimed: 0, items: [legacy])
        let currentSession = CleanupSessionRecord(mode: .moveToTrash, wasDryRun: false, totalBytesReclaimed: 0, items: [current])
        #expect(legacySession.remainingTrash.itemStatuses[legacy.id] == .unverified)
        #expect(legacySession.remainingTrash.urls.isEmpty)
        #expect(legacySession.remainingTrash.estimatedBytes == 0)
        #expect(legacySession.restorableItemCount == 0)
        #expect(currentSession.remainingTrash.itemStatuses[current.id] == .verified(reusedPath.standardizedFileURL))
        #expect(currentSession.remainingTrash.estimatedBytes == 256)

        let executor = CleanupExecutor(auditStore: AuditLogStore(storageDirectory: box.auditRoot),
                                       customTrashDirectory: box.trashRoot)
        let denied = try executor.undoSession(legacySession)
        #expect(denied.items.first?.isRestored == false)
        #expect(FileManager.default.fileExists(atPath: reusedPath.path))
        #expect(!FileManager.default.fileExists(atPath: legacyOrigin.path))

        let allowed = try executor.undoSession(currentSession)
        #expect(allowed.items.first?.isRestored == true)
        #expect(try String(contentsOf: currentOrigin, encoding: .utf8) == "Current item")
        #expect(legacySession.remainingTrash.itemStatuses[legacy.id] == .unavailable)
    }

    @Test("Cleanup refuses a replaced folder and any symlink in its parents")
    func rejectsChangedCleanupPaths() async throws {
        let box = try TestSandbox()
        defer { box.cleanup() }
        let fm = FileManager.default
        let project = box.workspaceRoot.appendingPathComponent("app")
        let artifact = project.appendingPathComponent("node_modules")
        try writeDummyFile(at: project.appendingPathComponent("package.json"), content: "{}")
        try writeDummyFile(at: artifact.appendingPathComponent("test.js"))
        let items = await APFSBlockScanner().scan(configuration: ScanConfiguration(
            workspaceRoots: [box.workspaceRoot], homeDirectory: box.fakeHomeRoot, includeGlobalCaches: false
        ))
        let item = try #require(items.first)
        let executor = CleanupExecutor(safetyInspector: SafetyInspector(homeDirectory: box.fakeHomeRoot),
                                       auditStore: AuditLogStore(storageDirectory: box.auditRoot),
                                       customTrashDirectory: box.trashRoot)

        let savedArtifact = project.appendingPathComponent("previous-artifact")
        try fm.moveItem(at: artifact, to: savedArtifact)
        try writeDummyFile(at: artifact.appendingPathComponent("keep.js"))
        let changed = try executor.execute(items: [item], mode: .permanentDelete,
                                          allowedWorkspaceRoots: [box.workspaceRoot])
        #expect(changed.items.first?.errorDescription != nil)
        #expect(fm.fileExists(atPath: artifact.appendingPathComponent("keep.js").path))

        let renamedProject = box.workspaceRoot.appendingPathComponent("other-project")
        try fm.moveItem(at: project, to: renamedProject)
        try fm.createSymbolicLink(at: project, withDestinationURL: renamedProject)
        #expect(throws: SafetyValidationError.symbolicLinkRejected(artifact.path)) {
            try executor.safetyInspector.validateDeletionTarget(artifact, allowedWorkspaceRoots: [box.workspaceRoot]).get()
        }
    }

    @Test("Tool commands with no storage changes report zero and output cannot block the runner")
    func toolCommandOutputAndAccounting() throws {
        let box = try TestSandbox()
        defer { box.cleanup() }
        let cache = box.workspaceRoot.appendingPathComponent("cache")
        try writeDummyFile(at: cache.appendingPathComponent("data.bin"), sizeBytes: 32_768)
        let item = CleanupItem(ruleId: "test.tool", title: "Test", projectName: "Test", path: cache,
                               category: .projectArtifacts, ecosystem: .git, baseSafetyTier: .safeRebuildable,
                               allocatedSizeBytes: 32_768, fileCount: 1, lastModified: .distantPast,
                               protection: .init(isGitRepo: false, hasUncommittedChanges: false,
                                                 daysSinceLastActivity: 40, hasActiveProcess: false,
                                                 activeShieldWindowDays: 7),
                               regenerateHint: "", actionKind: .toolCommand(
                                   executable: "/bin/sh",
                                   arguments: ["-c", "dd if=/dev/zero bs=1024 count=256; dd if=/dev/zero bs=1024 count=256 >&2"],
                                   displayCommand: "Test output"
                               ))
        let executor = CleanupExecutor(safetyInspector: SafetyInspector(homeDirectory: box.fakeHomeRoot),
                                       auditStore: AuditLogStore(storageDirectory: box.auditRoot))
        let session = try executor.execute(items: [item], mode: .moveToTrash, allowedWorkspaceRoots: [box.workspaceRoot],
                                           allowIrreversibleToolTasks: true)
        #expect(session.items.first?.errorDescription == nil)
        #expect(session.items.first?.sizeBytes == 0)
        #expect(session.totalBytesReclaimed == 0)
        #expect(throws: (any Error).self) {
            try CommandRunner.run("/bin/sleep", arguments: ["10"], timeout: 0.1)
        }
    }

    @Test("In-app updates require HTTPS and a signature from the trusted signing key")
    func verifiesReleaseAuthenticity() async throws {
        let archive = Data("test archive".utf8)
        let signer = Curve25519.Signing.PrivateKey()
        let signature = try signer.signature(for: archive).base64EncodedString()
        let trustedKey = signer.publicKey.rawRepresentation.base64EncodedString()
        try UpdateService.verifyArchiveSignature(archive, signature: signature, publicKey: trustedKey)
        #expect(throws: (any Error).self) {
            try UpdateService.verifyArchiveSignature(archive, signature: signature)
        }
        #expect(throws: (any Error).self) {
            try UpdateService.verifyArchiveSignature(archive + Data([0]), signature: signature, publicKey: trustedKey)
        }
        let httpFeed = await UpdateService().checkForUpdates(source: "http://example.invalid/latest.json")
        #expect(httpFeed == .failed(message: "Update feed URLs must use HTTPS."))
    }

    @Test("The bundled changelog presents upgrades in order and shows them only once per version")
    func changelogVersionSelection() throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let content = try String(contentsOf: repository.appendingPathComponent("CHANGELOG.md"), encoding: .utf8)
        let releases = ChangelogRelease.parse(content)
        let current = try #require(SemanticVersion(string: "1.0.6"))
        let previous = try #require(SemanticVersion(string: "1.0.2"))
        #expect(releases.map(\.id).suffix(7) == ["1.0.6", "1.0.5", "1.0.4", "1.0.3", "1.0.2", "1.0.1", "1.0.0"])
        #expect(ChangelogRelease.whatsNew(in: releases, current: current, previous: previous).map(\.id)
                == ["1.0.6", "1.0.5", "1.0.4", "1.0.3"])
        #expect(ChangelogRelease.whatsNew(in: releases, current: current, previous: nil).map(\.id) == ["1.0.6"])
        #expect(ChangelogRelease.whatsNew(in: releases, current: current, previous: current).isEmpty)
    }

    @Test("Scan comparisons persist two matching snapshots and count growth once per project")
    func comparesSavedScans() async throws {
        let box = try TestSandbox()
        defer { box.cleanup() }
        let store = ScanHistoryStore(storageDirectory: box.auditRoot)
        let configuration = ScanConfiguration(workspaceRoots: [box.workspaceRoot], includeGlobalCaches: false)
        let scope = ScanSnapshot.Scope(configuration: configuration, excludedPaths: [])
        let project = box.workspaceRoot.appendingPathComponent("app")
        let firstDate = Date(timeIntervalSince1970: 1_000)
        func artifact(_ folder: String, _ bytes: Int64) -> CleanupItem {
            CleanupItem(ruleId: folder, title: folder, projectName: "app", projectRootPath: project,
                        path: project.appendingPathComponent(folder), category: .projectArtifacts, ecosystem: .node,
                        baseSafetyTier: .safeRebuildable, allocatedSizeBytes: bytes, fileCount: 1,
                        lastModified: firstDate,
                        protection: .init(isGitRepo: false, hasUncommittedChanges: false, daysSinceLastActivity: 40,
                                          hasActiveProcess: false, activeShieldWindowDays: 7),
                        regenerateHint: "")
        }

        let first = ScanSnapshot(scope: scope, startedAt: firstDate, items: [
            artifact("node_modules", 100), artifact(".turbo", 60)
        ])
        #expect(try await store.record(first) == nil)
        var nested = artifact("ignored-child", 900)
        nested.containingWorktreePath = project
        let second = ScanSnapshot(scope: scope, startedAt: firstDate.addingTimeInterval(60), items: [
            artifact("node_modules", 150), artifact(".next", 80), nested, artifact(".next", 80)
        ])
        let reopened = ScanHistoryStore(storageDirectory: box.auditRoot)
        let comparison = try await reopened.record(second)
        let growing = try #require(comparison?.growingProjects.first)
        #expect(comparison?.previousScanDate == firstDate)
        #expect(growing.bytesAdded == 70)
        #expect(growing.growingArtifacts.map(\.title) == [".next", "node_modules"])
        #expect(growing.growingArtifacts.map(\.bytesAdded) == [80, 50])
        #expect(growing.growingArtifacts.map(\.isNew) == [true, false])
        _ = try await reopened.record(second)

        let historyURL = box.auditRoot.appendingPathComponent("scan-history.json")
        let saved = try JSONDecoder().decode([ScanSnapshot].self, from: Data(contentsOf: historyURL))
        #expect(saved.count == 2)

        let changedScope = ScanSnapshot.Scope(configuration: configuration, excludedPaths: [project.path])
        let rebased = ScanSnapshot(scope: changedScope, startedAt: Date(), items: [])
        #expect(try await reopened.record(rebased) == nil)
    }

    @Test("Docker storage reads machine output for a local socket and rejects remote contexts")
    func readsDockerStorage() throws {
        let box = try TestSandbox()
        defer { box.cleanup() }
        let executable = box.sandboxRoot.appendingPathComponent("docker-fixture")
        func installFixture(endpoint: String) throws {
            let script = """
            #!/bin/sh
            case "$*" in
              "context show") printf '%s\\n' desktop-linux ;;
              "context inspect --format {{.Endpoints.docker.Host}} -- desktop-linux") printf '%s\\n' '\(endpoint)' ;;
              "--host unix:///tmp/docker.sock system df --format {{json .}}")
                printf '%s\\n' '{"Type":"Images","TotalCount":"3","Active":"1","Size":"2GB","Reclaimable":"1GB (50%)"}'
                printf '%s\\n' '{"Type":"Local Volumes","TotalCount":"1","Active":"1","Size":"8MB","Reclaimable":"0B (0%)"}'
                printf '%s\\n' '{"Type":"Build Cache","TotalCount":"4","Active":"0","Size":"96MB","Reclaimable":"96MB"}'
                ;;
              *) exit 2 ;;
            esac
            """
            try script.write(to: executable, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        }

        try installFixture(endpoint: "unix:///tmp/docker.sock")
        let snapshot = try DockerStorageService.read(using: executable.path)
        #expect(snapshot.context == "desktop-linux")
        #expect(snapshot.rows.map(\.type) == ["Images", "Local Volumes", "Build Cache"])
        #expect(snapshot.rows.first?.reclaimable == "1GB (50%)")
        #expect(throws: (any Error).self) { try DockerStorageService.parse("not Docker JSON") }

        try installFixture(endpoint: "tcp://example.invalid:2376")
        do {
            _ = try DockerStorageService.read(using: executable.path)
            Issue.record("Expected a remote Docker context to be rejected")
        } catch {
            #expect(error.localizedDescription.contains("is remote"))
        }
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
