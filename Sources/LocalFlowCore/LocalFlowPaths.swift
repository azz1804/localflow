import Foundation

public enum LocalFlowPaths {
    public static let applicationName = "LocalFlow"

    public static var appSupportDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent(applicationName, isDirectory: true)
    }

    public static func ensureAppSupportDirectory() throws -> URL {
        let directory = appSupportDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    public static func envCandidates(bundleResourceURL: URL?, currentDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)) -> [URL] {
        var candidates: [URL] = []

        if let explicitPath = ProcessInfo.processInfo.environment["LOCALFLOW_ENV"], !explicitPath.isEmpty {
            candidates.append(URL(fileURLWithPath: explicitPath).standardizedFileURL)
        }

        candidates.append(appSupportDirectory.appendingPathComponent(".env"))
        candidates.append(currentDirectory.appendingPathComponent(".env"))

        if let bundleResourceURL {
            candidates.append(bundleResourceURL.appendingPathComponent(".env"))
        }

        return unique(candidates)
    }

    public static func dictionaryCandidates(bundleResourceURL: URL?, currentDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)) -> [URL] {
        var candidates: [URL] = []

        if let explicitPath = ProcessInfo.processInfo.environment["LOCALFLOW_DICTIONARY"], !explicitPath.isEmpty {
            candidates.append(URL(fileURLWithPath: explicitPath).standardizedFileURL)
        }

        candidates.append(appSupportDirectory.appendingPathComponent("dictionary.json"))
        candidates.append(currentDirectory.appendingPathComponent("Config/dictionary.json"))

        if let bundleResourceURL {
            candidates.append(bundleResourceURL.appendingPathComponent("dictionary.json"))
        }

        return unique(candidates)
    }

    public static func historyURL() throws -> URL {
        try ensureAppSupportDirectory().appendingPathComponent("history.jsonl")
    }

    private static func unique(_ urls: [URL]) -> [URL] {
        var seen: Set<String> = []
        var result: [URL] = []

        for url in urls {
            let path = url.standardizedFileURL.path
            if !seen.contains(path) {
                seen.insert(path)
                result.append(url)
            }
        }

        return result
    }
}
