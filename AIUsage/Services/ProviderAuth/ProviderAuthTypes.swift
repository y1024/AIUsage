import Foundation
import QuotaBackend

struct ProviderAuthPlan {
    let titleEn: String
    let titleZh: String
    let summaryEn: String
    let summaryZh: String
    let launchActions: [ProviderAuthLaunchAction]
    let supportsEmbeddedWebLogin: Bool
}

struct ProviderAuthLaunchAction: Identifiable, Hashable {
    enum Kind: Hashable {
        case openApp(bundleIdentifier: String)
        case openURL(URL)
        case revealPath(String)
        case runTerminal(command: String)
    }

    let id: String
    let titleEn: String
    let titleZh: String
    let subtitleEn: String
    let subtitleZh: String
    let kind: Kind

    func title(for language: String) -> String {
        language == "zh" ? titleZh : titleEn
    }

    func subtitle(for language: String) -> String {
        language == "zh" ? subtitleZh : subtitleEn
    }
}

struct ProviderAuthCandidate: Identifiable, Hashable {
    enum IdentityScope: String, Hashable {
        case accountScoped
        case sharedSource
    }

    let id: String
    let providerId: String
    let sourceIdentifier: String
    let sessionFingerprint: String?
    let title: String
    let subtitle: String?
    let detail: String
    let modifiedAt: Date?
    let authMethod: AuthMethod
    let credentialValue: String
    let sourcePath: String?
    let shouldCopyFile: Bool
    let identityScope: IdentityScope
}

struct ProviderMonitoredSessionIndex {
    let sourceIdentifiers: Set<String>
    let sessionFingerprints: Set<String>
    let accountHandles: Set<String>
}
