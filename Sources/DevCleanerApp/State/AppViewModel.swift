import SwiftUI
import AppKit
import Observation
import ServiceManagement
import DevCleanerCore

public enum SidebarDestination: Hashable, Identifiable {
    case allJunk
    case safeSweep
    case category(CleanupCategory)
    case dormantClones
    case toolCleaners
    case shieldedProjects
    case tier(SafetyTier)
    case auditHistory
    case settings

    public var id: String {
        switch self {
        case .allJunk: return "all_junk"
        case .safeSweep: return "safe_sweep"
        case .category(let cat): return "cat_\(cat.rawValue)"
        case .dormantClones: return "dormant_clones"
        case .toolCleaners: return "tool_cleaners"
        case .shieldedProjects: return "shielded_projects"
        case .tier(let tier): return "tier_\(tier.rawValue)"
        case .auditHistory: return "audit_history"
        case .settings: return "settings"
        }
    }

    public var title: String {
        switch self {
        case .allJunk: return "All Items"
        case .safeSweep: return "Safe Sweep"
        case .category(let cat): return cat.title
        case .dormantClones: return "Dormant Clones"
        case .toolCleaners: return "Tool Tasks"
        case .shieldedProjects: return "Protected"
        case .tier(let tier): return tier.shortLabel
        case .auditHistory: return "History"
        case .settings: return "Settings"
        }
    }

    public var subtitle: String {
        switch self {
        case .allJunk: return "All discovered developer artifacts and caches"
        case .safeSweep: return "Rebuildable artifacts in clean, inactive projects (30d+)"
        case .category(let cat): return cat.subtitle
        case .dormantClones: return "Read-only git clones (0 local commits) and repos untouched for 120+ days"
        case .toolCleaners: return "Native CLI subcommands: git gc packfiles, simctl unavailable devices, brew cleanup"
        case .shieldedProjects: return "Protected due to recent activity, dirty git tree, or active lock"
        case .tier(let tier): return tier.explanation
        case .auditHistory: return "Past cleanup sessions with 1-click restore from Trash and rebuild scripts"
        case .settings: return "Configure safety thresholds, scan scope, exclusions, menu bar alerts, and app updates"
        }
    }

    public var systemImage: String {
        switch self {
        case .allJunk: return "square.grid.2x2"
        case .safeSweep: return "sparkles"
        case .category(let cat): return cat.systemImage
        case .dormantClones: return "moon.zzz"
        case .toolCleaners: return "terminal"
        case .shieldedProjects: return "shield"
        case .tier(let tier): return tier.badgeIcon
        case .auditHistory: return "clock.arrow.circlepath"
        case .settings: return "gearshape"
        }
    }
}

public enum ArtifactSortOrder: String, CaseIterable, Identifiable {
    case sizeDescending = "Largest Size"
    case stalenessDescending = "Oldest / Stale First"
    case projectName = "Project Name"
    case safetyTier = "Safest Tier First"

    public var id: String { rawValue }
}

public struct StatusBannerState: Identifiable, Equatable {
    public let id = UUID()
    public let title: String
    public let subtitle: String
    public let isSuccess: Bool
    public let undoableSession: CleanupSessionRecord?
    public let availableUpdate: AppReleaseInfo?

    public init(
        title: String,
        subtitle: String,
        isSuccess: Bool,
        undoableSession: CleanupSessionRecord? = nil,
        availableUpdate: AppReleaseInfo? = nil
    ) {
        self.title = title
        self.subtitle = subtitle
        self.isSuccess = isSuccess
        self.undoableSession = undoableSession
        self.availableUpdate = availableUpdate
    }
}

@Observable
@MainActor
public final class AppViewModel {
    public var allScannedItems: [CleanupItem] = []
    public var selectedIDs: Set<String> = []
    public var sidebarDestination: SidebarDestination = .allJunk
    public var selectedEcosystem: Ecosystem? = nil
    public var selectedStalenessBucket: StalenessBucket? = nil
    public var searchText: String = ""
    public var sortOrder: ArtifactSortOrder = .sizeDescending

