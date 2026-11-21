import SwiftUI
import DevCleanerCore

struct DockerStorageView: View {
    @ViewState private var snapshot: DockerStorageSnapshot?
    @ViewState private var error: String?
    @ViewState private var isLoading = true
    @ViewState private var refreshID = UUID()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Docker Storage")
                        .font(.system(size: 20, weight: .semibold))
                    if let snapshot {
                        Text("Local context · \(snapshot.context)")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button("Refresh") { refreshID = UUID() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isLoading)
            }

            Divider().opacity(0.45)

            if isLoading {
                ProgressView("Reading Docker storage…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error {
                Text(error)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let snapshot {
                usageTable(snapshot.rows)
                Text("Reclaimable space is Docker’s estimate for its local engine.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, 28)
        .padding(.top, 44)
        .task(id: refreshID) { await refresh() }
    }

    private func usageTable(_ rows: [DockerStorageSnapshot.Row]) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 10) {
            GridRow {
                Text("Type")
                Text("Total").gridColumnAlignment(.trailing)
                Text("Active").gridColumnAlignment(.trailing)
                Text("Size").gridColumnAlignment(.trailing)
                Text("Reclaimable").gridColumnAlignment(.trailing)
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            Divider()
            ForEach(rows) { row in
                GridRow {
                    Text(row.type).frame(maxWidth: .infinity, alignment: .leading)
                    Text(row.totalCount).monospacedDigit()
                    Text(row.active).monospacedDigit()
                    Text(row.size).monospacedDigit()
                    Text(row.reclaimable).monospacedDigit()
                }
                .font(.system(size: 13))
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
    }

    private func refresh() async {
        isLoading = true
        let result = await Task.detached(priority: .utility) { Result { try DockerStorageService.read() } }.value
        guard !Task.isCancelled else { return }
        switch result {
        case .success(let value):
            snapshot = value
            error = nil
        case .failure(let failure):
            snapshot = nil
            error = failure.localizedDescription
        }
        isLoading = false
    }
}
