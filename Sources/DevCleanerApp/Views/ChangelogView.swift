import SwiftUI
import DevCleanerCore

struct ChangelogView: View {
    let releases: [ChangelogRelease]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Changelog")
                .font(.system(size: 26, weight: .semibold))
            if releases.isEmpty {
                Text("Release notes are unavailable.")
                    .foregroundStyle(.secondary)
            } else {
                releaseList(releases)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, 28)
        .padding(.top, 44)
    }
}

struct WhatsNewSheet: View {
    let releases: [ChangelogRelease]
    let showChangelog: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("What’s New")
                .font(.system(size: 22, weight: .semibold))
            releaseList(releases)
                .frame(maxHeight: 420)
            HStack {
                Button("View Changelog", action: showChangelog)
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 560)
    }
}

private func releaseList(_ releases: [ChangelogRelease]) -> some View {
    ScrollView {
        VStack(alignment: .leading, spacing: 20) {
            ForEach(releases) { release in
                VStack(alignment: .leading, spacing: 9) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("Husk \(release.id)")
                            .font(.headline)
                        Text(release.date)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityAddTraits(.isHeader)

                    ForEach(release.changes, id: \.self) { change in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("•").accessibilityHidden(true)
                            Text(change).fixedSize(horizontal: false, vertical: true)
                        }
                        .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.bottom, 16)
    }
}
