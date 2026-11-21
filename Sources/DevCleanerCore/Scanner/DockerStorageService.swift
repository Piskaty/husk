import Foundation

public struct DockerStorageSnapshot: Equatable, Sendable {
    public struct Row: Decodable, Equatable, Identifiable, Sendable {
        public let type: String
        public let totalCount: String
        public let active: String
        public let size: String
        public let reclaimable: String

        public var id: String { type }

        private enum CodingKeys: String, CodingKey {
            case type = "Type"
            case totalCount = "TotalCount"
            case active = "Active"
            case size = "Size"
            case reclaimable = "Reclaimable"
        }
    }

    public let context: String
    public let rows: [Row]
}

public enum DockerStorageService {
    public static func read() throws -> DockerStorageSnapshot {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            "/Applications/Docker.app/Contents/Resources/bin/docker",
            home.appendingPathComponent(".docker/bin/docker").path,
            "/opt/homebrew/bin/docker",
            "/usr/local/bin/docker"
        ]
        guard let executable = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw Failure.cliNotFound
        }
        return try read(using: executable)
    }

    static func read(using executable: String) throws -> DockerStorageSnapshot {
        let context = try CommandRunner.run(executable, arguments: ["context", "show"],
                                            timeout: 5, captureOutput: true)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !context.isEmpty else { throw Failure.missingContext }
        let endpoint = try CommandRunner.run(executable, arguments: [
            "context", "inspect", "--format", "{{.Endpoints.docker.Host}}", "--", context
        ], timeout: 5, captureOutput: true).trimmingCharacters(in: .whitespacesAndNewlines)
        guard endpoint.hasPrefix("unix:///") else { throw Failure.nonLocalContext(context) }

        // Use the inspected socket directly. The selected context may change while this request runs.
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "DOCKER_CONTEXT")
        environment.removeValue(forKey: "DOCKER_HOST")
        let output = try CommandRunner.run(executable, arguments: [
            "--host", endpoint, "system", "df", "--format", "{{json .}}"
        ], timeout: 20, captureOutput: true, environment: environment)
        return DockerStorageSnapshot(context: context, rows: try parse(output))
    }

    static func parse(_ output: String) throws -> [DockerStorageSnapshot.Row] {
        let decoder = JSONDecoder()
        let rows = try output.split(whereSeparator: \.isNewline).map {
            try decoder.decode(DockerStorageSnapshot.Row.self, from: Data($0.utf8))
        }
        guard !rows.isEmpty else { throw Failure.emptyOutput }
        return rows
    }

    private enum Failure: LocalizedError {
        case cliNotFound
        case missingContext
        case nonLocalContext(String)
        case emptyOutput

        var errorDescription: String? {
            switch self {
            case .cliNotFound: return "Docker CLI was not found. Open Docker Desktop or start your local Docker runtime, then refresh."
            case .missingContext: return "Docker has no active context."
            case .nonLocalContext(let name): return "The Docker context “\(name)” is remote. Select a local Docker context and refresh."
            case .emptyOutput: return "Docker returned no storage information."
            }
        }
    }
}
