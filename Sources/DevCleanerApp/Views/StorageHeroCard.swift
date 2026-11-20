import SwiftUI
import DevCleanerCore

public struct StorageHeroCard: View {
    @Bindable var viewModel: AppViewModel

    public init(viewModel: AppViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        let visibleBytes = viewModel.filteredItems.reduce(0) { $0 + $1.allocatedSizeBytes }

        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(viewModel.sidebarDestination.title)
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(.primary)

                        Text(ByteFormatting.string(from: visibleBytes))
                            .font(.system(size: 20, weight: .light))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .contentTransition(.numericText())
                    }

                    Text(subtitleLine)
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }

                Spacer()

                HStack(spacing: 8) {
                    if viewModel.safeSweepTotalBytes > 0 {
                        Button {
                            viewModel.applySafeSweepSelection(andPreview: true)
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "sparkles")
                                    .font(.system(size: 11))
                                Text("Safe Sweep")
                                Text(viewModel.formattedSafeSweepBytes)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                            .font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                        }
                        .buttonStyle(.bordered)
                        .disabled(viewModel.isScanning)
                        .help("Select \(viewModel.safeSweepItems.count) rebuildable artifacts inactive for \(viewModel.safeSweepMinimumStaleDays)+ days")
                    }

                    Button {
                        viewModel.startScan()
                    } label: {
                        Group {
                            if viewModel.isScanning {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 12, weight: .medium))
                            }
                        }
                        .frame(width: 20, height: 18)
                    }
                    .buttonStyle(.bordered)
                    .disabled(viewModel.isScanning)
                    .help("Rescan")
                }
            }

            // Ultra-thin 4px proportional bar
            GeometryReader { geo in
                let total = max(1, Double(viewModel.totalFoundBytes))
                HStack(spacing: 2) {
                    ForEach(CleanupCategory.allCases) { category in
                        let catBytes = viewModel.bytes(for: category)
                        if catBytes > 0 {
                            let fraction = max(0.015, Double(catBytes) / total)
                            RoundedRectangle(cornerRadius: 2)
                                .fill(DevCleanerTheme.categoryColor(category))
                                .frame(width: max(4, (geo.size.width - 6) * fraction))
                                .help("\(category.title): \(ByteFormatting.string(from: catBytes))")
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.primary.opacity(0.06))
                )
            }
            .frame(height: 4)
        }
    }

    private var subtitleLine: String {
        var parts: [String] = ["\(viewModel.filteredItems.count) items"]
        if viewModel.shieldedItems.count > 0 {
            parts.append("\(viewModel.shieldedItems.count) active protected")
        }
        if viewModel.dormantCloneItems.count > 0 {
            parts.append("\(viewModel.dormantCloneItems.count) dormant")
        }
        if viewModel.diskSpace.freeBytes > 0 {
            parts.append("\(viewModel.diskSpace.formattedFree) free on disk")
        }
        return parts.joined(separator: " · ")
    }
}