    // Persisted Preferences
    public var workspaceRoots: [URL] = []
    public var ignoredPaths: [String] = [] {
        didSet { UserDefaults.standard.set(ignoredPaths, forKey: Keys.ignoredPaths) }
    }
    public var includeGlobalCaches: Bool = true {
        didSet { UserDefaults.standard.set(includeGlobalCaches, forKey: Keys.includeGlobalCaches) }
    }
    public var maxWorkspaceDepth: Int = 6 {
        didSet { UserDefaults.standard.set(maxWorkspaceDepth, forKey: Keys.maxWorkspaceDepth) }
    }
    public var activeShieldWindowDays: Int = 7 {
        didSet { UserDefaults.standard.set(activeShieldWindowDays, forKey: Keys.activeShieldWindowDays) }
    }
    public var safeSweepMinimumStaleDays: Int = 30 {
        didSet { UserDefaults.standard.set(safeSweepMinimumStaleDays, forKey: Keys.safeSweepMinimumStaleDays) }
    }
    public var gitGCMinimumMB: Int = 60 {
        didSet { UserDefaults.standard.set(gitGCMinimumMB, forKey: Keys.gitGCMinimumMB) }
    }
    public var menuBarAlertThresholdGB: Double = 15.0 {
        didSet { UserDefaults.standard.set(menuBarAlertThresholdGB, forKey: Keys.menuBarAlertThresholdGB) }
    }
    public var lowDiskWarningThresholdGB: Double = 35.0 {
        didSet { UserDefaults.standard.set(lowDiskWarningThresholdGB, forKey: Keys.lowDiskWarningThresholdGB) }
    }
    public var deletionMode: DeletionMode = .moveToTrash {
        didSet { UserDefaults.standard.set(deletionMode.rawValue, forKey: Keys.deletionMode) }
    }
    public var updateSource: String = UpdateService.defaultGitHubRepo {
        didSet { UserDefaults.standard.set(updateSource, forKey: Keys.updateSource) }
    }
    public var autoCheckForUpdates: Bool = true {
        didSet { UserDefaults.standard.set(autoCheckForUpdates, forKey: Keys.autoCheckForUpdates) }
    }

    public var launchAtLoginEnabled: Bool = false
    public var updateStatus: UpdateCheckStatus = .idle
    public var updateInstallPhase: UpdateInstallPhase = .idle
    public var diskSpace: DiskSpaceSnapshot = DiskSpaceSnapshot.current()

    public var isScanning: Bool = false
    public var scanProgressText: String = "Ready to scan"
    public var discoveredDuringScanCount: Int = 0
    public var discoveredDuringScanBytes: Int64 = 0
    public var lastScanDurationSeconds: Double? = nil

    public var isShowingCommandPalette: Bool = false
    public var isShowingDryRunPreview: Bool = false
    public var activeDryRunManifest: DryRunManifest? = nil
    public var auditSessions: [CleanupSessionRecord] = []
    public var statusBanner: StatusBannerState? = nil

    private let scanner = APFSBlockScanner()
    private let auditStore = AuditLogStore()
    private let updateService = UpdateService()
    private var scanTask: Task<Void, Never>? = nil

    private enum Keys {
        static let savedRoots = "Husk.WorkspaceRoots.v1"
        static let ignoredPaths = "Husk.IgnoredPaths.v1"
        static let includeGlobalCaches = "Husk.IncludeGlobalCaches.v1"
        static let maxWorkspaceDepth = "Husk.MaxWorkspaceDepth.v1"
        static let activeShieldWindowDays = "Husk.ActiveShieldWindowDays.v1"
        static let safeSweepMinimumStaleDays = "Husk.SafeSweepMinimumStaleDays.v1"
        static let gitGCMinimumMB = "Husk.GitGCMinimumMB.v1"
        static let menuBarAlertThresholdGB = "Husk.MenuBarAlertThresholdGB.v1"
        static let lowDiskWarningThresholdGB = "Husk.LowDiskWarningThresholdGB.v1"
        static let deletionMode = "Husk.DeletionMode.v1"
        static let updateSource = "Husk.UpdateSource.v1"
        static let autoCheckForUpdates = "Husk.AutoCheckForUpdates.v1"
    }

