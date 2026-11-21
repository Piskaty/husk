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

        let parts = cleaned.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        let corePart = parts[0]
        let prereleasePart: String? = parts.count > 1 ? parts[1] : nil

        let components = corePart.split(separator: ".", omittingEmptySubsequences: false)
        let numbers = components.compactMap { Int($0) }
        guard !numbers.isEmpty, numbers.count == components.count, numbers.count <= 3,
              prereleasePart?.isEmpty != true else { return nil }

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
    public let signatureURL: URL?

    public init(
        version: String,
        downloadURL: URL,
        releasePageURL: URL? = nil,
        releaseNotes: String = "",
        publishedAt: String? = nil,
        sha256: String? = nil,
        signatureURL: URL? = nil
    ) {
        self.version = version
        self.downloadURL = downloadURL
        self.releasePageURL = releasePageURL
        self.releaseNotes = releaseNotes
        self.publishedAt = publishedAt
        self.sha256 = sha256
        self.signatureURL = signatureURL
    }

    public var canInstallInApp: Bool {
        guard let signatureURL else { return false }
        return UpdateService.isHTTPS(downloadURL) && UpdateService.isHTTPS(signatureURL)
            && downloadURL.pathExtension.lowercased() == "zip"
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
    public static let currentAppVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.5"
    public static let currentBuildNumber = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "6"
    static let releaseSigningPublicKey = "uGF8YCWlDXzBpsDwjQlk48PxFdhUHB3RPUF/uhSiNaM="
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

        if trimmed.contains("://") {
            guard let url = URL(string: trimmed), Self.isHTTPS(url) else {
                return .failed(message: "Update feed URLs must use HTTPS.")
            }
            endpointURL = url
            isGitHubAPI = url.host == "api.github.com"
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
            let (data, response) = try await URLSession.shared.data(for: request, delegate: HTTPSOnlyRedirects())
            guard let http = response as? HTTPURLResponse, http.url.map(Self.isHTTPS) == true else {
                return .failed(message: "Unexpected response from update server.")
            }
            if isGitHubAPI && http.statusCode == 404 {
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

    /// Authenticates the archive before extraction, then verifies the bundle before it can replace the app.
    public func downloadAndStageUpdate(
        release: AppReleaseInfo,
        onPhaseChange: @Sendable (UpdateInstallPhase) -> Void
    ) async throws -> (stagedAppURL: URL, stagingRootURL: URL) {
        guard release.canInstallInApp, let signatureURL = release.signatureURL else {
            throw Self.updateError("An HTTPS ZIP and a Husk release signature are required.")
        }

        let fm = FileManager.default
        let stagingRoot = fm.temporaryDirectory
            .appendingPathComponent("husk-update-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: stagingRoot, withIntermediateDirectories: false,
                               attributes: [.posixPermissions: 0o700])
        var staged = false
        defer {
            if !staged { try? fm.removeItem(at: stagingRoot) }
        }

        onPhaseChange(.downloading)
        let archiveURL = stagingRoot.appendingPathComponent("Husk-update.zip")
        let signatureFile = stagingRoot.appendingPathComponent("Husk-update.zip.sig")
        try await Self.download(from: release.downloadURL, to: archiveURL)
        try await Self.download(from: signatureURL, to: signatureFile)

        onPhaseChange(.verifying)
        let archive = try Data(contentsOf: archiveURL, options: .mappedIfSafe)
        let signatureSize = try signatureFile.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard signatureSize > 0, signatureSize <= 128 else {
            throw Self.updateError("Invalid Husk release signature.")
        }

        let signature = try String(contentsOf: signatureFile, encoding: .utf8)
        try Self.verifyArchiveSignature(archive, signature: signature)
        if let sha256 = release.sha256, !sha256.isEmpty, Self.sha256Hex(of: archive) != sha256.lowercased() {
            throw Self.updateError("SHA-256 checksum mismatch for downloaded archive.")
        }

        onPhaseChange(.extracting)
        let extractedDir = stagingRoot.appendingPathComponent("extracted", isDirectory: true)
        try fm.createDirectory(at: extractedDir, withIntermediateDirectories: false)
        try CommandRunner.run("/usr/bin/ditto", arguments: ["-x", "-k", archiveURL.path, extractedDir.path], timeout: 60)

        let stagedAppURL = extractedDir.appendingPathComponent("Husk.app", isDirectory: true)
        let executableURL = stagedAppURL.appendingPathComponent("Contents/MacOS/Husk")
        guard SafetyInspector.pathComponentError(for: executableURL) == nil,
              fm.isExecutableFile(atPath: executableURL.path),
              let bundle = Bundle(url: stagedAppURL), bundle.bundleIdentifier == "com.stabil.husk",
              let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              let bundleVersion = SemanticVersion(string: version),
              bundleVersion == release.semanticVersion,
              let currentVersion = SemanticVersion(string: Self.currentAppVersion),
              bundleVersion > currentVersion else {
            throw Self.updateError("The signed archive did not contain the expected newer Husk release.")
        }

        onPhaseChange(.verifying)
        try CommandRunner.run("/usr/bin/codesign",
                              arguments: ["--verify", "--deep", "--strict", stagedAppURL.path], timeout: 30)
        staged = true
        return (stagedAppURL, stagingRoot)
    }

    static func verifyArchiveSignature(_ archive: Data, signature: String,
                                       publicKey: String = releaseSigningPublicKey) throws {
        guard let keyBytes = Data(base64Encoded: publicKey),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyBytes),
              let signatureBytes = Data(base64Encoded: signature.trimmingCharacters(in: .whitespacesAndNewlines)),
              key.isValidSignature(signatureBytes, for: archive) else {
            throw updateError("The archive does not have a valid Husk release signature.")
        }
    }

    static func isHTTPS(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host != nil && url.user == nil && url.password == nil
    }

    private static func download(from url: URL, to destination: URL) async throws {
        var request = URLRequest(url: url)
        request.timeoutInterval = 120
        request.setValue("Husk/\(currentAppVersion) (macOS)", forHTTPHeaderField: "User-Agent")
        let (temporaryFile, response) = try await URLSession.shared.download(for: request, delegate: HTTPSOnlyRedirects())
        guard let http = response as? HTTPURLResponse, http.url.map(isHTTPS) == true,
              (200..<300).contains(http.statusCode) else {
            throw updateError("Could not download the update over HTTPS.")
        }
        try FileManager.default.moveItem(at: temporaryFile, to: destination)
    }

    private static func updateError(_ message: String) -> NSError {
        NSError(domain: "HuskSelfUpdateError", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    /// Spawns a detached helper script that waits for `currentPID` to terminate,
    /// replaces `targetAppBundleURL` with `stagedAppURL` (with rollback on error),
    /// clears quarantine, and relaunches the new `Husk.app`.
    public func launchSelfReplaceAndRelaunch(
        stagedAppURL: URL,
        stagingRootURL: URL,
        targetAppBundleURL: URL,
        currentPID: Int32 = ProcessInfo.processInfo.processIdentifier
    ) throws {
        guard FileManager.default.isWritableFile(atPath: targetAppBundleURL.deletingLastPathComponent().path) else {
            try? FileManager.default.removeItem(at: stagingRootURL)
            throw Self.updateError("Move Husk to a writable Applications folder before installing updates.")
        }
        let scriptURL = stagingRootURL.appendingPathComponent("apply-update.sh")
        let script = """
        #!/bin/zsh
        set -euo pipefail

        OLD_PID="\(currentPID)"
        STAGED="\(Self.escapeForDoubleQuotes(stagedAppURL.path))"
        TARGET="\(Self.escapeForDoubleQuotes(targetAppBundleURL.path))"
        STAGING_ROOT="\(Self.escapeForDoubleQuotes(stagingRootURL.path))"
        BACKUP="${TARGET}.previous.$$"
        INCOMING="${TARGET}.incoming.$$"
        [[ ! -e "$INCOMING" && ! -L "$INCOMING" && ! -e "$BACKUP" && ! -L "$BACKUP" ]]
        trap 'rm -rf "$STAGING_ROOT" "$INCOMING"' EXIT

        # Stage on the install volume before moving the original bundle.
        mv "$STAGED" "$INCOMING"
        /usr/bin/codesign --verify --deep --strict "$INCOMING"

        # Wait up to 10 seconds for the old Husk process to exit cleanly
        for i in {1..100}; do
          if ! kill -0 "$OLD_PID" 2>/dev/null; then
            break
          fi
          sleep 0.1
        done

        if kill -0 "$OLD_PID" 2>/dev/null; then
          exit 1
        fi

        # Replace with rollback protection
        if [[ -e "$TARGET" ]]; then
          mv "$TARGET" "$BACKUP"
        fi

        if mv "$INCOMING" "$TARGET"; then
          /usr/bin/xattr -d com.apple.quarantine "$TARGET" 2>/dev/null || true
          if /usr/bin/open -n "$TARGET"; then
            rm -rf "$BACKUP"
          elif [[ -e "$BACKUP" ]]; then
            rm -rf "$TARGET"
            mv "$BACKUP" "$TARGET"
            /usr/bin/open -n "$TARGET"
          fi
        else
          # Roll back if swap failed
          if [[ -e "$BACKUP" ]]; then
            mv "$BACKUP" "$TARGET"
            /usr/bin/open -n "$TARGET"
          fi
        fi
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
        try sha256Hex(of: Data(contentsOf: fileURL, options: .mappedIfSafe))
    }

    private static func sha256Hex(of data: Data) -> String {
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

            let assets = json["assets"] as? [[String: Any]] ?? []
            let chosen = assets.first { (($0["name"] as? String) ?? "").lowercased().hasSuffix(".zip") }
            let downloadURL = (chosen?["browser_download_url"] as? String).flatMap(URL.init(string:))
            let signatureURL = (chosen?["name"] as? String).flatMap { zipName in
                let signature = assets.first { ($0["name"] as? String) == zipName + ".sig" }
                return (signature?["browser_download_url"] as? String).flatMap(URL.init(string:))
            }
            let finalDownload = downloadURL ?? htmlURL ?? fallbackURL
            return AppReleaseInfo(
                version: tagName,
                downloadURL: finalDownload,
                releasePageURL: htmlURL,
                releaseNotes: body,
                publishedAt: publishedAt,
                sha256: nil,
                signatureURL: signatureURL
            )
        }

        // Case 2: Website `latest.json` manifest
        if let version = json["version"] as? String {
            let urlStr = (json["downloadURL"] as? String)
                ?? (json["download_url"] as? String)
                ?? (json["url"] as? String)
            let downloadURL = urlStr.flatMap { URL(string: $0, relativeTo: fallbackURL)?.absoluteURL } ?? fallbackURL
            let pageStr = (json["releasePageURL"] as? String) ?? (json["release_page_url"] as? String)
            let releasePageURL = pageStr.flatMap(URL.init(string:))
            let notes = (json["releaseNotes"] as? String)
                ?? (json["release_notes"] as? String)
                ?? (json["notes"] as? String)
                ?? ""
            let publishedAt = (json["publishedAt"] as? String) ?? (json["published_at"] as? String)
            let sha256 = json["sha256"] as? String
            let signatureURL = ((json["signatureURL"] as? String) ?? (json["signature_url"] as? String))
                .flatMap { URL(string: $0, relativeTo: fallbackURL)?.absoluteURL }

            return AppReleaseInfo(
                version: version,
                downloadURL: downloadURL,
                releasePageURL: releasePageURL,
                releaseNotes: notes,
                publishedAt: publishedAt,
                sha256: sha256,
                signatureURL: signatureURL
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


private final class HTTPSOnlyRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(request.url.map(UpdateService.isHTTPS) == true ? request : nil)
    }
}
