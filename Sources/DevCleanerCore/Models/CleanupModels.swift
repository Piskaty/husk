import Foundation

public enum CleanupCategory: String, CaseIterable, Codable, Sendable, Identifiable {
    case projectArtifacts = "project_artifacts"
    case packageCaches = "package_caches"
    case xcodeClutter = "xcode_clutter"
    case containersAndAI = "containers_and_ai"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .projectArtifacts: return "Project Artifacts"
        case .packageCaches: return "Package Caches"
        case .xcodeClutter: return "Xcode & Apple"
        case .containersAndAI: return "Containers & AI"
        }
    }

    public var subtitle: String {
        switch self {
        case .projectArtifacts: return "node_modules, target/, .build/, .venv, .next, .gradle"
        case .packageCaches: return "bun, pnpm, npm, yarn, cargo, uv, pip, Homebrew"
        case .xcodeClutter: return "DerivedData, DeviceSupport, Simulators, Archives"
        case .containersAndAI: return "HuggingFace Hub, Ollama models, PyTorch, Docker caches"
        }
    }

    public var systemImage: String {
        switch self {
        case .projectArtifacts: return "folder"
        case .packageCaches: return "shippingbox"
        case .xcodeClutter: return "hammer"
        case .containersAndAI: return "cpu"
        }
    }
}

public enum SafetyTier: Int, CaseIterable, Codable, Sendable, Comparable, Identifiable {
    case safeRebuildable = 1
    case cautionRedownload = 2
    case protectedManual = 3

    public var id: Int { rawValue }

    public static func < (lhs: SafetyTier, rhs: SafetyTier) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var title: String {
        switch self {
        case .safeRebuildable: return "Tier 1 • Safe / Rebuildable"
        case .cautionRedownload: return "Tier 2 • Re-download Cache"
        case .protectedManual: return "Tier 3 • Protected / Manual"
        }
    }

    public var shortLabel: String {
        switch self {
        case .safeRebuildable: return "Safe Rebuild"
        case .cautionRedownload: return "Re-download"
        case .protectedManual: return "Protected"
        }
    }

    public var badgeIcon: String {
        switch self {
        case .safeRebuildable: return "checkmark.shield.fill"
        case .cautionRedownload: return "arrow.down.circle.fill"
        case .protectedManual: return "lock.shield.fill"
        }
    }

    public var explanation: String {
        switch self {
        case .safeRebuildable:
            return "100% deterministic local artifact. Safely regenerated anytime with your install or build command."
        case .cautionRedownload:
            return "Global package cache or downloadable SDK support files. Safe to delete, but requires bandwidth to re-fetch."
        case .protectedManual:
            return "Belongs to an active/dirty git project, or holds release Archives (dSYMs) / large local AI models. Never auto-selected."
        }
    }
}

public enum Ecosystem: String, CaseIterable, Codable, Sendable, Identifiable {
    case node = "node"
    case rust = "rust"
    case swift = "swift"
    case python = "python"
    case jvm = "jvm"
    case xcode = "xcode"
    case homebrew = "homebrew"
    case docker = "docker"
    case aiModels = "ai_models"
    case git = "git"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .node: return "Node & Web"
        case .rust: return "Rust"
        case .swift: return "Swift"
        case .python: return "Python"
        case .jvm: return "JVM & Gradle"
        case .xcode: return "Xcode"
        case .homebrew: return "Homebrew"
        case .docker: return "Docker"
        case .aiModels: return "AI & ML"
        case .git: return "Git Packfiles"
        }
    }

    public var systemImage: String {
        switch self {
        case .node: return "globe"
        case .rust: return "gearshape.2"
        case .swift: return "swift"
        case .python: return "terminal"
        case .jvm: return "cup.and.saucer"
        case .xcode: return "hammer"
        case .homebrew: return "mug"
        case .docker: return "shippingbox.and.arrow.backward"
        case .aiModels: return "brain.head.profile"
        case .git: return "arrow.triangle.branch"
        }
    }
}

public enum StalenessBucket: String, CaseIterable, Codable, Sendable, Identifiable {
    case active = "active"     // < 7 days
    case warm = "warm"         // 7 - 30 days
    case stale = "stale"       // 30 - 90 days
    case ancient = "ancient"   // > 90 days

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .active: return "Active (<7d)"
        case .warm: return "Warm (7–30d)"
        case .stale: return "Stale (30–90d)"
        case .ancient: return "Ancient (90d+)"
        }
    }

    public var shortTitle: String {
        switch self {
        case .active: return "< 7d"
        case .warm: return "7–30d"
        case .stale: return "30–90d"
        case .ancient: return "90d+"
        }
    }

    public static func from(days: Int) -> StalenessBucket {
        if days < 7 {
            return .active
        } else if days < 30 {
            return .warm
        } else if days < 90 {
            return .stale
        } else {
            return .ancient
        }
    }
}