    public init() {
        let defaults = UserDefaults.standard
        self.workspaceRoots = Self.loadPersistedWorkspaceRoots()
        self.ignoredPaths = defaults.stringArray(forKey: Keys.ignoredPaths) ?? []
        if defaults.object(forKey: Keys.includeGlobalCaches) != nil {
            self.includeGlobalCaches = defaults.bool(forKey: Keys.includeGlobalCaches)
        }
        if let depth = defaults.object(forKey: Keys.maxWorkspaceDepth) as? Int, depth >= 2 {
            self.maxWorkspaceDepth = depth
        }
        if let shield = defaults.object(forKey: Keys.activeShieldWindowDays) as? Int, shield >= 1 {
            self.activeShieldWindowDays = shield
        }
        if let sweep = defaults.object(forKey: Keys.safeSweepMinimumStaleDays) as? Int, sweep >= 1 {
            self.safeSweepMinimumStaleDays = sweep
        }
        if let gc = defaults.object(forKey: Keys.gitGCMinimumMB) as? Int, gc >= 10 {
            self.gitGCMinimumMB = gc
        }
        if let mb = defaults.object(forKey: Keys.menuBarAlertThresholdGB) as? Double, mb > 0 {
            self.menuBarAlertThresholdGB = mb
        }
        if let ld = defaults.object(forKey: Keys.lowDiskWarningThresholdGB) as? Double, ld > 0 {
            self.lowDiskWarningThresholdGB = ld
        }
        if let modeRaw = defaults.string(forKey: Keys.deletionMode),
           let mode = DeletionMode(rawValue: modeRaw) {
            self.deletionMode = mode
        }
        if let src = defaults.string(forKey: Keys.updateSource), !src.isEmpty {
            self.updateSource = src
        }
        if defaults.object(forKey: Keys.autoCheckForUpdates) != nil {
            self.autoCheckForUpdates = defaults.bool(forKey: Keys.autoCheckForUpdates)
        }

        self.launchAtLoginEnabled = (SMAppService.mainApp.status == .enabled)
        self.auditSessions = auditStore.loadSessions()
        self.diskSpace = DiskSpaceSnapshot.current()
    }

    // MARK: - Computed Metrics

    /// Active items after filtering out any user-excluded paths.
    public var items: [CleanupItem] {
        guard !ignoredPaths.isEmpty else { return allScannedItems }
        return allScannedItems.filter { item in
            let itemPath = item.path.standardizedFileURL.path
            let projPath = item.projectRootPath?.standardizedFileURL.path
            return !ignoredPaths.contains { ignored in
                itemPath == ignored
                    || itemPath.hasPrefix(ignored + "/")
                    || projPath == ignored
            }
        }
    }

    public var totalFoundBytes: Int64 {
        items.reduce(0) { $0 + $1.allocatedSizeBytes }
    }

    public var formattedTotalFoundBytes: String {
        ByteFormatting.string(from: totalFoundBytes)
    }

    public var safeSweepItems: [CleanupItem] {
        items.filter { $0.isEligibleForSafeSweep(minimumStaleDays: safeSweepMinimumStaleDays) }
    }

    public var safeSweepTotalBytes: Int64 {
        safeSweepItems.reduce(0) { $0 + $1.allocatedSizeBytes }
    }

    public var formattedSafeSweepBytes: String {
        ByteFormatting.string(from: safeSweepTotalBytes)
    }

    public var dormantCloneItems: [CleanupItem] {
        items.filter { $0.protection.isDormantOrOrphaned && $0.category == .projectArtifacts }
    }

    public var dormantCloneTotalBytes: Int64 {
        dormantCloneItems.reduce(0) { $0 + $1.allocatedSizeBytes }
    }

    public var toolCommandItems: [CleanupItem] {
        items.filter { $0.actionKind.isToolCommand }
    }

    public var toolCommandTotalBytes: Int64 {
        toolCommandItems.reduce(0) { $0 + $1.allocatedSizeBytes }
    }

    public var shieldedItems: [CleanupItem] {
        items.filter(\.protection.isShielded)
    }

    public var shieldedTotalBytes: Int64 {
        shieldedItems.reduce(0) { $0 + $1.allocatedSizeBytes }
    }

    public var selectedItems: [CleanupItem] {
        items.filter { selectedIDs.contains($0.id) }
    }

    public var selectedTotalBytes: Int64 {
        selectedItems.reduce(0) { $0 + $1.allocatedSizeBytes }
    }

    public var formattedSelectedBytes: String {
        ByteFormatting.string(from: selectedTotalBytes)
    }

