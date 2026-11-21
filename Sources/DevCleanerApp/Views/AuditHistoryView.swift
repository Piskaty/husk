import AppKit
import SwiftUI
import DevCleanerCore

public struct AuditHistoryView: View {
    @Bindable var viewModel: AppViewModel
    @ViewState private var trashSummaries: [UUID: CleanupTrashSummary] = [:]
    @ViewState private var trashRefreshID = UUID()

    public init(viewModel: AppViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("History")
                        .font(.system(size: 20, weight: .semibold))
                    Text("Past cleanup sessions, Trash restore, and project rebuild scripts")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }

                Spacer()

                if !viewModel.auditSessions.isEmpty {
                    Button("Refresh Trash Status") { trashRefreshID = UUID() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }

                Button("Open Log Folder") {
                    let store = AuditLogStore()
                    viewModel.revealInFinder(store.storageDirectory)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            Divider().opacity(0.45)

            if viewModel.auditSessions.isEmpty {
                VStack(spacing: 6) {
                    Text("No history yet")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text("Completed cleanups appear here with 1-click restore from Trash and rebuild scripts.")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(viewModel.auditSessions) { session in
                            sessionSection(session)
                        }
                    }
                    .padding(.bottom, 16)
                }
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 44)
        .task(id: trashRefreshID) { await refreshTrashStatus() }
        .onChange(of: viewModel.auditSessions) { _, _ in trashRefreshID = UUID() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            trashRefreshID = UUID()
        }
    }

    @ViewBuilder
    private func sessionSection(_ session: CleanupSessionRecord) -> some View {
        let trash = trashSummaries[session.id]
        let restorableCount = trash?.urls.count ?? 0
        let hasUnverifiedItems = trash?.itemStatuses.values.contains(.unverified) == true

        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(session.timestamp.formatted(date: .abbreviated, time: .shortened))
                    .font(.system(size: 12.5, weight: .medium))

                Text("·")
                    .foregroundStyle(.tertiary)

                Text("\(session.items.count) items · \(session.storageSummary)")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()

                if session.wasDryRun {
                    SubtleTag(text: "Dry-Run")
                }

                Spacer()

                if session.rebuildShellScript != nil {
                    Button {
                        viewModel.copyRebuildScript(for: session)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 10))
                            Text("Copy Rebuild Script")
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Copies a shell script to re-bootstrap dependencies for projects in this session")
                }

                if restorableCount > 0 {
                    Button("Restore (\(restorableCount))") {
                        viewModel.undoCleanupSession(session)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(viewModel.isCleaning)
                }
            }

            if !session.wasDryRun, let trash, session.items.contains(where: { $0.trashedPath != nil }) {
                if restorableCount > 0 {
                    HStack {
                        Text("\(ByteFormatting.string(from: trash.estimatedBytes)) estimated still in Trash")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Show in Finder") { viewModel.revealTrashItems(session) }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                } else if !hasUnverifiedItems {
                    Text("Trash items for this session are unavailable.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                if hasUnverifiedItems {
                    Text("Review unverified Trash items manually in Finder.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }

            VStack(spacing: 0) {
                ForEach(session.items) { record in
                    HStack(spacing: 10) {
                        Text(record.projectName)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)

                        if record.title != record.projectName {
                            Text(record.title)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }

                        if let cmd = record.rebuildCommand {
                            Text(cmd)
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }

                        Spacer()

                        Text(recordStatus(record, session: session, trashStatus: trash?.itemStatuses[record.id]))
                            .font(.system(size: 11))
                            .foregroundStyle(record.errorDescription == nil ? Color.secondary : .orange)
                            .lineLimit(2)
                            .help(record.errorDescription ?? "")

                        Text(ByteFormatting.string(from: record.sizeBytes))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .frame(width: 70, alignment: .trailing)
                    }
                    .padding(.vertical, 5)
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.035))
        )
    }

    private func recordStatus(_ record: CleanedItemRecord, session: CleanupSessionRecord,
                              trashStatus: CleanupTrashItemStatus?) -> String {
        if let error = record.errorDescription { return error }
        if record.isRestored { return "Restored" }
        if session.wasDryRun { return "Simulated" }
        if record.trashedPath != nil, let trashStatus {
            switch trashStatus {
            case .verified: return "In Trash"
            case .unverified: return "Unverified"
            case .unavailable: return "Unavailable"
            }
        }
        return "Processed"
    }

    private func refreshTrashStatus() async {
        let sessions = viewModel.auditSessions
        let summaries = await Task.detached(priority: .utility) {
            Dictionary(sessions.map { ($0.id, $0.remainingTrash) }, uniquingKeysWith: { first, _ in first })
        }.value
        guard !Task.isCancelled else { return }
        trashSummaries = summaries
    }
}
