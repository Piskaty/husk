import SwiftUI
import DevCleanerCore

public struct DryRunPreviewSheet: View {
    @Bindable var viewModel: AppViewModel
    @ViewState private var copiedMarkdown: Bool = false

    public init(viewModel: AppViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        let manifest = viewModel.activeDryRunManifest
            ?? DryRunManifest(items: viewModel.selectedItems, mode: viewModel.deletionMode)

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
                    if viewModel.diskSpace.freeBytes > 0 {
                        Text("→ \(ByteFormatting.string(from: viewModel.diskSpace.freeBytes + manifest.totalBytes)) free")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                    }
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
                .glassEffect(.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
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
            .glassEffect(.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            HStack(spacing: 10) {
                Menu {
                    ForEach(DeletionMode.allCases) { mode in
                        Button(mode.title) {
                            viewModel.deletionMode = mode
                            viewModel.activeDryRunManifest = DryRunManifest(
                                items: viewModel.selectedItems,
                                mode: mode
                            )
                        }
                    }
                    Divider()
                    Button(copiedMarkdown ? "Copied Manifest" : "Copy Markdown Manifest") {
                        viewModel.copyDryRunMarkdownToClipboard()
                        copiedMarkdown = true
                    }
                    Button("Simulate Dry-Run Only") {
                        viewModel.executeConfirmedCleanup(dryRunOnly: true)
                    }
                } label: {
                    Text(viewModel.deletionMode.shortTitle)
                        .font(.system(size: 12))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                Spacer()

                Button("Cancel") {
                    viewModel.isShowingDryRunPreview = false
                }
                .buttonStyle(.glass)
                .keyboardShortcut(.cancelAction)

                Button {
                    viewModel.executeConfirmedCleanup(dryRunOnly: false)
                } label: {
                    Text(
                        viewModel.deletionMode == .moveToTrash
                            ? "Move to Trash"
                            : "Delete Permanently"
                    )
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 8)
                }
                .buttonStyle(.glassProminent)
                .tint(viewModel.deletionMode == .moveToTrash ? nil : .red)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 610)
    }
}
