import SwiftUI
import DevCleanerCore

public struct DryRunPreviewSheet: View {
    @Bindable var viewModel: AppViewModel
    @ViewState private var copiedMarkdown: Bool = false
    @ViewState private var confirmedToolTasks = false

    public init(viewModel: AppViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        let manifest = viewModel.activeDryRunManifest
            ?? DryRunManifest(items: viewModel.selectedItems, mode: viewModel.deletionMode)
        let hasToolTasks = manifest.items.contains { $0.actionKind.isToolCommand }
        let hasFilesystemItems = manifest.items.contains { !$0.actionKind.isToolCommand }

        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Confirm Cleanup")
                        .font(.system(size: 16, weight: .semibold))
                    Text("\(manifest.items.count) items · \(manifest.totalFiles.formatted()) files")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text(ByteFormatting.string(from: manifest.totalBytes))
                        .font(.system(size: 20, weight: .light))
                        .foregroundStyle(.primary)
                        .monospacedDigit()
                }
            }

            if !manifest.warnings.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(manifest.warnings, id: \.self) { warning in
                        Text(warning)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.primary.opacity(0.04))
                )
            }

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(manifest.items) { item in
                        HStack(spacing: 10) {
                            Text(item.projectName)
                                .font(.system(size: 12.5, weight: .medium))
                                .lineLimit(1)

                            if item.title != item.projectName {
                                Text(item.title)
                                    .font(.system(size: 11.5, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }

                            if item.actionKind.isToolCommand {
                                SubtleTag(text: "CLI", systemImage: "terminal")
                            }

                            Spacer()

                            Text(item.displayPath)
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: 230, alignment: .trailing)

                            Text(item.formattedSize)
                                .font(.system(size: 12, weight: .medium))
                                .monospacedDigit()
                                .frame(width: 72, alignment: .trailing)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)

                        Divider().opacity(0.4)
                    }
                }
            }
            .frame(minHeight: 200, maxHeight: 290)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(0.03))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
            )

            if hasToolTasks {
                Toggle("I confirm that tool tasks can make permanent changes.", isOn: $confirmedToolTasks)
                    .toggleStyle(.checkbox)
            }

            HStack(spacing: 10) {
                Menu {
                    if hasFilesystemItems {
                        ForEach(DeletionMode.allCases) { mode in
                            Button(mode.title) {
                                viewModel.deletionMode = mode
                                viewModel.activeDryRunManifest = DryRunManifest(items: manifest.items, mode: mode)
                            }
                        }
                        Divider()
                    }
                    Button(copiedMarkdown ? "Copied Manifest" : "Copy Markdown Manifest") {
                        viewModel.copyDryRunMarkdownToClipboard()
                        copiedMarkdown = true
                    }
                    Button("Simulate Dry-Run Only") {
                        viewModel.executeConfirmedCleanup(dryRunOnly: true)
                    }
                } label: {
                    Text(hasFilesystemItems ? manifest.mode.shortTitle : "Options")
                        .font(.system(size: 12))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                Spacer()

                Button("Cancel") {
                    viewModel.isShowingDryRunPreview = false
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(.cancelAction)

                Button {
                    viewModel.executeConfirmedCleanup(allowIrreversibleToolTasks: confirmedToolTasks)
                } label: {
                    Text(confirmationTitle(mode: manifest.mode, hasToolTasks: hasToolTasks,
                                           hasFilesystemItems: hasFilesystemItems))
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 8)
                }
                .buttonStyle(.borderedProminent)
                .tint(hasToolTasks || manifest.mode == .permanentDelete ? .red : nil)
                .keyboardShortcut(.defaultAction)
                .disabled(hasToolTasks && !confirmedToolTasks)
            }
        }
        .padding(20)
        .frame(width: 610)
    }

    private func confirmationTitle(mode: DeletionMode, hasToolTasks: Bool, hasFilesystemItems: Bool) -> String {
        if hasToolTasks && !hasFilesystemItems { return "Run Tool Tasks" }
        let action = mode == .moveToTrash ? "Move to Trash" : "Delete Permanently"
        return hasToolTasks ? "\(action) & Run Tools" : action
    }
}
