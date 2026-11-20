import SwiftUI
import DevCleanerCore

public struct PaletteAction: Identifiable {
    public let id: String
    public let title: String
    public let subtitle: String
    public let systemImage: String
    public let badgeText: String?
    public let perform: () -> Void
}

public struct CommandPaletteView: View {
    @Bindable var viewModel: AppViewModel
    @ViewState private var query: String = ""
    @ViewState private var highlightedIndex: Int = 0
    @FocusState private var isSearchFocused: Bool

    public init(viewModel: AppViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        let actions = filteredActions
        let clampedIndex = min(max(0, highlightedIndex), max(0, actions.count - 1))

        ZStack {
            Color.black.opacity(0.20)
                .ignoresSafeArea()
                .onTapGesture {
                    viewModel.isShowingCommandPalette = false
                }

            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)

                    TextField("Type a command or search…", text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14))
                        .focused($isSearchFocused)
                        .onSubmit {
                            if actions.indices.contains(clampedIndex) {
                                execute(actions[clampedIndex])
                            }
                        }

                    Text("esc")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)

                Divider().opacity(0.45)

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(actions.enumerated()), id: \.element.id) { index, action in
                                let isHighlighted = index == clampedIndex
                                Button {
                                    execute(action)
                                } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: action.systemImage)
                                            .font(.system(size: 12))
                                            .foregroundStyle(.secondary)
                                            .frame(width: 18)

                                        Text(action.title)
                                            .font(.system(size: 12.5, weight: .medium))
                                            .foregroundStyle(.primary)
                                            .lineLimit(1)

                                        Spacer()

                                        if let badge = action.badgeText {
                                            Text(badge)
                                                .font(.system(size: 11.5))
                                                .foregroundStyle(.tertiary)
                                                .monospacedDigit()
                                        }
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 7)
                                    .background(
                                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                                            .fill(isHighlighted ? Color.primary.opacity(0.09) : Color.clear)
                                    )
                                }
                                .buttonStyle(.plain)
                                .id(index)
                            }
                        }
                        .padding(6)
                    }
                    .frame(maxHeight: 320)
                    .onChange(of: clampedIndex) { _, newValue in
                        proxy.scrollTo(newValue, anchor: .center)
                    }
                }
            }
            .frame(width: 520)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(nsColor: .windowBackgroundColor))
                    .shadow(color: Color.black.opacity(0.24), radius: 22, y: 10)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
            )
        }
        .onAppear {
            highlightedIndex = 0
            isSearchFocused = true
        }
        .onChange(of: query) { _, _ in
            highlightedIndex = 0
        }
        .onKeyPress(.upArrow) {
            if highlightedIndex > 0 { highlightedIndex -= 1 }
            return .handled
        }
        .onKeyPress(.downArrow) {
            if highlightedIndex < max(0, actions.count - 1) { highlightedIndex += 1 }
            return .handled
        }
        .onKeyPress(.escape) {
            viewModel.isShowingCommandPalette = false
            return .handled
        }
    }

    private func execute(_ action: PaletteAction) {
        viewModel.isShowingCommandPalette = false
        action.perform()
    }

    private var filteredActions: [PaletteAction] {
        var list: [PaletteAction] = [
            PaletteAction(
                id: "cmd.safe_sweep",
                title: "Safe Sweep (30d+ Inactive Projects)",
                subtitle: "Select rebuildable artifacts in inactive repos",
                systemImage: "sparkles",
                badgeText: viewModel.formattedSafeSweepBytes,
                perform: { viewModel.applySafeSweepSelection(andPreview: true) }
            ),
            PaletteAction(
                id: "cmd.select_merged_worktrees",
                title: "Select Merged & Clean Git Worktrees",
                subtitle: "Linked worktrees already merged into main with zero uncommitted changes",
                systemImage: "arrow.triangle.branch",
                badgeText: ByteFormatting.string(
                    from: viewModel.safeMergedWorktreeItems.reduce(0) { $0 + $1.allocatedSizeBytes }
                ),
                perform: {
                    viewModel.sidebarDestination = .worktrees
                    let ids = Set(viewModel.safeMergedWorktreeItems.map(\.id))
                    viewModel.selectedIDs = ids
                }
            ),
            PaletteAction(
                id: "cmd.select_dormant_clones",
                title: "Select Dormant & Read-Only Clones",
                subtitle: "Untouched repos (120d+) and read-only clones (0 local commits)",
                systemImage: "moon.zzz",
                badgeText: ByteFormatting.string(from: viewModel.dormantCloneTotalBytes),
                perform: {
                    viewModel.sidebarDestination = .dormantClones
                    viewModel.selectAllItems { $0.protection.isDormantOrOrphaned && $0.category == .projectArtifacts }
                }
            ),
            PaletteAction(
                id: "cmd.select_tool_tasks",
                title: "View Native Tool Subcommand Tasks",
                subtitle: "git gc packfiles, simctl unavailable devices, brew cleanup",
                systemImage: "terminal",
                badgeText: ByteFormatting.string(from: viewModel.toolCommandTotalBytes),
                perform: {
                    viewModel.sidebarDestination = .toolCleaners
                }
            ),
            PaletteAction(
                id: "cmd.select_stale_node_modules",
                title: "Select Unshielded node_modules",
                subtitle: "All non-active node_modules folders",
                systemImage: "folder",
                badgeText: ByteFormatting.string(
                    from: viewModel.items
                        .filter { $0.ruleId == "node.node_modules" && !$0.protection.isShielded }
                        .reduce(0) { $0 + $1.allocatedSizeBytes }
                ),
                perform: {
                    viewModel.sidebarDestination = .category(.projectArtifacts)
                    viewModel.selectAllItems { $0.ruleId == "node.node_modules" && !$0.protection.isShielded }
                }
            ),
            PaletteAction(
                id: "cmd.select_rust_targets",
                title: "Select Unshielded Rust target/",
                subtitle: "All non-active Cargo target folders",
                systemImage: "folder",
                badgeText: ByteFormatting.string(
                    from: viewModel.items
                        .filter { $0.ruleId == "rust.target" && !$0.protection.isShielded }
                        .reduce(0) { $0 + $1.allocatedSizeBytes }
                ),
                perform: {
                    viewModel.sidebarDestination = .category(.projectArtifacts)
                    viewModel.selectAllItems { $0.ruleId == "rust.target" && !$0.protection.isShielded }
                }
            ),
            PaletteAction(
                id: "cmd.select_package_caches",
                title: "Select Global Package Caches",
                subtitle: "bun, pnpm, npm, cargo, uv, pip, Homebrew",
                systemImage: "shippingbox",
                badgeText: ByteFormatting.string(from: viewModel.bytes(for: .packageCaches)),
                perform: {
                    viewModel.sidebarDestination = .category(.packageCaches)
                    viewModel.selectAllItems { $0.category == .packageCaches }
                }
            ),
            PaletteAction(
                id: "cmd.preview_dry_run",
                title: "Review & Move Selected to Trash…",
                subtitle: "Open confirmation sheet",
                systemImage: "trash",
                badgeText: viewModel.selectedItems.isEmpty ? nil : viewModel.formattedSelectedBytes,
                perform: { viewModel.openDryRunPreview() }
            ),
            PaletteAction(
                id: "cmd.open_audit_log",
                title: "View History & Restore from Trash",
                subtitle: "Open cleanup history and rebuild scripts",
                systemImage: "clock.arrow.circlepath",
                badgeText: nil,
                perform: { viewModel.sidebarDestination = .auditHistory }
            ),
            PaletteAction(
                id: "cmd.clear_selection",
                title: "Clear Selection",
                subtitle: "Deselect all items",
                systemImage: "xmark",
                badgeText: nil,
                perform: { viewModel.clearSelection() }
            ),
            PaletteAction(
                id: "cmd.rescan",
                title: "Rescan",
                subtitle: "Refresh disk scan",
                systemImage: "arrow.clockwise",
                badgeText: nil,
                perform: { viewModel.startScan() }
            ),
            PaletteAction(
                id: "cmd.open_settings",
                title: "Open Settings…",
                subtitle: "Safety thresholds, exclusions, menu bar alerts, and updates",
                systemImage: "gearshape",
                badgeText: "⌘,",
                perform: { viewModel.sidebarDestination = .settings }
            ),
            PaletteAction(
                id: "cmd.check_updates",
                title: "Check for Updates…",
                subtitle: "Check GitHub Releases or website feed for a newer version of Husk",
                systemImage: "arrow.triangle.2.circlepath",
                badgeText: "v\(UpdateService.currentAppVersion)",
                perform: { viewModel.checkForUpdates(navigateToSettings: true) }
            )
        ]

        if let undoable = viewModel.auditSessions.first(where: { $0.restorableItemCount > 0 }) {
            list.insert(
                PaletteAction(
                    id: "cmd.undo_last",
                    title: "Undo Last Cleanup",
                    subtitle: "Restore \(undoable.restorableItemCount) items from Trash",
                    systemImage: "arrow.uturn.backward",
                    badgeText: undoable.formattedTotalReclaimed,
                    perform: { viewModel.undoCleanupSession(undoable) }
                ),
                at: 1
            )
        }

        for item in viewModel.items.prefix(50) {
            let isSelected = viewModel.selectedIDs.contains(item.id)
            list.append(
                PaletteAction(
                    id: "item.\(item.id)",
                    title: "\(isSelected ? "✓ " : "")\(item.projectName) / \(item.title)",
                    subtitle: item.displayPath,
                    systemImage: "folder",
                    badgeText: item.formattedSize,
                    perform: { viewModel.toggleSelection(for: item) }
                )
            )
        }

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else {
            return Array(list.prefix(12))
        }
        return list.filter {
            $0.title.lowercased().contains(trimmed) || $0.subtitle.lowercased().contains(trimmed)
        }
    }
}
