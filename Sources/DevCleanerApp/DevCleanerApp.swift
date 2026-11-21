import SwiftUI
import AppKit
import DevCleanerCore

public final class AppDelegate: NSObject, NSApplicationDelegate {
    public func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}

@main
public struct DevCleanerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ViewState private var viewModel = AppViewModel()

    public init() {}

    public var body: some Scene {
        WindowGroup("Husk", id: "main-workspace") {
            MainWorkspaceView(viewModel: viewModel)
                .frame(minWidth: 1040, minHeight: 680)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1180, height: 760)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    viewModel.checkForUpdates(navigateToSettings: true)
                }

                Button("Changelog") {
                    viewModel.sidebarDestination = .changelog
                }

                Button("Settings…") {
                    viewModel.sidebarDestination = .settings
                }
                .keyboardShortcut(",", modifiers: [.command])

                Divider()
            }

            CommandMenu("Cleanup") {
                Button("Command Palette…") {
                    withAnimation(.snappy(duration: 0.18)) {
                        viewModel.isShowingCommandPalette.toggle()
                    }
                }
                .keyboardShortcut("k", modifiers: [.command])

                Button("1-Click Safe Sweep (30d+ Inactive)") {
                    viewModel.applySafeSweepSelection(andPreview: true)
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])

                Button("Preview Dry-Run Manifest…") {
                    viewModel.openDryRunPreview()
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(viewModel.selectedItems.isEmpty)

                Divider()

                Button("Rescan Workspaces & Caches") {
                    viewModel.startScan()
                }
                .keyboardShortcut("r", modifiers: [.command])

                Button("Add Workspace Folder…") {
                    viewModel.promptToAddWorkspaceRoot()
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])

                Divider()

                Button("Select All Unshielded in View") {
                    viewModel.selectVisibleSafeItems()
                }
                .keyboardShortcut("a", modifiers: [.command, .shift])

                Button("Clear Selection") {
                    viewModel.clearSelection()
                }
                .keyboardShortcut(.escape, modifiers: [])
            }
        }

        MenuBarExtra {
            MenuBarPopoverView(viewModel: viewModel)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: viewModel.isLowDiskSpace ? "externaldrive.badge.exclamationmark" : "externaldrive.fill.badge.checkmark")
                if viewModel.totalFoundBytes > 0 {
                    Text(viewModel.needsMenuBarAttention ? "• \(viewModel.formattedTotalFoundBytes)" : viewModel.formattedTotalFoundBytes)
                }
            }
        }
        .menuBarExtraStyle(.window)
    }
}