public enum CleanupActionKind: Codable, Sendable, Equatable {
    case filesystem
    case toolCommand(executable: String, arguments: [String], displayCommand: String)

    public var isToolCommand: Bool {
        if case .toolCommand = self { return true }
        return false
    }

    public var displayCommandString: String? {
        if case .toolCommand(_, _, let displayCommand) = self {
            return displayCommand
        }
        return nil
    }
}

public struct ProjectProtectionState: Codable, Sendable, Equatable {
    public var isGitRepo: Bool
    public var hasUncommittedChanges: Bool
    public var daysSinceLastActivity: Int
    public var hasActiveProcess: Bool
    public var activeShieldWindowDays: Int
    public var gitBranch: String?
    public var isReadOnlyClone: Bool

    public init(
        isGitRepo: Bool = false,
        hasUncommittedChanges: Bool = false,
        daysSinceLastActivity: Int = 999,
        hasActiveProcess: Bool = false,
        activeShieldWindowDays: Int = 7,
        gitBranch: String? = nil,
        isReadOnlyClone: Bool = false
    ) {
        self.isGitRepo = isGitRepo
        self.hasUncommittedChanges = hasUncommittedChanges
        self.daysSinceLastActivity = daysSinceLastActivity
        self.hasActiveProcess = hasActiveProcess
        self.activeShieldWindowDays = activeShieldWindowDays
        self.gitBranch = gitBranch
        self.isReadOnlyClone = isReadOnlyClone
    }

    public var isRecentlyActive: Bool {
        daysSinceLastActivity < activeShieldWindowDays
    }

    public var isShielded: Bool {
        hasActiveProcess || hasUncommittedChanges || (isGitRepo && isRecentlyActive)
    }

    /// True when the project is an untouched read-only clone (30d+ old with 0 local user commits) or dormant for 120+ days.
    public var isDormantOrOrphaned: Bool {
        guard !isShielded else { return false }
        if isReadOnlyClone && daysSinceLastActivity >= 21 {
            return true
        }
        return daysSinceLastActivity >= 120
    }

    public var dormantBadgeText: String? {
        guard isDormantOrOrphaned else { return nil }
        if isReadOnlyClone {
            return "Read-Only Clone"
        }
        return "Dormant"
    }

    public var shieldReasons: [String] {
        var reasons: [String] = []
        if hasActiveProcess {
            reasons.append("Running process")
        }
        if hasUncommittedChanges {
            reasons.append("Dirty git tree")
        }
        if isGitRepo && isRecentlyActive {
            if daysSinceLastActivity <= 0 {
                reasons.append("Active today")
            } else {
                reasons.append("Active \(daysSinceLastActivity)d ago")
            }
        }
        return reasons
    }

    public var shieldSummary: String? {
        let reasons = shieldReasons
        guard !reasons.isEmpty else { return nil }
        return reasons.joined(separator: " • ")
    }
}

public struct CleanupItem: Identifiable, Codable, Sendable, Equatable {
    public let id: String
    public let ruleId: String
    public let title: String
    public let projectName: String
    public let projectRootPath: URL?
    public let path: URL
    public let category: CleanupCategory
    public let ecosystem: Ecosystem
    public let baseSafetyTier: SafetyTier
    public let allocatedSizeBytes: Int64
    public let fileCount: Int
    public let lastModified: Date
    public let protection: ProjectProtectionState
    public let regenerateHint: String
    public let rebuildCommand: String?
    public let actionKind: CleanupActionKind

