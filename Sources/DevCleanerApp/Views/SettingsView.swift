import SwiftUI
import DevCleanerCore

public struct SettingsView: View {
    @Bindable var viewModel: AppViewModel

    public init(viewModel: AppViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header (aligned at 44pt top offset to match sidebar and other detail views)
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Settings")
                        .font(.system(size: 20, weight: .semibold))
                    Text("Configure safety thresholds, scan scope, exclusions, menu bar alerts, and updates")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }

                Spacer()

                Button("Restore Defaults") {
                    viewModel.resetDefaults()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            Divider().opacity(0.45)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    updatesSection
                    safetySection
                    scanningSection
                    exclusionsSection
                    alertsAndSystemSection
                }
                .padding(.bottom, 28)
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 44)
    }

    // MARK: - 1. Updates & Release Feed

    private var updatesSection: some View {
        settingsCard(title: "Updates & Release Channel", icon: "arrow.triangle.2.circlepath") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 8) {
                            Text("Husk \(UpdateService.currentAppVersion)")
                                .font(.system(size: 13.5, weight: .semibold))
                            SubtleTag(text: "Build \(UpdateService.currentBuildNumber)")
                        }
                        Text(updateStatusCaption)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    HStack(spacing: 8) {
                        if case .updateAvailable(let release, _) = viewModel.updateStatus {
                            if viewModel.updateInstallPhase.isInProgress {
                                HStack(spacing: 6) {
                                    ProgressView()
                                        .controlSize(.small)
                                    Text(viewModel.updateInstallPhase.label)
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 8)
                            } else {
                                Button {
                                    viewModel.openReleasePage(release)
                                } label: {
                                    Text("Release Notes")
                                        .font(.system(size: 12))
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)

                                if release.canInstallInApp {
                                    Button {
                                        viewModel.installUpdateAndRelaunch(release)
                                    } label: {
                                        Label("Update & Relaunch (\(release.version))", systemImage: "arrow.down.circle.fill")
                                            .font(.system(size: 12, weight: .medium))
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .controlSize(.small)
                                    .disabled(viewModel.isCleaning)
                                }
                            }
                        }

                        Button {
                            viewModel.checkForUpdates()
                        } label: {
                            HStack(spacing: 5) {
                                if viewModel.updateStatus == .checking {
                                    ProgressView()
                                        .controlSize(.small)
                                } else {
                                    Image(systemName: "arrow.clockwise")
                                        .font(.system(size: 11))
                                }
                                Text(viewModel.updateStatus == .checking ? "Checking…" : "Check for Updates")
                                    .font(.system(size: 12, weight: .medium))
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(viewModel.updateStatus == .checking || viewModel.updateInstallPhase.isInProgress)
                    }
                }

                if case .updateAvailable(let release, _) = viewModel.updateStatus,
                   !release.releaseNotes.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Release Notes — \(release.version)")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Text(release.releaseNotes)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(6)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 7))
                }

                Divider().opacity(0.35)

                settingsRow(
                    title: "Automatically check for updates on launch",
                    subtitle: "Queries GitHub Releases or your website manifest in the background"
                ) {
                    Toggle("", isOn: $viewModel.autoCheckForUpdates)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }

                Divider().opacity(0.35)

                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Update Feed (GitHub Repo or Website JSON URL)")
                            .font(.system(size: 12.5, weight: .medium))
                        Text("Use GitHub Releases or an HTTPS manifest. In-app installs require a signed Husk ZIP.")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }

                    Spacer()

                    TextField("Piskaty/husk or https://...", text: $viewModel.updateSource)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, design: .monospaced))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .frame(width: 260)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.primary.opacity(0.05))
                        )
                }
            }
        }
    }

    private var updateStatusCaption: String {
        switch viewModel.updateStatus {
        case .idle:
            return "Ready to check GitHub Releases or website feed"
        case .checking:
            return "Checking release endpoint…"
        case .upToDate(let version, let checkedAt):
            return "Up to date (v\(version)) · Checked \(checkedAt.formatted(date: .omitted, time: .shortened))"
        case .updateAvailable(let release, _):
            return "Update available: \(release.version)"
        case .failed(let message):
            return message
        }
    }

    // MARK: - 2. Safety & Protection Thresholds

    private var safetySection: some View {
        settingsCard(title: "Safety & Protection", icon: "shield") {
            VStack(alignment: .leading, spacing: 12) {
                settingsRow(
                    title: "Active-Project Shield Window",
                    subtitle: "Repositories with commits or edits inside this window are marked Active and protected"
                ) {
                    Picker("", selection: $viewModel.activeShieldWindowDays) {
                        Text("3 days").tag(3)
                        Text("7 days (Recommended)").tag(7)
                        Text("14 days").tag(14)
                        Text("30 days").tag(30)
                    }
                    .labelsHidden()
                    .frame(width: 175)
                    .onChange(of: viewModel.activeShieldWindowDays) { _, _ in
                        viewModel.startScan()
                    }
                }

                Divider().opacity(0.35)

                settingsRow(
                    title: "Safe Sweep Inactivity Threshold",
                    subtitle: "Minimum age before Tier 1 rebuildable artifacts are included in 1-Click Safe Sweep"
                ) {
                    Picker("", selection: $viewModel.safeSweepMinimumStaleDays) {
                        Text("14 days").tag(14)
                        Text("30 days (Recommended)").tag(30)
                        Text("60 days").tag(60)
                        Text("90 days").tag(90)
                    }
                    .labelsHidden()
                    .frame(width: 175)
                }

                Divider().opacity(0.35)

                settingsRow(
                    title: "Default Cleanup Action",
                    subtitle: "Trash-first relocation allows 1-click Undo from History or Finder"
                ) {
                    Picker("", selection: $viewModel.deletionMode) {
                        ForEach(DeletionMode.allCases) { mode in
                            Text(mode.shortTitle).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 175)
                }
            }
        }
    }

    // MARK: - 3. Scanning & Scope

    private var scanningSection: some View {
        settingsCard(title: "Scanning & Scope", icon: "magnifyingglass") {
            VStack(alignment: .leading, spacing: 12) {
                settingsRow(
                    title: "Scan Global Package & Developer Caches",
                    subtitle: "Include bun, pnpm, npm, cargo, uv, pip, Homebrew, Xcode DerivedData, and AI caches"
                ) {
                    Toggle("", isOn: $viewModel.includeGlobalCaches)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .onChange(of: viewModel.includeGlobalCaches) { _, _ in
                            viewModel.startScan()
                        }
                }

                Divider().opacity(0.35)

                settingsRow(
                    title: "Workspace Directory Traversal Depth",
                    subtitle: "How many subfolder levels deep Husk searches inside each workspace root"
                ) {
                    Picker("", selection: $viewModel.maxWorkspaceDepth) {
                        Text("4 levels").tag(4)
                        Text("6 levels (Default)").tag(6)
                        Text("8 levels").tag(8)
                        Text("10 levels").tag(10)
                    }
                    .labelsHidden()
                    .frame(width: 175)
                    .onChange(of: viewModel.maxWorkspaceDepth) { _, _ in
                        viewModel.startScan()
                    }
                }

                Divider().opacity(0.35)

                settingsRow(
                    title: "Git Packfile (git gc) Suggestion Threshold",
                    subtitle: "Suggest non-destructive 'git gc --prune=now' when .git/objects exceeds this size"
                ) {
                    Picker("", selection: $viewModel.gitGCMinimumMB) {
                        Text("30 MB").tag(30)
                        Text("60 MB (Default)").tag(60)
                        Text("150 MB").tag(150)
                        Text("500 MB").tag(500)
                    }
                    .labelsHidden()
                    .frame(width: 175)
                    .onChange(of: viewModel.gitGCMinimumMB) { _, _ in
                        viewModel.startScan()
                    }
                }
            }
        }
    }

    // MARK: - 4. Excluded / Pinned Projects

    private var exclusionsSection: some View {
        settingsCard(title: "Excluded Folders & Pinned Projects", icon: "pin") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Husk completely hides and never cleans items inside excluded folders.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Add Excluded Folder…") {
                        viewModel.promptToAddIgnoredPath()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                if viewModel.ignoredPaths.isEmpty {
                    Text("No excluded paths configured. You can also right-click any item row to exclude it.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.tertiary)
                        .padding(.vertical, 4)
                } else {
                    VStack(spacing: 4) {
                        ForEach(viewModel.ignoredPaths, id: \.self) { path in
                            HStack(spacing: 8) {
                                Image(systemName: "folder.badge.minus")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                Text(path)
                                    .font(.system(size: 11.5, design: .monospaced))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                                Button("Remove") {
                                    viewModel.removeIgnoredPath(path)
                                }
                                .buttonStyle(.plain)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }
            }
        }
    }

    // MARK: - 5. Menu Bar & Disk Space Alerts

    private var alertsAndSystemSection: some View {
        settingsCard(title: "Menu Bar & Disk Space Alerts", icon: "menubar.rectangle") {
            VStack(alignment: .leading, spacing: 12) {
                settingsRow(
                    title: "Launch Husk at Login",
                    subtitle: "Keep the Husk menu bar monitor available when signing in to macOS"
                ) {
                    Toggle(
                        "",
                        isOn: Binding(
                            get: { viewModel.launchAtLoginEnabled },
                            set: { viewModel.setLaunchAtLogin($0) }
                        )
                    )
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                }

                Divider().opacity(0.35)

                settingsRow(
                    title: "Dev Husks Menu Bar Alert Threshold",
                    subtitle: "Show an attention dot in the menu bar when total reclaimable space exceeds this amount"
                ) {
                    Picker("", selection: $viewModel.menuBarAlertThresholdGB) {
                        Text("10 GB").tag(10.0)
                        Text("15 GB (Default)").tag(15.0)
                        Text("25 GB").tag(25.0)
                        Text("50 GB").tag(50.0)
                    }
                    .labelsHidden()
                    .frame(width: 175)
                }

                Divider().opacity(0.35)

                settingsRow(
                    title: "Low Mac Free Disk Space Warning",
                    subtitle: "Warn in the menu bar and footer when remaining APFS free space falls below this threshold"
                ) {
                    Picker("", selection: $viewModel.lowDiskWarningThresholdGB) {
                        Text("20 GB").tag(20.0)
                        Text("35 GB (Default)").tag(35.0)
                        Text("50 GB").tag(50.0)
                        Text("100 GB").tag(100.0)
                    }
                    .labelsHidden()
                    .frame(width: 175)
                }
            }
        }
    }

    // MARK: - Reusable Minimalist Liquid Glass Card

    @ViewBuilder
    private func settingsCard<Content: View>(
        title: String,
        icon: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
            }

            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.035))
        )
    }

    @ViewBuilder
    private func settingsRow<Control: View>(
        title: String,
        subtitle: String,
        @ViewBuilder control: () -> Control
    ) -> some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            control()
        }
    }
}
