import SwiftUI
import DevCleanerCore

public struct AuditHistoryView: View {
    @Bindable var viewModel: AppViewModel

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
    }

    @ViewBuilder
    private func sessionSection(_ session: CleanupSessionRecord) -> some View {
        let restorableCount = session.restorableItemCount

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

                        Text(record.errorDescription ?? (record.isRestored ? "Restored"
                             : (record.canRestore ? "In Trash" : (session.wasDryRun ? "Simulated" : "Processed"))))
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
}