    public var maxItemBytes: Int64 {
        max(1, items.map(\.allocatedSizeBytes).max() ?? 1)
    }

    public var isLowDiskSpace: Bool {
        guard diskSpace.freeBytes > 0 else { return false }
        let freeGB = Double(diskSpace.freeBytes) / 1_000_000_000.0
        return freeGB < lowDiskWarningThresholdGB
    }

    public var isAboveJunkThreshold: Bool {
        let junkGB = Double(totalFoundBytes) / 1_000_000_000.0
        return junkGB >= menuBarAlertThresholdGB
    }

    public var hasAvailableUpdate: Bool {
        if case .updateAvailable = updateStatus { return true }
        return false
    }

    public var needsMenuBarAttention: Bool {
        isLowDiskSpace || isAboveJunkThreshold || hasAvailableUpdate
    }

    public var projectedFreeAfterSelectedBytes: Int64 {
        diskSpace.freeBytes + selectedTotalBytes
    }

    public var projectedFreeAfterSafeSweepBytes: Int64 {
        diskSpace.freeBytes + safeSweepTotalBytes
    }

    public func bytes(for category: CleanupCategory) -> Int64 {
        items.filter { $0.category == category }.reduce(0) { $0 + $1.allocatedSizeBytes }
    }

    public func bytes(for tier: SafetyTier) -> Int64 {
        items.filter { $0.effectiveSafetyTier == tier }.reduce(0) { $0 + $1.allocatedSizeBytes }
    }

    public func bytes(for bucket: StalenessBucket) -> Int64 {
        items.filter { $0.stalenessBucket == bucket }.reduce(0) { $0 + $1.allocatedSizeBytes }
    }

    public func count(for bucket: StalenessBucket) -> Int {
        items.filter { $0.stalenessBucket == bucket }.count
    }

    public var filteredItems: [CleanupItem] {
        var result = items

        switch sidebarDestination {
        case .allJunk:
            break
        case .safeSweep:
            result = result.filter { $0.isEligibleForSafeSweep(minimumStaleDays: safeSweepMinimumStaleDays) }
        case .category(let category):
            result = result.filter { $0.category == category }
        case .dormantClones:
            result = result.filter { $0.protection.isDormantOrOrphaned && $0.category == .projectArtifacts }
        case .toolCleaners:
            result = result.filter { $0.actionKind.isToolCommand }
        case .shieldedProjects:
            result = result.filter(\.protection.isShielded)
        case .tier(let tier):
            result = result.filter { $0.effectiveSafetyTier == tier }
        case .auditHistory, .settings:
            break
        }

        if let selectedEcosystem {
            result = result.filter { $0.ecosystem == selectedEcosystem }
        }

        if let selectedStalenessBucket {
            result = result.filter { $0.stalenessBucket == selectedStalenessBucket }
        }

        let trimmedQuery = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !trimmedQuery.isEmpty {
            result = result.filter { item in
                item.projectName.lowercased().contains(trimmedQuery)
                    || item.title.lowercased().contains(trimmedQuery)
                    || item.displayPath.lowercased().contains(trimmedQuery)
                    || item.ecosystem.title.lowercased().contains(trimmedQuery)
                    || item.category.title.lowercased().contains(trimmedQuery)
            }
        }

        switch sortOrder {
        case .sizeDescending:
            result.sort { $0.allocatedSizeBytes > $1.allocatedSizeBytes }
        case .stalenessDescending:
            result.sort {
                if $0.stalenessDays != $1.stalenessDays {
                    return $0.stalenessDays > $1.stalenessDays
                }
                return $0.allocatedSizeBytes > $1.allocatedSizeBytes
            }
        case .projectName:
            result.sort {
                $0.projectName.localizedCaseInsensitiveCompare($1.projectName) == .orderedAscending
            }
        case .safetyTier:
            result.sort {
                if $0.effectiveSafetyTier != $1.effectiveSafetyTier {
                    return $0.effectiveSafetyTier < $1.effectiveSafetyTier
                }
                return $0.allocatedSizeBytes > $1.allocatedSizeBytes
            }
        }

        return result
    }

    // MARK: - Scanning & Exclusions

    public func refreshDiskSpace() {
        diskSpace = DiskSpaceSnapshot.current()
    }

