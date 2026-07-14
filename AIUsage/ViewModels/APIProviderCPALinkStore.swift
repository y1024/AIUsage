import Foundation
import Combine
import os.log

// MARK: - API Provider ↔ CPA Link Store
// 记录「API 提供商」分发到 CPA OpenAI 兼容上游时的 name 映射。
// CPA 上游条目以 name 标识，无 linkedProviderId 字段，故本地持久化 providerId → cpaName。
// 路径: ~/.config/aiusage/api-provider-cpa-links.json

private let apiProviderCPALinkLog = Logger(subsystem: "com.aiusage.desktop", category: "APIProviderCPALinkStore")

@MainActor
final class APIProviderCPALinkStore: ObservableObject {
    static let shared = APIProviderCPALinkStore()

    /// providerId → CPA openai-compatibility provider name
    @Published private(set) var links: [String: String] = [:]

    private let fileManager = FileManager.default

    private struct StoreFile: Codable {
        var version: Int
        var links: [String: String]
    }

    private static let storeVersion = 1

    static var storePath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return (home as NSString).appendingPathComponent(".config/aiusage/api-provider-cpa-links.json")
    }

    init() {
        load()
    }

    func cpaName(for providerId: String) -> String? {
        links[providerId]
    }

    func hasLink(for providerId: String) -> Bool {
        links[providerId] != nil
    }

    func setLink(providerId: String, cpaName: String) {
        let trimmed = cpaName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !providerId.isEmpty, !trimmed.isEmpty else { return }
        links[providerId] = trimmed
        save()
    }

    func removeLink(providerId: String) {
        guard links.removeValue(forKey: providerId) != nil else { return }
        save()
    }

    // MARK: - Persistence

    private func load() {
        guard let data = fileManager.contents(atPath: Self.storePath) else { return }
        do {
            let file = try JSONDecoder().decode(StoreFile.self, from: data)
            links = file.links
        } catch {
            apiProviderCPALinkLog.error("Failed to load CPA links: \(String(describing: error), privacy: .public)")
        }
    }

    private func save() {
        let file = StoreFile(version: Self.storeVersion, links: links)
        do {
            let dir = (Self.storePath as NSString).deletingLastPathComponent
            try fileManager.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(file)
            try data.write(to: URL(fileURLWithPath: Self.storePath), options: .atomic)
            try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.storePath)
        } catch {
            apiProviderCPALinkLog.error("Failed to save CPA links: \(String(describing: error), privacy: .public)")
        }
    }
}
