import SwiftUI
import AppKit
import DevCleanerCore

public struct MenuBarPopoverView: View {
    @Bindable var viewModel: AppViewModel
    @Environment(\.openWindow) private var openWindow

    public init(viewModel: AppViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Minimal Header with Free Disk Space Monitor
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(viewModel.formattedTotalFoundBytes)
                        .font(.system(size: 20, weight: .semibold))
                        .monospacedDigit()
                    HStack(spacing: 5) {
                        if viewModel.isLowDiskSpace {
                            Circle()
                                .fill(Color.orange)
                                .frame(width: 6, height: 6)
                        }
                        Text("\(viewModel.diskSpace.formattedFree) free on Mac")
                            .font(.system(size: 11))
                            .foregroundStyle(viewModel.isLowDiskSpace ? Color.orange : .secondary)
                            .monospacedDigit()
                    }
                }

                Spacer()

                Button {
                    viewModel.startScan()
                } label: {
                    if viewModel.isScanning {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11))
                    }
                }
                .buttonStyle(.glass)
                .controlSize(.small)
                .disabled(viewModel.isScanning)
            }

            if viewModel.isLowDiskSpace || viewModel.isAboveJunkThreshold {
                HStack(spacing: 6) {
                    Image(systemName: viewModel.isLowDiskSpace ? "externaldrive.badge.exclamationmark" : "sparkles")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                    Text(
                        viewModel.isLowDiskSpace
                            ? "Low disk space · Safe Sweep frees \(viewModel.formattedSafeSweepBytes)"
                            : "Over \(Int(viewModel.menuBarAlertThresholdGB)) GB of dev husks found"
                    )
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassEffect(.clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            }

            Divider().opacity(0.45)

            // Categories + Dormant Clones
            VStack(spacing: 6) {
                ForEach(CleanupCategory.allCases) { category in
                    let catBytes = viewModel.bytes(for: category)
                    HStack {
                        Text(category.title)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(ByteFormatting.string(from: catBytes))
                            .font(.system(size: 12, weight: .medium))
                            .monospacedDigit()
                    }
                }

                if viewModel.dormantCloneTotalBytes > 0 {
                    HStack {
                        Text("Dormant Clones")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(ByteFormatting.string(from: viewModel.dormantCloneTotalBytes))
                            .font(.system(size: 12, weight: .medium))
                            .monospacedDigit()
                    }
                }
            }

            Divider().opacity(0.45)

            // Actions
            VStack(spacing: 6) {
                if !viewModel.safeSweepItems.isEmpty {
                    Button {
                        openMainWorkspaceWindow()
                        viewModel.applySafeSweepSelection(andPreview: true)
                    } label: {
                        HStack {
                            Text("Safe Sweep")
                            Spacer()
                            Text("+\(viewModel.formattedSafeSweepBytes)")
                                .monospacedDigit()
                        }
                        .font(.system(size: 12, weight: .medium))
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.small)
                }

                HStack(spacing: 8) {
                    Button {
                        openMainWorkspaceWindow()
                    } label: {
                        Text("Open Husk")
                            .font(.system(size: 12))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)

                    Button {
                        openMainWorkspaceWindow()
                        viewModel.sidebarDestination = .settings
                    } label: {
                        Image(systemName: "gearshape")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                    .help("Settings & Updates")

                    Button("Quit") {
                        NSApplication.shared.terminate(nil)
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                }
            }
        }
        .padding(14)
        .frame(width: 265)
    }

    private func openMainWorkspaceWindow() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        openWindow(id: "main-workspace")
    }
}