    public func startScan() {
        scanTask?.cancel()
        isScanning = true
        refreshDiskSpace()
        scanProgressText = "Scanning workspaces & caches…"
        discoveredDuringScanCount = 0
        discoveredDuringScanBytes = 0

        let config = ScanConfiguration(
            workspaceRoots: workspaceRoots,
            includeGlobalCaches: includeGlobalCaches,
            maxWorkspaceDepth: maxWorkspaceDepth,
            activeShieldWindowDays: activeShieldWindowDays,
            gitGCMinimumBytes: Int64(gitGCMinimumMB) * 1024 * 1024
        )
        let startedAt = Date()

        scanTask = Task { [weak self] in
            guard let self else { return }
            let scannedItems = await scanner.scan(configuration: config) { [weak self] progress in
                Task { @MainActor [weak self] in
                    guard let self, self.isScanning else { return }
                    self.scanProgressText = progress.currentPath
                    self.discoveredDuringScanCount = progress.discoveredCount
                    self.discoveredDuringScanBytes = progress.totalAllocatedBytes
                }
            }

            guard !Task.isCancelled else { return }
            let elapsed = Date().timeIntervalSince(startedAt)
            self.allScannedItems = scannedItems
            let validIDs = Set(self.items.map(\.id))
            self.selectedIDs = self.selectedIDs.intersection(validIDs)
            self.isScanning = false
            self.lastScanDurationSeconds = elapsed
            self.refreshDiskSpace()
            self.scanProgressText = "\(self.items.count) items · \(self.diskSpace.formattedFree) free on Mac"
        }
    }

    public func ignoreItem(_ item: CleanupItem) {
        let targetPath = (item.projectRootPath ?? item.path).standardizedFileURL.path
        if !ignoredPaths.contains(targetPath) {
            ignoredPaths.append(targetPath)
        }
        selectedIDs.remove(item.id)
        statusBanner = StatusBannerState(
            title: "Excluded \(item.projectName)",
            subtitle: "Manage excluded paths anytime in Settings.",
            isSuccess: true,
            undoableSession: nil
        )
    }

    public func removeIgnoredPath(_ path: String) {
        ignoredPaths.removeAll { $0 == path }
    }

    public func promptToAddIgnoredPath() {
        let panel = NSOpenPanel()
        panel.title = "Exclude Project or Cache Folder"
        panel.message = "Husk will never flag or clean anything inside an excluded folder."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Exclude Folder"

        if panel.runModal() == .OK {
            for url in panel.urls {
                let path = url.standardizedFileURL.path
                if !ignoredPaths.contains(path) {
                    ignoredPaths.append(path)
                }
            }
        }
    }

    public func resetDefaults() {
        activeShieldWindowDays = 7
        safeSweepMinimumStaleDays = 30
        includeGlobalCaches = true
        maxWorkspaceDepth = 6
        gitGCMinimumMB = 60
        menuBarAlertThresholdGB = 15.0
        lowDiskWarningThresholdGB = 35.0
        deletionMode = .moveToTrash
        updateSource = UpdateService.defaultGitHubRepo
        autoCheckForUpdates = true
        startScan()
    }

    // MARK: - Launch at Login & Updates

