// MARK: - Batch Auth File Scanner
// Generic scanner that finds importable auth files in a directory.
// Works with any provider that supports .authFile (Codex, Kiro, Gemini, Antigravity, Droid).

import Foundation
import QuotaBackend

struct ScannedAuthFile: Identifiable, Hashable {
    let id: String
    let fileURL: URL
    let fileName: String
    let detectedEmail: String?
    let modifiedAt: Date?
    let fileSize: Int64
    let providerId: String
}

enum BatchAuthFileScanner {

    static func scanDirectory(at directoryURL: URL, for providerId: String, recursive: Bool = false) -> [ScannedAuthFile] {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: directoryURL.path, isDirectory: &isDir), isDir.boolValue else {
            return []
        }

        let resourceKeys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        var options: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles, .skipsPackageDescendants]
        if !recursive { options.insert(.skipsSubdirectoryDescendants) }

        guard let enumerator = fm.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: Array(resourceKeys),
            options: options
        ) else { return [] }

        var results: [ScannedAuthFile] = []

        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: resourceKeys),
                  values.isRegularFile == true else { continue }

            let ext = fileURL.pathExtension.lowercased()
            guard ext == "json" || isKnownAuthFileName(fileURL.lastPathComponent, for: providerId) else { continue }

            guard let email = quickExtractEmail(from: fileURL, for: providerId) else { continue }

            let size = Int64(values.fileSize ?? 0)
            let modified = values.contentModificationDate

            results.append(ScannedAuthFile(
                id: fileURL.absoluteString,
                fileURL: fileURL,
                fileName: fileURL.lastPathComponent,
                detectedEmail: email.nilIfBlank,
                modifiedAt: modified,
                fileSize: size,
                providerId: providerId
            ))
        }

        return results.sorted { ($0.modifiedAt ?? .distantPast) > ($1.modifiedAt ?? .distantPast) }
    }

    static func scanFiles(_ fileURLs: [URL], for providerId: String) -> [ScannedAuthFile] {
        fileURLs.compactMap { fileURL in
            guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
            guard let email = quickExtractEmail(from: fileURL, for: providerId) else { return nil }

            let values = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            return ScannedAuthFile(
                id: fileURL.absoluteString,
                fileURL: fileURL,
                fileName: fileURL.lastPathComponent,
                detectedEmail: email.nilIfBlank,
                modifiedAt: values?.contentModificationDate,
                fileSize: Int64(values?.fileSize ?? 0),
                providerId: providerId
            )
        }
    }

    static let authFileProviderIds: Set<String> = ["codex", "kiro", "gemini", "antigravity"]

    // MARK: - Quick Parse

    private static func quickExtractEmail(from fileURL: URL, for providerId: String) -> String? {
        guard let data = try? Data(contentsOf: fileURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        switch providerId {
        case "codex":
            return codexEmailFromJSON(json)
        case "kiro":
            return kiroEmailFromJSON(json)
        case "gemini":
            return geminiEmailFromJSON(json)
        case "antigravity":
            return antigravityEmailFromJSON(json)
        case "droid":
            return droidEmailFromJSON(json)
        default:
            return genericEmailFromJSON(json)
        }
    }

    private static func codexEmailFromJSON(_ json: [String: Any]) -> String? {
        let tokens = json["tokens"] as? [String: Any]
        if let idToken = str(tokens?["id_token"]) ?? str(json["id_token"]) {
            if let email = ProviderAuthManager.jwtEmail(from: idToken) { return email }
        }
        return str(json["email"])
            ?? str(json["accountEmail"])
            ?? (tokens != nil || json["access_token"] != nil ? "ChatGPT Login" : nil)
    }

    private static func kiroEmailFromJSON(_ json: [String: Any]) -> String? {
        str(json["email"])
            ?? str(json["accountEmail"])
            ?? str(json["userEmail"])
            ?? (str(json["access_token"]) != nil || str(json["accessToken"]) != nil ? "Kiro Account" : nil)
    }

    private static func geminiEmailFromJSON(_ json: [String: Any]) -> String? {
        str(json["email"])
            ?? str(json["client_email"])
            ?? ProviderAuthManager.jwtEmail(from: str(json["id_token"]))
            ?? (str(json["refresh_token"]) != nil ? "Gemini Login" : nil)
    }

    private static func antigravityEmailFromJSON(_ json: [String: Any]) -> String? {
        str(json["email"])
            ?? ProviderAuthManager.jwtEmail(from: str(json["access_token"]))
            ?? (str(json["refresh_token"]) != nil ? "Antigravity Login" : nil)
    }

    private static func droidEmailFromJSON(_ json: [String: Any]) -> String? {
        let token = str(json["accessToken"]) ?? str(json["access_token"])
        return ProviderAuthManager.jwtEmail(from: token)
            ?? str(json["email"])
            ?? (token != nil || str(json["refreshToken"]) != nil ? "Droid Login" : nil)
    }

    private static func genericEmailFromJSON(_ json: [String: Any]) -> String? {
        str(json["email"])
            ?? str(json["accountEmail"])
            ?? ProviderAuthManager.jwtEmail(from: str(json["id_token"]))
            ?? ProviderAuthManager.jwtEmail(from: str(json["access_token"]))
    }

    private static func isKnownAuthFileName(_ name: String, for providerId: String) -> Bool {
        let lower = name.lowercased()
        switch providerId {
        case "codex": return lower == "auth.json"
        case "droid": return lower.hasPrefix("auth") && (lower.hasSuffix(".json") || lower.contains(".v2."))
        default: return lower.hasSuffix(".json")
        }
    }

    private static func str(_ value: Any?) -> String? {
        guard let s = value as? String else { return nil }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
