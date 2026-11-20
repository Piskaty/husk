import SwiftUI
import DevCleanerCore

public struct MainWorkspaceView: View {
    @Bindable var viewModel: AppViewModel

    public init(viewModel: AppViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        ZStack {
            LiquidGlassWindowBackdrop()
                .ignoresSafeArea()

            HStack(spacing: 0) {
                sidebarColumn
                    .frame(width: 248)

                // Full-height 1px vertical hairline
                Rectangle()
                    .fill(Color.primary.opacity(0.08))
                    .frame(width: 1)
                    .ignoresSafeArea()

                detailColumn
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .ignoresSafeArea(.container, edges: .top)
            .sheet(isPresented: $viewModel.isShowingDryRunPreview) {
                DryRunPreviewSheet(viewModel: viewModel)
            }

            if viewModel.isShowingCommandPalette {
                CommandPaletteView(viewModel: viewModel)
                    .transition(.opacity)
                    .zIndex(50)
            }
        }
        .onAppear {
            if viewModel.items.isEmpty && !viewModel.isScanning {
                viewModel.startScan()
            }
            if viewModel.autoCheckForUpdates && viewModel.updateStatus == .idle {
                viewModel.checkForUpdates(navigateToSettings: false)
            }
        }
    }

    // MARK: - Perfectly Aligned Custom Liquid Glass Sidebar

    private var sidebarColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Space reserved for macOS traffic lights (matches detail top offset of 44pt)
            Color.clear
                .frame(height: 44)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    // Primary Overview Section
                    VStack(alignment: .leading, spacing: 2) {
                        sidebarItem(
                            destination: .allJunk,
                            trailingText: viewModel.totalFoundBytes > 0 ? viewModel.formattedTotalFoundBytes : nil
                        )

                        sidebarItem(
                            destination: .safeSweep,
                            trailingText: viewModel.safeSweepTotalBytes > 0 ? viewModel.formattedSafeSweepBytes : nil
                        )
                    }

                    // Categories Section
                    VStack(alignment: .leading, spacing: 2) {
                        sidebarSectionHeader("Categories")

                        ForEach(CleanupCategory.allCases) { category in
                            let bytes = viewModel.bytes(for: category)
                            sidebarItem(
                                destination: .category(category),
                                trailingText: bytes > 0 ? ByteFormatting.string(from: bytes) : nil
                            )
                        }
                    }

                    // Smart Views & Filter Section
                    VStack(alignment: .leading, spacing: 2) {
                        sidebarSectionHeader("Smart Views")

                        sidebarItem(
                            destination: .dormantClones,
                            trailingText: viewModel.dormantCloneTotalBytes > 0
                                ? ByteFormatting.string(from: viewModel.dormantCloneTotalBytes)
                                : nil
                        )

                        sidebarItem(
                            destination: .toolCleaners,
                            trailingText: viewModel.toolCommandTotalBytes > 0
                                ? ByteFormatting.string(from: viewModel.toolCommandTotalBytes)
                                : nil
                        )

                        sidebarItem(
                            destination: .shieldedProjects,
                            trailingText: viewModel.shieldedItems.isEmpty ? nil : "\(viewModel.shieldedItems.count)"
                        )

                        sidebarItem(
                            destination: .auditHistory,
                            trailingText: viewModel.auditSessions.isEmpty ? nil : "\(viewModel.auditSessions.count)"
                        )

                        sidebarItem(
                            destination: .settings,
                            trailingText: viewModel.hasAvailableUpdate ? "Update" : nil
                        )
                    }

                    // Workspace Folders Section
                    VStack(alignment: .leading, spacing: 4) {
                        sidebarSectionHeader("Folders")

                        ForEach(viewModel.workspaceRoots, id: \.path) { root in
                            HStack(spacing: 8) {
                                Image(systemName: "folder")
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 16)

                                Text(root.lastPathComponent)
                                    .font(.system(size: 12.5))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .help(root.path)

                                Spacer()

                                if viewModel.workspaceRoots.count > 1 {
                                    Button {
                                        viewModel.removeWorkspaceRoot(root)
                                    } label: {
                                        Image(systemName: "xmark")
                                            .font(.system(size: 9, weight: .medium))
                                            .foregroundStyle(.tertiary)
                                    }
                                    .buttonStyle(.plain)
                                    .help("Remove folder")
                                }
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                        }

                        Button {
                            viewModel.promptToAddWorkspaceRoot()
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "plus")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(.tertiary)
                                    .frame(width: 16)

                                Text("Add Folder…")
                                    .font(.system(size: 12.5))
                                    .foregroundStyle(.secondary)

                                Spacer()
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 16)
            }
        }
        .background(Color.primary.opacity(0.015))
    }

    @ViewBuilder
    private func sidebarSectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 10)
            .padding(.bottom, 3)
    }

    @ViewBuilder
    private func sidebarItem(
        destination: SidebarDestination,
        trailingText: String?
    ) -> some View {
        let isSelected = viewModel.sidebarDestination == destination

        Button {
            withAnimation(.snappy(duration: 0.18)) {
                viewModel.sidebarDestination = destination
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: destination.systemImage)
                    .font(.system(size: 12, weight: isSelected ? .medium : .regular))
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .frame(width: 16)

                Text(destination.title)
                    .font(.system(size: 12.5, weight: isSelected ? .medium : .regular))
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .lineLimit(1)

                Spacer(minLength: 6)

                if let trailingText {
                    Text(trailingText)
                        .font(.system(size: 11))
                        .foregroundStyle(isSelected ? .secondary : .tertiary)
                        .monospacedDigit()
                        .fixedSize()
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.primary.opacity(0.04))
                        .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Detail Column

    private var detailColumn: some View {
        VStack(spacing: 0) {
            if viewModel.sidebarDestination == .auditHistory {
                AuditHistoryView(viewModel: viewModel)
            } else if viewModel.sidebarDestination == .settings {
                SettingsView(viewModel: viewModel)
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    StorageHeroCard(viewModel: viewModel)

                    minimalFilterBar

                    if let banner = viewModel.statusBanner {
                        statusBannerView(banner)
                    }

                    Divider()
                        .opacity(0.45)

                    if viewModel.isScanning && viewModel.items.isEmpty {
                        scanningPlaceholderView
                    } else if viewModel.filteredItems.isEmpty {
                        emptyStateView
                    } else {
                        artifactListView
                    }
                }
                .padding(.horizontal, 28)
                .padding(.top, 44) // Matches sidebar top offset so headers align horizontally

                bottomActionFooter
            }
        }
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.75))
    }

    // MARK: - Minimal Liquid Glass Filter Bar

    private var minimalFilterBar: some View {
        HStack(spacing: 12) {
            // Search input with Liquid Glass surface & embedded ⌘K button
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tertiary)

                TextField("Filter items…", text: $viewModel.searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))

                if !viewModel.searchText.isEmpty {
                    Button {
                        viewModel.searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }

                Button {
                    viewModel.isShowingCommandPalette = true
                } label: {
                    Text("⌘K")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
                .help("Open Command Palette (⌘K)")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
            )

            // Ecosystem dropdown
            Menu {
                Button("All Ecosystems") {
                    viewModel.selectedEcosystem = nil
                }
                Divider()
                ForEach(Ecosystem.allCases) { eco in
                    if viewModel.items.contains(where: { $0.ecosystem == eco }) {
                        Button(eco.title) {
                            viewModel.selectedEcosystem = eco
                        }
                    }
                }
            } label: {
                Text(viewModel.selectedEcosystem?.title ?? "Ecosystem")
                    .font(.system(size: 12))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            // Age dropdown
            Menu {
                Button("Any Age") {
                    viewModel.selectedStalenessBucket = nil
                }
                Divider()
                ForEach(StalenessBucket.allCases) { bucket in
                    Button(bucket.title) {
                        viewModel.selectedStalenessBucket = bucket
                    }
                }
            } label: {
                Text(viewModel.selectedStalenessBucket?.shortTitle ?? "Age")
                    .font(.system(size: 12))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            // Sort dropdown
            Menu {
                ForEach(ArtifactSortOrder.allCases) { order in
                    Button(order.rawValue) {
                        viewModel.sortOrder = order
                    }
                }
            } label: {
                Text(viewModel.sortOrder.rawValue)
                    .font(.system(size: 12))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Spacer()

            if !viewModel.selectedIDs.isEmpty {
                Button("Clear") {
                    viewModel.clearSelection()
                }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            } else if !viewModel.filteredItems.isEmpty {
                Button("Select Safe") {
                    viewModel.selectVisibleSafeItems()
                }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Liquid Glass Status / Undo & Rebuild Script Banner

    @ViewBuilder
    private func statusBannerView(_ banner: StatusBannerState) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(banner.isSuccess ? DevCleanerTheme.safeGreen : Color.red)
                .frame(width: 6, height: 6)

            Text(banner.title)
                .font(.system(size: 12, weight: .medium))

            Text(banner.subtitle)
                .font(.system(size: 12, design: banner.title == "Copied Command" ? .monospaced : .default))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer()

            if let undoSession = banner.undoableSession {
                if undoSession.rebuildShellScript != nil {
                    Button("Copy Rebuild Script") {
                        viewModel.copyRebuildScript(for: undoSession)
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                }

                if undoSession.restorableItemCount > 0 {
                    Button("Undo") {
                        viewModel.undoCleanupSession(undoSession)
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                }
            }

            Button {
                viewModel.statusBanner = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    // MARK: - Clean Artifact List

    private var artifactListView: some View {
        let filtered = viewModel.filteredItems
        let maxBytes = viewModel.maxItemBytes

        return ScrollView {
            LazyVStack(spacing: 1) {
                ForEach(filtered) { item in
                    ArtifactRowCard(
                        item: item,
                        isSelected: viewModel.selectedIDs.contains(item.id),
                        maxSizeBytes: maxBytes,
                        onToggle: {
                            viewModel.toggleSelection(for: item)
                        },
                        onRevealInFinder: {
                            viewModel.revealInFinder(item.path)
                        },
                        onOpenInTerminal: {
                            viewModel.openInTerminal(item.projectRootPath ?? item.path)
                        },
                        onCopyRebuildCommand: {
                            viewModel.copyRebuildCommand(for: item)
                        }
                    )
                    .contextMenu {
                        Button(viewModel.selectedIDs.contains(item.id) ? "Deselect" : "Select") {
                            viewModel.toggleSelection(for: item)
                        }
                        if item.rebuildCommand != nil || item.actionKind.displayCommandString != nil {
                            Button("Copy Rebuild Command") {
                                viewModel.copyRebuildCommand(for: item)
                            }
                        }
                        Button("Reveal in Finder") {
                            viewModel.revealInFinder(item.path)
                        }
                        if item.projectRootPath != nil {
                            Button("Open in Terminal") {
                                viewModel.openInTerminal(item.projectRootPath ?? item.path)
                            }
                        }
                        Divider()
                        Button("Exclude Project from Husk") {
                            viewModel.ignoreItem(item)
                        }
                    }
                }
            }
            .padding(.bottom, 12)
        }
        .padding(.horizontal, -10)
    }

    private var scanningPlaceholderView: some View {
        VStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text("Scanning…")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            Text(viewModel.scanProgressText)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyStateView: some View {
        VStack(spacing: 8) {
            Text("No items")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)

            Text(viewModel.sidebarDestination.subtitle)
                .font(.system(size: 11.5))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)

            if viewModel.selectedEcosystem != nil || viewModel.selectedStalenessBucket != nil || !viewModel.searchText.isEmpty {
                Button("Reset Filters") {
                    viewModel.selectedEcosystem = nil
                    viewModel.selectedStalenessBucket = nil
                    viewModel.searchText = ""
                }
                .buttonStyle(.glass)
                .controlSize(.small)
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Liquid Glass Bottom Footer with Free Space Projection

    private var bottomActionFooter: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                if viewModel.isLowDiskSpace {
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 6, height: 6)
                        .help("Low free disk space (< \(Int(viewModel.lowDiskWarningThresholdGB)) GB)")
                }

                Text(footerDiskSummaryText)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
                    .lineLimit(1)
            }

            Spacer()

            if !viewModel.selectedItems.isEmpty {
                Text("\(viewModel.selectedItems.count) selected · \(viewModel.formattedSelectedBytes)")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Button {
                viewModel.openDryRunPreview()
            } label: {
                Text(
                    viewModel.selectedItems.isEmpty
                        ? "Move to Trash…"
                        : "Move to Trash (\(viewModel.formattedSelectedBytes))…"
                )
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
            }
            .buttonStyle(.glassProminent)
            .disabled(viewModel.selectedItems.isEmpty)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 10)
        .overlay(alignment: .top) {
            Divider().opacity(0.35)
        }
    }

    private var footerDiskSummaryText: String {
        guard viewModel.diskSpace.freeBytes > 0 else {
            return viewModel.scanProgressText
        }
        if viewModel.selectedTotalBytes > 0 {
            let projected = ByteFormatting.string(from: viewModel.projectedFreeAfterSelectedBytes)
            return "Mac Disk: \(viewModel.diskSpace.formattedFree) free → \(projected) after clean"
        }
        return "\(viewModel.items.count) items · \(viewModel.diskSpace.formattedFree) free on Mac"
    }
}
