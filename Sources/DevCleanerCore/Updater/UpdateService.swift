import Foundation
import CryptoKit

public struct SemanticVersion: Comparable, Equatable, Sendable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int
    public let prerelease: String?

    public init(major: Int, minor: Int, patch: Int, prerelease: String? = nil) {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = prerelease
    }

    public init?(string: String) {
        var cleaned = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("v") || cleaned.hasPrefix("V") {
            cleaned.removeFirst()
        }
        guard !cleaned.isEmpty else { return nil }

        let parts = cleaned.split(separator: "-", maxSplits: 1).map(String.init)
        let corePart = parts[0]
        let prereleasePart: String? = parts.count > 1 ? parts[1] : nil

        let numbers = corePart.split(separator: ".").compactMap { Int($0) }
        guard !numbers.isEmpty else { return nil }

        self.major = numbers[0]
        self.minor = numbers.count > 1 ? numbers[1] : 0
        self.patch = numbers.count > 2 ? numbers[2] : 0
        self.prerelease = prereleasePart
    }

    public var description: String {
        if let prerelease, !prerelease.isEmpty {
            return "\(major).\(minor).\(patch)-\(prerelease)"
        }
        return "\(major).\(minor).\(patch)"
    }

    public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }

        switch (lhs.prerelease, rhs.prerelease) {
        case (nil, nil):
            return false
        case (.some, nil):
            return true
        case (nil, .some):
            return false
        case (.some(let lPre), .some(let rPre)):
            return lPre < rPre
        }
    }
}

public struct AppReleaseInfo: Codable, Sendable, Equatable {
    public let version: String
    public let downloadURL: URL
    public let releasePageURL: URL?
    public let releaseNotes: String
    public let publishedAt: String?
    public let sha256: String?

    public init(
        version: String,
        downloadURL: URL,
        releasePageURL: URL? = nil,
        releaseNotes: String = "",
        publishedAt: String? = nil,
        sha256: String? = nil
    ) {
        self.version = version
        self.downloadURL = downloadURL
        self.releasePageURL = releasePageURL
        self.releaseNotes = releaseNotes
        self.publishedAt = publishedAt
        self.sha256 = sha256
    }

    public var semanticVersion: SemanticVersion? {
        SemanticVersion(string: version)
    }
}

public enum UpdateCheckStatus: Sendable, Equatable {
    case idle
    case checking
    case upToDate(currentVersion: String, checkedAt: Date)
    case updateAvailable(release: AppReleaseInfo, currentVersion: String)
    case failed(message: String)
}

public enum UpdateInstallPhase: Sendable, Equatable {
    case idle
    case downloading
    case extracting
    case verifying
    case restarting
    case failed(String)

    public var isInProgress: Bool {
        switch self {
        case .downloading, .extracting, .verifying, .restarting:
            return true
        case .idle, .failed:
            return false
        }
    }

    public var label: String {
        switch self {
        case .idle: return ""
        case .downloading: return "Downloading update…"
        case .extracting: return "Extracting Husk.app…"
        case .verifying: return "Verifying bundle & signature…"
        case .restarting: return "Installing & relaunching…"
        case .failed(let msg): return "Update failed: \(msg)"
        }
    }
}

public struct UpdateService: Sendable {
    public static let currentAppVersion = "1.0.4"
    public static let currentBuildNumber = "5"
    public static let defaultGitHubRepo = "Piskaty/husk"

    public init() {}

    // MARK: - Check for Updates

    public func checkForUpdates(
        source: String,
        currentVersion: String = Self.currentAppVersion
    ) async -> UpdateCheckStatus {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .failed(message: "Update source is empty. Enter a GitHub 'owner/repo' or website 'latest.json' URL.")
        }

        let endpointURL: URL
        let isGitHubAPI: Bool

        if trimmed.hasPrefix("https://") || trimmed.hasPrefix("http://") {
            guard let url = URL(string: trimmed) else {
                return .failed(message: "Invalid update feed URL.")
            }
            endpointURL = url
            isGitHubAPI = trimmed.contains("api.github.com/repos/")
        } else {
            let slug = trimmed
                .replacingOccurrences(of: "https://github.com/", with: "")
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard slug.split(separator: "/").count == 2,
                  let url = URL(string: "https://api.github.com/repos/\(slug)/releases/latest") else {
                return .failed(message: "Enter a valid GitHub 'owner/repo' (e.g. Piskaty/husk) or full HTTPS manifest URL.")
            }
            endpointURL = url
            isGitHubAPI = true
        }

        var request = URLRequest(url: endpointURL)
        request.timeoutInterval = 10.0
        request.setValue("Husk/\(currentVersion) (macOS)", forHTTPHeaderField: "User-Agent")
        if isGitHubAPI {
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failed(message: "Unexpected response from update server.")
            }
            if http.statusCode == 404 {
                return .upToDate(currentVersion: currentVersion, checkedAt: Date())
            }
            guard (200..<300).contains(http.statusCode) else {
                return .failed(message: "Update server returned HTTP \(http.statusCode).")
            }