    public init(
        id: String? = nil,
        ruleId: String,
        title: String,
        projectName: String,
        projectRootPath: URL? = nil,
        path: URL,
        category: CleanupCategory,
        ecosystem: Ecosystem,
        baseSafetyTier: SafetyTier,
        allocatedSizeBytes: Int64,
        fileCount: Int,
        lastModified: Date,
        protection: ProjectProtectionState,
        regenerateHint: String,
        rebuildCommand: String? = nil,
        actionKind: CleanupActionKind = .filesystem
    ) {
        self.id = id ?? path.standardizedFileURL.path
        self.ruleId = ruleId
        self.title = title
        self.projectName = projectName
        self.projectRootPath = projectRootPath
        self.path = path.standardizedFileURL
        self.category = category
        self.ecosystem = ecosystem
        self.baseSafetyTier = baseSafetyTier
        self.allocatedSizeBytes = allocatedSizeBytes
        self.fileCount = fileCount
        self.lastModified = lastModified
        self.protection = protection
        self.regenerateHint = regenerateHint
        self.rebuildCommand = rebuildCommand
        self.actionKind = actionKind
    }

    public var effectiveSafetyTier: SafetyTier {
        if protection.isShielded {
            return .protectedManual
        }
        return baseSafetyTier
    }

    public var stalenessDays: Int {
        max(0, protection.daysSinceLastActivity)
    }

    public var stalenessBucket: StalenessBucket {
        StalenessBucket.from(days: stalenessDays)
    }

    public var formattedSize: String {
        ByteFormatting.string(from: allocatedSizeBytes)
    }

    public var displayPath: String {
        if let cmd = actionKind.displayCommandString {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            let shortPath = path.path.hasPrefix(home)
                ? "~" + path.path.dropFirst(home.count)
                : path.path
            return "\(shortPath) · \(cmd)"
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.path.hasPrefix(home) {
            return "~" + path.path.dropFirst(home.count)
        }
        return path.path
    }

    public func isEligibleForSafeSweep(minimumStaleDays: Int = 30) -> Bool {
        guard !protection.isShielded else { return false }
        guard effectiveSafetyTier == .safeRebuildable else { return false }
        return stalenessDays >= minimumStaleDays
    }
}

public enum DeletionMode: String, Codable, Sendable, CaseIterable, Identifiable {
    case moveToTrash = "move_to_trash"
    case permanentDelete = "permanent_delete"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .moveToTrash: return "Move to macOS Trash (Safe & Undoable)"
        case .permanentDelete: return "Delete Permanently (Immediate)"
        }
    }

    public var shortTitle: String {
        switch self {
        case .moveToTrash: return "Move to Trash"
        case .permanentDelete: return "Permanent Delete"
        }
    }
}

public struct DryRunManifest: Codable, Sendable, Equatable {
    public let generatedAt: Date
    public let mode: DeletionMode
    public let items: [CleanupItem]
    public let totalBytes: Int64
    public let totalFiles: Int
    public let bytesByTier: [SafetyTier: Int64]
    public let bytesByCategory: [CleanupCategory: Int64]
    public let warnings: [String]

    public init(items: [CleanupItem], mode: DeletionMode, generatedAt: Date = Date()) {
        self.generatedAt = generatedAt
        self.mode = mode
        self.items = items
        self.totalBytes = items.reduce(0) { $0 + $1.allocatedSizeBytes }
        self.totalFiles = items.reduce(0) { $0 + $1.fileCount }

        var tierMap: [SafetyTier: Int64] = [:]
        var catMap: [CleanupCategory: Int64] = [:]
        for item in items {
            tierMap[item.effectiveSafetyTier, default: 0] += item.allocatedSizeBytes
            catMap[item.category, default: 0] += item.allocatedSizeBytes
        }
        self.bytesByTier = tierMap
        self.bytesByCategory = catMap

        var notes: [String] = []
        let shieldedItems = items.filter { $0.protection.isShielded }
        if !shieldedItems.isEmpty {
            notes.append("Includes \(shieldedItems.count) active/shielded project item(s).")
        }
        let toolItems = items.filter { $0.actionKind.isToolCommand }
        if !toolItems.isEmpty {
            notes.append("Includes \(toolItems.count) CLI tool subcommand task(s) (e.g. git gc / simctl / brew / docker).")
        }
        if mode == .permanentDelete {
            notes.append("Permanent Delete is selected: items bypass macOS Trash and cannot be undone.")
        }
        self.warnings = notes
    }

