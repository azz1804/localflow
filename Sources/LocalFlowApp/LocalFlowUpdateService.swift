import Foundation

struct LocalFlowAvailableUpdate: Equatable, Sendable {
    let commit: String

    var shortCommit: String {
        String(commit.prefix(7))
    }
}

enum LocalFlowUpdatePresentation: Equatable, Sendable {
    case hidden
    case available(LocalFlowAvailableUpdate)
    case installing(LocalFlowAvailableUpdate)
    case failed(LocalFlowAvailableUpdate, message: String)

    var update: LocalFlowAvailableUpdate? {
        switch self {
        case .hidden:
            return nil
        case let .available(update),
             let .installing(update),
             let .failed(update, _):
            return update
        }
    }
}

struct LocalFlowUpdateService: Sendable {
    let repository: String
    let branch: String

    init(
        repository: String = "azz1804/localflow",
        branch: String = "main"
    ) {
        self.repository = repository
        self.branch = branch
    }

    func availableUpdate(
        installedCommit: String,
        session: URLSession = .shared
    ) async throws -> LocalFlowAvailableUpdate? {
        guard Self.isComparableCommit(installedCommit) else {
            throw LocalFlowUpdateError.installedVersionUnavailable
        }

        guard let encodedBranch = branch.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed
        ),
        let url = URL(
            string: "https://api.github.com/repos/\(repository)/commits/\(encodedBranch)"
        ) else {
            throw LocalFlowUpdateError.invalidEndpoint
        }

        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 12
        )
        request.setValue(
            "application/vnd.github+json",
            forHTTPHeaderField: "Accept"
        )
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("LocalFlow-Update-Checker", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw LocalFlowUpdateError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw LocalFlowUpdateError.httpStatus(httpResponse.statusCode)
        }

        let release = try JSONDecoder().decode(
            GitHubCommitResponse.self,
            from: data
        )
        guard Self.isComparableCommit(release.sha) else {
            throw LocalFlowUpdateError.invalidResponse
        }

        if Self.commitsMatch(installedCommit, release.sha) {
            return nil
        }
        return LocalFlowAvailableUpdate(commit: release.sha.lowercased())
    }

    func downloadInstaller(
        for update: LocalFlowAvailableUpdate,
        destinationDirectory: URL,
        session: URLSession = .shared
    ) async throws -> URL {
        guard Self.isFullCommit(update.commit),
              let url = URL(
                string: "https://raw.githubusercontent.com/\(repository)/\(update.commit)/install.sh"
              ) else {
            throw LocalFlowUpdateError.invalidInstaller
        }

        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 20
        )
        request.setValue("LocalFlow-Updater", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw LocalFlowUpdateError.installerDownloadFailed
        }

        let script = String(decoding: data, as: UTF8.self)
        guard script.hasPrefix("#!/usr/bin/env bash"),
              script.contains("LocalFlow"),
              script.contains("LOCALFLOW_REPOSITORY") else {
            throw LocalFlowUpdateError.invalidInstaller
        }

        try FileManager.default.createDirectory(
            at: destinationDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let installerURL = destinationDirectory.appendingPathComponent(
            "install-\(update.shortCommit).sh"
        )
        try data.write(to: installerURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: installerURL.path
        )
        return installerURL
    }

    static func commitsMatch(_ lhs: String, _ rhs: String) -> Bool {
        let left = normalizedCommit(lhs)
        let right = normalizedCommit(rhs)
        guard isComparableCommit(left), isComparableCommit(right) else {
            return false
        }
        return left.hasPrefix(right) || right.hasPrefix(left)
    }

    static func isComparableCommit(_ value: String) -> Bool {
        let normalized = normalizedCommit(value)
        guard (7...40).contains(normalized.count) else {
            return false
        }
        return normalized.allSatisfy { $0.isHexDigit }
    }

    private static func isFullCommit(_ value: String) -> Bool {
        let normalized = normalizedCommit(value)
        return normalized.count == 40
            && normalized.allSatisfy { $0.isHexDigit }
    }

    private static func normalizedCommit(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-dirty", with: "")
    }
}

private struct GitHubCommitResponse: Decodable {
    let sha: String
}

enum LocalFlowUpdateError: LocalizedError, Equatable {
    case installedVersionUnavailable
    case invalidEndpoint
    case invalidResponse
    case httpStatus(Int)
    case installerDownloadFailed
    case invalidInstaller
    case launchFailed

    var errorDescription: String? {
        switch self {
        case .installedVersionUnavailable:
            return "La version installée de LocalFlow ne peut pas être identifiée."
        case .invalidEndpoint, .invalidResponse:
            return "LocalFlow n’a pas pu vérifier la dernière version."
        case let .httpStatus(status):
            return "La vérification de la mise à jour a échoué (HTTP \(status))."
        case .installerDownloadFailed:
            return "Le programme de mise à jour n’a pas pu être téléchargé."
        case .invalidInstaller:
            return "Le programme de mise à jour reçu n’est pas valide."
        case .launchFailed:
            return "La mise à jour n’a pas pu démarrer."
        }
    }
}
