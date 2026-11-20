import SwiftUI
import DevCleanerCore

public struct StorageHeroCard: View {
    @Bindable var viewModel: AppViewModel
    @ViewState private var hoveredCategory: CleanupCategory? = nil

    public init(viewModel: AppViewModel) {
        self.viewModel = viewModel
    }

    private struct BarSegment: Identifiable {
        let category: CleanupCategory
        let bytes: Int64
        let itemCount: Int
        let percentage: Double

        var id: CleanupCategory { category }

        var shortName: String {
            switch category {
            case .projectArtifacts: return "Projects"
            case .packageCaches: return "Caches"
            case .xcodeClutter: return "Xcode"
            case .containersAndAI: return "AI & Docker"
            }
        }
    }

    public var body: some View {
        let visibleBytes = viewModel.filteredItems.reduce(0) { $0 + $1.allocatedSizeBytes }
        let segments = computeSegments()

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

            // Colorful Segmented Storage Bar with Adaptive Inline Labels & Hover Inspection
            VStack(alignment: .leading, spacing: 6) {
                GeometryReader { geo in
                    let gap: CGFloat = 2
                    let totalGaps = CGFloat(max(0, segments.count - 1)) * gap
                    let usableWidth = max(1, geo.size.width - totalGaps)
                    let minSliver: CGFloat = 10
                    let reservedMinWidth = CGFloat(segments.count) * minSliver
                    let flexibleWidth = max(0, usableWidth - reservedMinWidth)
                    let totalBytes = max(1, Double(viewModel.totalFoundBytes))

                    if segments.isEmpty {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Color.primary.opacity(0.06))
                    } else {
                        HStack(spacing: gap) {
                            ForEach(segments) { segment in
                                let width = minSliver + flexibleWidth * (Double(segment.bytes) / totalBytes)
                                let isHovered = hoveredCategory == segment.category
                                let isActiveFilter = viewModel.sidebarDestination == .category(segment.category)
                                let baseColor = DevCleanerTheme.categoryColor(segment.category)
                                let sizeStr = ByteFormatting.string(from: segment.bytes)
                                let pctStr = segment.percentage < 0.1
                                    ? "<0.1%"
                                    : String(format: "%.1f%%", segment.percentage)

                                ZStack {
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .fill(baseColor.opacity(isHovered || isActiveFilter ? 1.0 : 0.88))

                                    // Adaptive inline label inside the colored area when there is room
                                    if width >= 175 {
                                        HStack(spacing: 5) {
                                            Text(segment.category.title)
                                                .font(.system(size: 11, weight: .semibold))
                                                .lineLimit(1)
                                            Text(sizeStr)
                                                .font(.system(size: 11, weight: .medium))
                                                .opacity(0.85)
                                                .monospacedDigit()
                                                .lineLimit(1)
                                        }
                                        .foregroundStyle(Color.white)
                                        .padding(.horizontal, 8)
                                    } else if width >= 96 {
                                        HStack(spacing: 4) {
                                            Text(segment.shortName)
                                                .font(.system(size: 10.5, weight: .semibold))
                                                .lineLimit(1)
                                            Text(sizeStr)
                                                .font(.system(size: 10.5, weight: .medium))
                                                .opacity(0.85)
                                                .monospacedDigit()
                                                .lineLimit(1)
                                        }
                                        .foregroundStyle(Color.white)
                                        .padding(.horizontal, 6)
                                    } else if width >= 54 {
                                        Text(sizeStr)
                                            .font(.system(size: 10.5, weight: .semibold))
                                            .foregroundStyle(Color.white)
                                            .monospacedDigit()
                                            .lineLimit(1)
                                            .padding(.horizontal, 4)
                                    }
                                }
                                .frame(width: width, height: 26)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .strokeBorder(
                                            Color.white.opacity(isActiveFilter ? 0.65 : (isHovered ? 0.35 : 0.0)),
                                            lineWidth: isActiveFilter ? 1.5 : 1.0
                                        )
                                )
                                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                .onHover { hovering in
                                    withAnimation(.easeOut(duration: 0.12)) {
                                        hoveredCategory = hovering ? segment.category : (hoveredCategory == segment.category ? nil : hoveredCategory)
                                    }
                                }
                                .onTapGesture {
                                    withAnimation(.snappy(duration: 0.18)) {
                                        if viewModel.sidebarDestination == .category(segment.category) {
                                            viewModel.sidebarDestination = .allJunk
                                        } else {
                                            viewModel.sidebarDestination = .category(segment.category)
                                        }
                                    }
                                }
                                .help("\(segment.category.title) — \(sizeStr) (\(pctStr), \(segment.itemCount) items) · Click to filter")
                            }
                        }
                    }
                }
                .frame(height: 26)

                // Instant hover callout bar for small segments (or subtle legend when hovering)
                if let hovered = hoveredCategory,
                   let seg = segments.first(where: { $0.category == hovered }) {
                    let pctStr = seg.percentage < 0.1 ? "<0.1%" : String(format: "%.1f%%", seg.percentage)
                    HStack(spacing: 6) {
                        Circle()
                            .fill(DevCleanerTheme.categoryColor(seg.category))
                            .frame(width: 7, height: 7)
                        Text(seg.category.title)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.primary)
                        Text("·")
                            .foregroundStyle(.tertiary)
                        Text("\(ByteFormatting.string(from: seg.bytes)) (\(pctStr))")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        Text("· \(seg.itemCount) \(seg.itemCount == 1 ? "item" : "items")")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                        Spacer()
                        Text("Click segment to filter")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.tertiary)
                    }
                    .transition(.opacity)
                }
            }
        }
    }

    private func computeSegments() -> [BarSegment] {
        let total = max(1, Double(viewModel.totalFoundBytes))
        return CleanupCategory.allCases.compactMap { category in
            let matching = viewModel.items.filter { $0.category == category }
            let bytes = matching.reduce(0) { $0 + $1.allocatedSizeBytes }
            guard bytes > 0 else { return nil }
            let pct = (Double(bytes) / total) * 100.0
            return BarSegment(
                category: category,
                bytes: bytes,
                itemCount: matching.count,
                percentage: pct
            )
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