    public func toMarkdown() -> String {
        var lines: [String] = []
        let formatter = ISO8601DateFormatter()
        lines.append("# Husk Dry-Run Manifest")
        lines.append("- **Generated**: \(formatter.string(from: generatedAt))")
        lines.append("- **Action Mode**: \(mode.title)")
        lines.append("- **Selected Items**: \(items.count) (\(totalFiles) files)")
        lines.append("- **Total Space to Reclaim**: \(ByteFormatting.string(from: totalBytes))")
        lines.append("")
        if !warnings.isEmpty {
            lines.append("## Warnings")
            for warning in warnings {
                lines.append("- ⚠️ \(warning)")
            }
            lines.append("")
        }
        lines.append("## Target Paths")
        lines.append("| Project / Target | Artifact | Safety Tier | Size | Path / Command |")
        lines.append("| :--- | :--- | :--- | ---: | :--- |")
        for item in items {
            lines.append("| \(item.projectName) | `\(item.title)` | \(item.effectiveSafetyTier.shortLabel) | \(item.formattedSize) | `\(item.displayPath)` |")
        }
        return lines.joined(separator: "\n")
    }
}

public struct CleanedItemRecord: Codable, Sendable, Equatable, Identifiable {
    public var id: String { originalPath }
    public let title: String
    public let projectName: String
    public let category: CleanupCategory
    public let ecosystem: Ecosystem
    public let originalPath: String
    public let trashedPath: String?
    public let sizeBytes: Int64
    public var isRestored: Bool
    public let errorDescription: String?
    public let rebuildCommand: String?

    public init(
        title: String,
        projectName: String,
        category: CleanupCategory,
        ecosystem: Ecosystem,
        originalPath: String,
        trashedPath: String?,
        sizeBytes: Int64,
        isRestored: Bool = false,
        errorDescription: String? = nil,
        rebuildCommand: String? = nil
    ) {
        self.title = title
        self.projectName = projectName
        self.category = category
        self.ecosystem = ecosystem
        self.originalPath = originalPath
        self.trashedPath = trashedPath
        self.sizeBytes = sizeBytes
        self.isRestored = isRestored
        self.errorDescription = errorDescription
        self.rebuildCommand = rebuildCommand
    }

    public var canRestore: Bool {
        guard !isRestored, errorDescription == nil, let trashedPath else { return false }
        return FileManager.default.fileExists(atPath: trashedPath)
    }
}

public struct CleanupSessionRecord: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let timestamp: Date
    public let mode: DeletionMode
    public let wasDryRun: Bool
    public let totalBytesReclaimed: Int64
    public var items: [CleanedItemRecord]

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        mode: DeletionMode,
        wasDryRun: Bool,
        totalBytesReclaimed: Int64,
        items: [CleanedItemRecord]
    ) {
        self.id = id
        self.timestamp = timestamp
        self.mode = mode
        self.wasDryRun = wasDryRun
        self.totalBytesReclaimed = totalBytesReclaimed
        self.items = items
    }

    public var restorableItemCount: Int {
        items.filter(\.canRestore).count
    }

    public var formattedTotalReclaimed: String {
        ByteFormatting.string(from: totalBytesReclaimed)
    }

    /// Generates a shell script that re-runs the install/build command for all cleaned project items in this session.
    public var rebuildShellScript: String? {
        var seen = Set<String>()
        var commands: [String] = []
        for item in items {
            if let cmd = item.rebuildCommand, !seen.contains(cmd) {
                seen.insert(cmd)
                commands.append(cmd)
            }
        }
        guard !commands.isEmpty else { return nil }
        return (["#!/usr/bin/env zsh", "# Re-bootstrap projects cleaned in Husk session \(id.uuidString.prefix(8))"] + commands).joined(separator: "\n")
    }
}

public struct DiskSpaceSnapshot: Sendable, Equatable {
    public let freeBytes: Int64
    public let totalBytes: Int64

    public init(freeBytes: Int64, totalBytes: Int64) {
        self.freeBytes = freeBytes
        self.totalBytes = totalBytes
    }

    public var formattedFree: String {
        ByteFormatting.string(from: freeBytes)
    }

    public static func current(at url: URL = URL(fileURLWithPath: "/")) -> DiskSpaceSnapshot {
        let keys: Set<URLResourceKey> = [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey,
            .volumeTotalCapacityKey
        ]
        if let values = try? url.resourceValues(forKeys: keys) {
            let free = values.volumeAvailableCapacityForImportantUsage
                ?? Int64(values.volumeAvailableCapacity ?? 0)
            let total = Int64(values.volumeTotalCapacity ?? 0)
            return DiskSpaceSnapshot(freeBytes: free, totalBytes: total)
        }
        return DiskSpaceSnapshot(freeBytes: 0, totalBytes: 0)
    }
}

public enum ByteFormatting {
    public static func string(from bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        formatter.countStyle = .file
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter.string(fromByteCount: bytes)
    }
}