    public func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLoginEnabled = (SMAppService.mainApp.status == .enabled)
        } catch {
            launchAtLoginEnabled = (SMAppService.mainApp.status == .enabled)
            statusBanner = StatusBannerState(
                title: "Login Item Setting",
                subtitle: error.localizedDescription,
                isSuccess: false,
                undoableSession: nil
            )
        }
    }

    public func checkForUpdates(navigateToSettings: Bool = false) {
        if navigateToSettings {
            sidebarDestination = .settings
        }
        updateStatus = .checking
        let source = updateSource
        Task {
            let result = await updateService.checkForUpdates(source: source)
            self.updateStatus = result
            if case .updateAvailable(let release, _) = result {
                self.statusBanner = StatusBannerState(
                    title: "Husk \(release.version) is available",
                    subtitle: release.releaseNotes.isEmpty ? "Ready to install and relaunch in-place." : release.releaseNotes,
                    isSuccess: true,
                    undoableSession: nil,
                    availableUpdate: release
                )
            }
        }
    }

    public func installUpdateAndRelaunch(_ release: AppReleaseInfo) {
        guard !updateInstallPhase.isInProgress else { return }
        updateInstallPhase = .downloading
        let service = updateService
        let targetBundle = UpdateService.resolveCurrentInstallBundleURL()

        Task { [weak self] in
            guard let self else { return }
            do {
                let staged = try await service.downloadAndStageUpdate(release: release) { [weak self] phase in
                    Task { @MainActor [weak self] in
                        self?.updateInstallPhase = phase
                    }
                }

                self.updateInstallPhase = .restarting
                try service.launchSelfReplaceAndRelaunch(
                    stagedAppURL: staged.stagedAppURL,
                    stagingRootURL: staged.stagingRootURL,
                    targetAppBundleURL: targetBundle
                )

                // Short yield so the UI shows "Installing & relaunching…" before quitting
                try? await Task.sleep(for: .milliseconds(250))
                NSApplication.shared.terminate(nil)
            } catch {
                self.updateInstallPhase = .failed(error.localizedDescription)
                self.statusBanner = StatusBannerState(
                    title: "Update Failed",
                    subtitle: error.localizedDescription,
                    isSuccess: false
                )
            }
        }
    }

    public func openReleasePage(_ release: AppReleaseInfo) {
        NSWorkspace.shared.open(release.releasePageURL ?? release.downloadURL)
    }

    // MARK: - Selection & Execution

    public func toggleSelection(for item: CleanupItem) {
        if selectedIDs.contains(item.id) {
            selectedIDs.remove(item.id)
        } else {
            selectedIDs.insert(item.id)
        }
    }

    public func applySafeSweepSelection(andPreview: Bool = false) {
        let eligible = safeSweepItems
        selectedIDs = Set(eligible.map(\.id))
        if andPreview && !eligible.isEmpty {
            openDryRunPreview()
        } else if eligible.isEmpty {
            statusBanner = StatusBannerState(
                title: "No Stale Safe-Sweep Artifacts Found",
                subtitle: "All Tier 1 project artifacts were modified within the last \(safeSweepMinimumStaleDays) days or are protected.",
                isSuccess: true,
                undoableSession: nil
            )
        }
    }

    public func selectVisibleSafeItems() {
        let safeInView = filteredItems.filter {
            !$0.protection.isShielded && $0.effectiveSafetyTier != .protectedManual
        }
        for item in safeInView {
            selectedIDs.insert(item.id)
        }
    }

    public func selectAllItems(matching filter: (CleanupItem) -> Bool) {
        let matching = items.filter(filter)
        selectedIDs = Set(matching.map(\.id))
    }

    public func clearSelection() {
        selectedIDs.removeAll()
    }

    public func openDryRunPreview() {
        let targets = selectedItems
        guard !targets.isEmpty else { return }
        let executor = makeExecutor()
        activeDryRunManifest = executor.buildDryRunManifest(items: targets, mode: deletionMode)
        isShowingDryRunPreview = true
    }

    public func executeConfirmedCleanup(dryRunOnly: Bool = false) {
        let targets = selectedItems
        guard !targets.isEmpty else {
            isShowingDryRunPreview = false
            return
        }

        let executor = makeExecutor()
        do {
            let session = try executor.execute(
                items: targets,
                mode: deletionMode,
                dryRun: dryRunOnly,
                allowedWorkspaceRoots: workspaceRoots
            )
            auditSessions = auditStore.loadSessions()
            isShowingDryRunPreview = false
            refreshDiskSpace()

            if dryRunOnly {
                statusBanner = StatusBannerState(
                    title: "Dry-Run Logged",
                    subtitle: "Simulated \(targets.count) items (\(session.formattedTotalReclaimed)) with zero files modified.",
                    isSuccess: true,
                    undoableSession: nil
                )
            } else {
                let failedCount = session.items.filter { $0.errorDescription != nil }.count
                let cleanedPaths = Set(
                    session.items
                        .filter { $0.errorDescription == nil }
                        .map(\.originalPath)
                )
                allScannedItems.removeAll { cleanedPaths.contains($0.path.path) }
                selectedIDs.removeAll()

                let actionVerb = deletionMode == .moveToTrash ? "Moved to Trash" : "Deleted"
                let sub = failedCount == 0
                    ? "\(actionVerb) \(cleanedPaths.count) items · \(diskSpace.formattedFree) now free."
                    : "\(actionVerb) \(cleanedPaths.count) items (\(failedCount) skipped)."

                statusBanner = StatusBannerState(
                    title: "Reclaimed \(session.formattedTotalReclaimed)",
                    subtitle: sub,
                    isSuccess: true,
                    undoableSession: session
                )
            }
        } catch {
            isShowingDryRunPreview = false
            statusBanner = StatusBannerState(
                title: "Cleanup Error",
                subtitle: error.localizedDescription,
                isSuccess: false,
                undoableSession: nil
            )
        }
    }

    public func undoCleanupSession(_ session: CleanupSessionRecord) {
        let executor = makeExecutor()
        do {
            let updated = try executor.undoSession(session)
            auditSessions = auditStore.loadSessions()
            let restoredCount = updated.items.filter(\.isRestored).count
            statusBanner = StatusBannerState(
                title: "Restored \(restoredCount) Item(s)",
                subtitle: "Original files returned from Trash.",
                isSuccess: true,
                undoableSession: nil
            )
            startScan()
        } catch {
            statusBanner = StatusBannerState(
                title: "Restore Failed",
                subtitle: error.localizedDescription,
                isSuccess: false,
                undoableSession: nil
            )
        }
    }

    // MARK: - Rebuild Commands & Clipboard

    public func copyRebuildCommand(for item: CleanupItem) {
        let cmd = item.rebuildCommand ?? item.actionKind.displayCommandString ?? "cd \"\(item.path.path)\""
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(cmd, forType: .string)
        statusBanner = StatusBannerState(
            title: "Copied Command",
            subtitle: cmd,
            isSuccess: true,
            undoableSession: nil
        )
    }

    public func copyRebuildScript(for session: CleanupSessionRecord) {
        guard let script = session.rebuildShellScript else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(script, forType: .string)
        statusBanner = StatusBannerState(
            title: "Copied Rebuild Script",
            subtitle: "Paste in Terminal to re-bootstrap dependencies for cleaned projects.",
            isSuccess: true,
            undoableSession: nil
        )
    }

    // MARK: - Workspace Management & OS Integration

    public func promptToAddWorkspaceRoot() {
        let panel = NSOpenPanel()
        panel.title = "Add Developer Workspace Folder"
        panel.message = "Choose a folder containing your projects (e.g. ~/Projects, ~/Code)."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add Folder"

        if panel.runModal() == .OK {
            for url in panel.urls {
                addWorkspaceRoot(url)
            }
            startScan()
        }
    }

    public func addWorkspaceRoot(_ url: URL) {
        let standardized = url.standardizedFileURL
        guard !workspaceRoots.contains(standardized) else { return }
        workspaceRoots.append(standardized)
        persistWorkspaceRoots()
    }

    public func removeWorkspaceRoot(_ url: URL) {
        let standardized = url.standardizedFileURL
        workspaceRoots.removeAll { $0.standardizedFileURL == standardized }
        persistWorkspaceRoots()
        startScan()
    }

    public func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    public func openInTerminal(_ url: URL) {
        let dirURL = url.hasDirectoryPath ? url : url.deletingLastPathComponent()
        if let terminalURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") {
            let config = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.open([dirURL], withApplicationAt: terminalURL, configuration: config)
        }
    }

    public func copyDryRunMarkdownToClipboard() {
        guard let manifest = activeDryRunManifest else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(manifest.toMarkdown(), forType: .string)
    }

    private func makeExecutor() -> CleanupExecutor {
        let inspector = SafetyInspector(activeShieldWindowDays: activeShieldWindowDays)
        return CleanupExecutor(safetyInspector: inspector, auditStore: auditStore)
    }

    private func persistWorkspaceRoots() {
        let paths = workspaceRoots.map(\.path)
        UserDefaults.standard.set(paths, forKey: Keys.savedRoots)
    }

    private static func loadPersistedWorkspaceRoots() -> [URL] {
        if let saved = UserDefaults.standard.stringArray(forKey: Keys.savedRoots), !saved.isEmpty {
            let urls = saved.map { URL(fileURLWithPath: $0).standardizedFileURL }
            let existing = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
            if !existing.isEmpty {
                return existing
            }
        }
        return CleanupRuleRegistry.defaultWorkspaceRoots()
    }
}
