import SwiftUI
import DevCleanerCore

struct ScanChangesView: View {
    @Bindable var viewModel: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Since Last Scan")
                        .font(.system(size: 20, weight: .semibold))
                    if let comparison = viewModel.scanComparison {
                        Text("\(comparison.previousScanDate.formatted(date: .abbreviated, time: .shortened)) → \(comparison.currentScanDate.formatted(date: .abbreviated, time: .shortened))")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if viewModel.isScanning {
                    ProgressView().controlSize(.small)
                }
                Button("Scan Again") { viewModel.startScan() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(viewModel.isScanning || viewModel.isCleaning)
            }

            Divider().opacity(0.45)

            if let error = viewModel.scanComparisonError {
                message(error)
            } else if let comparison = viewModel.scanComparison {
                if comparison.growingProjects.isEmpty {
                    message("No new or growing folders since the previous scan.")
                } else {
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            ForEach(comparison.growingProjects) { project in
                                projectSection(project)
                            }
                        }
                        .padding(.bottom, 16)
                    }
                }
            } else {
                message("Complete two scans with the same scan settings to compare storage changes.")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, 28)
        .padding(.top, 44)
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func projectSection(_ project: ScanComparison.ProjectChange) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(project.title).font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("\(signedSize(project.bytesAdded)) net")
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
            }
            ForEach(project.growingArtifacts) { artifact in
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(artifact.title).font(.system(size: 12, weight: .medium))
                            if artifact.isNew {
                                SubtleTag(text: "New")
                            }
                        }
                        Text(artifact.path)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                    Text(signedSize(artifact.bytesAdded))
                        .font(.system(size: 12))
                        .monospacedDigit()
                    Button {
                        viewModel.revealInFinder(URL(fileURLWithPath: artifact.path))
                    } label: {
                        Image(systemName: "folder")
                    }
                    .buttonStyle(.borderless)
                    .help("Reveal in Finder")
                    .accessibilityLabel("Reveal in Finder")
                }
                .padding(.vertical, 4)
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
    }

    private func signedSize(_ bytes: Int64) -> String {
        let sign = bytes > 0 ? "+" : (bytes < 0 ? "−" : "")
        return sign + ByteFormatting.string(from: abs(bytes))
    }
}
