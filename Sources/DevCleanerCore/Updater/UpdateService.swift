import Foundation

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

        // A stable release (prerelease == nil) is greater than a prerelease of the same version
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

public struct UpdateService: Sendable {
    public static let currentAppVersion = "1.0.1"
    public static let currentBuildNumber = "2"
    public static let defaultGitHubRepo = "Piskaty/husk"

    public init() {}

    /// Checks either a GitHub repository (`owner/repo`) via GitHub Releases API or a full HTTPS `latest.json` URL on a custom website.
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
            // Treat as GitHub owner/repo slug
            let slug = trimmed
                .replacingOccurrences(of: "https://github.com/", with: "")
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard slug.split(separator: "/").count == 2,
                  let url = URL(string: "https://api.github.com/repos/\(slug)/releases/latest") else {
                return .failed(message: "Enter a valid GitHub 'owner/repo' (e.g. stabil/husk) or full HTTPS manifest URL.")
            }
            endpointURL = url
            isGitHubAPI = true
        }

        var request = URLRequest(url: endpointURL)
        request.timeoutInterval = 8.0
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

    /// Parses either a GitHub Releases `/releases/latest` JSON payload or a website `latest.json` manifest.
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
                // Prefer .dmg first, then .zip
                let dmgAsset = assets.first {
                    (($0["name"] as? String) ?? "").lowercased().hasSuffix(".dmg")
                }
                let zipAsset = assets.first {
                    (($0["name"] as? String) ?? "").lowercased().hasSuffix(".zip")
                }
                if let chosen = dmgAsset ?? zipAsset ?? assets.first,
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

        // Case 2: Website `latest.json` manifest (`version`, `downloadURL` / `download_url`, `releaseNotes` / `notes`, `sha256`)
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
