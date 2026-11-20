import SwiftUI
import DevCleanerCore

public struct ArtifactRowCard: View {
    public let item: CleanupItem
    public let isSelected: Bool
    public let maxSizeBytes: Int64
    public let onToggle: () -> Void
    public let onRevealInFinder: () -> Void
    public let onOpenInTerminal: () -> Void
    public let onCopyRebuildCommand: () -> Void

    @ViewState private var isHovered: Bool = false

    public init(
        item: CleanupItem,
        isSelected: Bool,
        maxSizeBytes: Int64,
        onToggle: @escaping () -> Void,
        onRevealInFinder: @escaping () -> Void,
        onOpenInTerminal: @escaping () -> Void,
        onCopyRebuildCommand: @escaping () -> Void
    ) {
        self.item = item
        self.isSelected = isSelected
        self.maxSizeBytes = maxSizeBytes
        self.onToggle = onToggle
        self.onRevealInFinder = onRevealInFinder
        self.onOpenInTerminal = onOpenInTerminal
        self.onCopyRebuildCommand = onCopyRebuildCommand
    }

    public var body: some View {
        HStack(spacing: 12) {
            // Minimal checkbox
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(isSelected ? Color.primary : Color.secondary.opacity(0.4))

            // Primary title & subtle tags
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(item.projectName)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    if item.title != item.projectName {
                        Text(item.title)
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    if item.protection.isShielded {
                        SubtleTag(text: "Active", systemImage: "shield.fill")
                            .help(item.protection.shieldSummary ?? "Active repository")
                    } else if let dormantText = item.protection.dormantBadgeText {
                        SubtleTag(text: dormantText, systemImage: "moon.zzz")
                            .help("Untouched for \(item.stalenessDays) days\(item.protection.isReadOnlyClone ? " · 0 local commits since clone" : "")")
                    } else if item.actionKind.isToolCommand {
                        SubtleTag(text: "CLI", systemImage: "terminal")
                            .help(item.regenerateHint)
                    } else if item.effectiveSafetyTier == .protectedManual {
                        SubtleTag(text: "Manual")
                            .help(item.regenerateHint)
                    }
                }

                Text(item.displayPath)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 12)

            // Hover-only utility buttons
            if isHovered {
                HStack(spacing: 4) {
                    if let rebuildCmd = item.rebuildCommand ?? item.actionKind.displayCommandString {
                        Button(action: onCopyRebuildCommand) {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .frame(width: 24, height: 24)
                                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 5))
                        }
                        .buttonStyle(.plain)
                        .help("Copy command: \(rebuildCmd)")
                    }

                    Button(action: onRevealInFinder) {
                        Image(systemName: "folder")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .frame(width: 24, height: 24)
                            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 5))
                    }
                    .buttonStyle(.plain)
                    .help("Reveal in Finder")

                    if item.projectRootPath != nil {
                        Button(action: onOpenInTerminal) {
                            Image(systemName: "terminal")
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                                .frame(width: 24, height: 24)
                                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 5))
                        }
                        .buttonStyle(.plain)
                        .help("Open in Terminal")
                    }
                }
            }

            // Age
            Text(stalenessLabel)
                .font(.system(size: 11.5))
                .foregroundStyle(.tertiary)
                .monospacedDigit()
                .frame(width: 48, alignment: .trailing)

            // Clean tabular size
            Text(item.formattedSize)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)
                .monospacedDigit()
                .frame(width: 78, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
                    .glassEffect(.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else if isHovered {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.035))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggle)
        .onHover { hovering in
            isHovered = hovering
        }
    }

    private var stalenessLabel: String {
        let days = item.stalenessDays
        if days == 0 {
            return "today"
        } else {
            return "\(days)d"
        }
    }
}