            let release = try Self.parseReleasePayload(data: data, fallbackURL: endpointURL)
            return Self.compare(release: release, againstCurrentVersion: currentVersion)
        } catch {
            return .failed(message: "Could not reach update feed: \(error.localizedDescription)")
        }
    }

    // MARK: - In-App Self-Update (Download, Extract, Verify, Atomic Swap & Relaunch)

    /// Downloads the release `.zip` archive directly in-process (no browser quarantine),
    /// verifies optional SHA-256 + `codesign`, and returns the staged `Husk.app` URL ready for atomic replacement.
    public func downloadAndStageUpdate(
        release: AppReleaseInfo,
        onPhaseChange: @Sendable (UpdateInstallPhase) -> Void
    ) async throws -> (stagedAppURL: URL, stagingRootURL: URL) {
        let fm = FileManager.default
        let stagingRoot = fm.temporaryDirectory
            .appendingPathComponent("husk-update-\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL
        try fm.createDirectory(at: stagingRoot, withIntermediateDirectories: true)

        onPhaseChange(.downloading)
        var request = URLRequest(url: release.downloadURL)
        request.timeoutInterval = 120.0
        request.setValue("Husk/\(Self.currentAppVersion) (macOS)", forHTTPHeaderField: "User-Agent")

        let (tempDownloadedURL, response) = try await URLSession.shared.download(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw NSError(
                domain: "HuskSelfUpdateError",
                code: code,
                userInfo: [NSLocalizedDescriptionKey: "Download failed with HTTP \(code)."]
            )
        }

        let archiveURL = stagingRoot.appendingPathComponent("Husk-update.zip")
        try? fm.removeItem(at: archiveURL)
        try fm.moveItem(at: tempDownloadedURL, to: archiveURL)

        // Optional SHA-256 verification if provided by manifest
        if let expectedHash = release.sha256?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           !expectedHash.isEmpty {
            let actualHash = try Self.sha256Hex(of: archiveURL)
            guard actualHash == expectedHash else {
                try? fm.removeItem(at: stagingRoot)
                throw NSError(
                    domain: "HuskSelfUpdateError",
                    code: 10,
                    userInfo: [NSLocalizedDescriptionKey: "SHA-256 checksum mismatch for downloaded archive."]
                )
            }
        }

        // Extract .zip using macOS ditto (preserves bundle structure & code signature)
        onPhaseChange(.extracting)
        let extractedDir = stagingRoot.appendingPathComponent("extracted", isDirectory: true)
        try fm.createDirectory(at: extractedDir, withIntermediateDirectories: true)
        try Self.runHelperProcess(executable: "/usr/bin/ditto", arguments: ["-x", "-k", archiveURL.path, extractedDir.path])

        let stagedAppURL = extractedDir.appendingPathComponent("Husk.app", isDirectory: true).standardizedFileURL
        let executableURL = stagedAppURL.appendingPathComponent("Contents/MacOS/Husk")
        guard fm.fileExists(atPath: stagedAppURL.path), fm.isExecutableFile(atPath: executableURL.path) else {
            try? fm.removeItem(at: stagingRoot)
            throw NSError(
                domain: "HuskSelfUpdateError",
                code: 11,
                userInfo: [NSLocalizedDescriptionKey: "Release archive did not contain a valid Husk.app bundle."]
            )
        }

        // Verify signature and clear any extended quarantine attributes
        onPhaseChange(.verifying)
        _ = try? Self.runHelperProcess(executable: "/usr/bin/xattr", arguments: ["-cr", stagedAppURL.path])
        try Self.runHelperProcess(executable: "/usr/bin/codesign", arguments: ["--verify", "--deep", "--strict", stagedAppURL.path])

        return (stagedAppURL, stagingRoot)
    }

    /// Spawns a detached helper script that waits for `currentPID` to terminate,
    /// atomically swaps `targetAppBundleURL` with `stagedAppURL` (with rollback on error),
    /// clears quarantine, and relaunches the new `Husk.app`.
    public func launchSelfReplaceAndRelaunch(
        stagedAppURL: URL,
        stagingRootURL: URL,
        targetAppBundleURL: URL,
        currentPID: Int32 = ProcessInfo.processInfo.processIdentifier
    ) throws {
        let scriptURL = stagingRootURL.appendingPathComponent("apply-update.sh")
        let script = """
        #!/bin/zsh
        set -euo pipefail

        OLD_PID="\(currentPID)"
        STAGED="\(Self.escapeForDoubleQuotes(stagedAppURL.path))"
        TARGET="\(Self.escapeForDoubleQuotes(targetAppBundleURL.path))"
        STAGING_ROOT="\(Self.escapeForDoubleQuotes(stagingRootURL.path))"
        BACKUP="${TARGET}.previous.$$"

        # Wait up to 10 seconds for the old Husk process to exit cleanly
        for i in {1..100}; do
          if ! kill -0 "$OLD_PID" 2>/dev/null; then
            break
          fi
          sleep 0.1
        done

        # Atomic swap with rollback protection
        mkdir -p "$(dirname "$TARGET")"
        if [[ -e "$TARGET" ]]; then
          mv "$TARGET" "$BACKUP"
        fi

        if mv "$STAGED" "$TARGET"; then
          rm -rf "$BACKUP"
          /usr/bin/xattr -cr "$TARGET" 2>/dev/null || true
          /usr/bin/open -n "$TARGET"
        else
          # Roll back if swap failed
          if [[ -e "$BACKUP" ]]; then
            mv "$BACKUP" "$TARGET"
          fi
        fi

        rm -rf "$STAGING_ROOT"
        """

        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [scriptURL.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    public static func resolveCurrentInstallBundleURL() -> URL {
        let bundleURL = Bundle.main.bundleURL.standardizedFileURL
        if bundleURL.pathExtension == "app" {
            return bundleURL
        }
        return URL(fileURLWithPath: "/Applications/Husk.app", isDirectory: true)
    }

    public static func sha256Hex(of fileURL: URL) throws -> String {
        let data = try Data(contentsOf: fileURL)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func escapeForDoubleQuotes(_ input: String) -> String {
        input
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "$", with: "\\$")
            .replacingOccurrences(of: "`", with: "\\`")
    }

    private static func runHelperProcess(executable: String, arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let errPipe = Pipe()
        process.standardOutput = Pipe()
        process.standardError = errPipe
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let errStr = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                ?? "Command failed with exit code \(process.terminationStatus)"
            throw NSError(domain: "HuskSelfUpdateError", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: errStr])
        }
    }

    // MARK: - Manifest Parsing & Version Comparison

    public static func parseReleasePayload(data: Data, fallbackURL: URL) throws -> AppReleaseInfo {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "HuskUpdateError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid JSON payload"])
        }

        // Case 1: GitHub Releases API payload (`tag_name`, `assets`, `body`, `html_url`)
        if let tagName = json["tag_name"] as? String {
            let htmlURL = (json["html_url"] as? String).flatMap(URL.init(string:))
            let body = (json["body"] as? String) ?? ""
            let publishedAt = json["published_at"] as? String

            var downloadURL: URL? = nil
            if let assets = json["assets"] as? [[String: Any]] {
                // Prefer .zip for direct in-app ditto extraction, fallback to .dmg
                let zipAsset = assets.first {
                    (($0["name"] as? String) ?? "").lowercased().hasSuffix(".zip")
                }
                let dmgAsset = assets.first {
                    (($0["name"] as? String) ?? "").lowercased().hasSuffix(".dmg")
                }
                if let chosen = zipAsset ?? dmgAsset ?? assets.first,
                   let urlString = chosen["browser_download_url"] as? String {
                    downloadURL = URL(string: urlString)
                }
            }

            let finalDownload = downloadURL ?? htmlURL ?? fallbackURL
            return AppReleaseInfo(
                version: tagName,
                downloadURL: finalDownload,
                releasePageURL: htmlURL,
                releaseNotes: body,
                publishedAt: publishedAt,
                sha256: nil
            )
        }

        // Case 2: Website `latest.json` manifest
        if let version = json["version"] as? String {
            let urlStr = (json["downloadURL"] as? String)
                ?? (json["download_url"] as? String)
                ?? (json["url"] as? String)
            let downloadURL = urlStr.flatMap(URL.init(string:)) ?? fallbackURL
            let pageStr = (json["releasePageURL"] as? String) ?? (json["release_page_url"] as? String)
            let releasePageURL = pageStr.flatMap(URL.init(string:))
            let notes = (json["releaseNotes"] as? String)
                ?? (json["release_notes"] as? String)
                ?? (json["notes"] as? String)
                ?? ""
            let publishedAt = (json["publishedAt"] as? String) ?? (json["published_at"] as? String)
            let sha256 = json["sha256"] as? String

            return AppReleaseInfo(
                version: version,
                downloadURL: downloadURL,
                releasePageURL: releasePageURL,
                releaseNotes: notes,
                publishedAt: publishedAt,
                sha256: sha256
            )
        }

        throw NSError(domain: "HuskUpdateError", code: 2, userInfo: [NSLocalizedDescriptionKey: "Unrecognized release manifest schema"])
    }

    public static func compare(release: AppReleaseInfo, againstCurrentVersion currentVersion: String) -> UpdateCheckStatus {
        guard let currentSemver = SemanticVersion(string: currentVersion),
              let latestSemver = release.semanticVersion else {
            return .upToDate(currentVersion: currentVersion, checkedAt: Date())
        }
        if latestSemver > currentSemver {
            return .updateAvailable(release: release, currentVersion: currentSemver.description)
        }
        return .upToDate(currentVersion: currentSemver.description, checkedAt: Date())
    }
}
