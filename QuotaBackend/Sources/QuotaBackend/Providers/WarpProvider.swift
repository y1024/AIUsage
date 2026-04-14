import Foundation

// MARK: - Warp Provider
// 优先从 macOS NSUserDefaults (app cache) 读取，无需 API key
// 数据来源: dev.warp.Warp-Stable / Warp-Preview / Warp-Nightly defaults

public struct WarpProvider: ProviderFetcher {
    public let id = "warp"
    public let displayName = "Warp"
    public let description = "Warp terminal AI request quota"

    static let domains = ["dev.warp.Warp-Stable", "dev.warp.Warp-Preview", "dev.warp.Warp-Nightly"]

    public init() {}

    public func fetchUsage() async throws -> ProviderUsage {
        // Try each Warp domain variant
        for domain in Self.domains {
            if let result = try? await fetchFromDomain(domain) {
                return result
            }
        }
        throw ProviderError("not_found", "Warp app data not found. Make sure Warp is installed and has been used at least once.")
    }

    private func fetchFromDomain(_ domain: String) async throws -> ProviderUsage {
        guard let limitInfo = readDefaultsJSON(domain: domain, key: "AIRequestLimitInfo") else {
            throw ProviderError("not_found", "No AIRequestLimitInfo in \(domain)")
        }

        let assistantInfo = readDefaultsJSON(domain: domain, key: "AIAssistantRequestLimitInfo")
        let quotaInfo = readDefaultsJSON(domain: domain, key: "AIRequestQuotaInfoSetting")
        let email = readKeychainEmail(domain: domain)

        var usage = ProviderUsage(provider: "warp", label: "Warp")
        usage.accountEmail = email

        var source = SourceInfo(mode: "auto", type: "app-cache")
        source.defaultsDomain = domain
        usage.source = source

        // Parse main request limit
        let primary = parseWarpLimitInfo(limitInfo, fallbackResetAt: latestCycleEndDate(quotaInfo))
        usage.primary = primary

        // Parse assistant limit
        if let assistantInfo {
            usage.secondary = parseWarpLimitInfo(assistantInfo, fallbackResetAt: nil)
        }

        // Extra fields for normalizer
        let requestsUsed = primary.usedPercent.map { Int($0 / 100.0 * Double(extra_limit(limitInfo))) } ?? intField(limitInfo, "num_requests_used_since_refresh")
        let requestLimit = extra_limit(limitInfo)
        let isUnlimited = boolField(limitInfo, "is_unlimited")

        var extra: [String: AnyCodable] = [:]
        extra["requestsUsed"]    = AnyCodable(requestsUsed ?? 0)
        extra["requestLimit"]    = AnyCodable(requestLimit)
        extra["requestsRemaining"] = AnyCodable(isUnlimited ? 0 : max(0, requestLimit - (requestsUsed ?? 0)))
        extra["isUnlimited"]     = AnyCodable(isUnlimited)
        extra["bonusCreditsRemaining"] = AnyCodable(0)
        extra["bonusCreditsTotal"]     = AnyCodable(0)

        if let assistantInfo {
            let aUsed = intField(assistantInfo, "num_requests_used_since_refresh") ?? 0
            extra["assistantRequestsUsed"] = AnyCodable(aUsed)
        }

        usage.extra = extra
        return usage
    }

    // MARK: - Defaults reading

    private func readDefaultsJSON(domain: String, key: String) -> [String: Any]? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        task.arguments = ["read", domain, key]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()

        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            return nil
        }

        guard task.terminationStatus == 0 else { return nil }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }

        // `defaults read` outputs property list format, try JSON first then plist
        if let jsonData = text.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
            return json
        }

        // Fall back to plist parsing
        if let plistData = text.data(using: .utf8),
           let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any] {
            return plist
        }

        return nil
    }

    private func readKeychainEmail(domain: String) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        task.arguments = ["find-generic-password", "-s", domain, "-a", "User", "-w"]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()

        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            return nil
        }

        guard task.terminationStatus == 0 else { return nil }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty,
              let jsonData = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let email = json["email"] as? String, !email.isEmpty else { return nil }

        return email
    }

    // MARK: - Parsing helpers

    private func parseWarpLimitInfo(_ info: [String: Any], fallbackResetAt: Date?) -> RawQuotaWindow {
        let limit = extra_limit(info)
        let used = intField(info, "num_requests_used_since_refresh") ?? 0
        let isUnlimited = boolField(info, "is_unlimited")
        let nextRefreshRaw = info["next_refresh_time"] as? String
        let nextRefresh = nextRefreshRaw.flatMap { parseDate($0) } ?? fallbackResetAt

        var window = RawQuotaWindow()
        window.unlimited = isUnlimited
        window.entitlement = isUnlimited ? nil : limit
        window.remaining = isUnlimited ? nil : max(0, limit - used)
        window.resetAt = nextRefresh.map { SharedFormatters.iso8601String(from: $0) }

        if isUnlimited {
            window.usedPercent = 0
            window.remainingPercent = 100
            window.resetDescription = "Unlimited"
        } else if limit > 0 {
            let usedPct = min(100.0, max(0.0, Double(used) / Double(limit) * 100.0))
            window.usedPercent = usedPct
            window.remainingPercent = max(0, 100 - usedPct)
            window.resetDescription = nextRefresh.map { formatResetDescription($0, usage: "\(used)/\(limit) credits") }
        }

        return window
    }

    private func latestCycleEndDate(_ quotaInfo: [String: Any]?) -> Date? {
        guard let cycles = quotaInfo?["cycle_history"] as? [[String: Any]] else { return nil }
        return cycles.compactMap { c -> Date? in
            guard let s = c["end_date"] as? String else { return nil }
            return parseDate(s)
        }.max()
    }

    private func extra_limit(_ info: [String: Any]) -> Int {
        intField(info, "limit") ?? 0
    }

    private func intField(_ dict: [String: Any], _ key: String) -> Int? {
        switch dict[key] {
        case let v as Int: return v
        case let v as Double: return Int(v)
        case let v as String: return Int(v)
        default: return nil
        }
    }

    private func boolField(_ dict: [String: Any], _ key: String) -> Bool {
        switch dict[key] {
        case let v as Bool: return v
        case let v as Int: return v != 0
        default: return false
        }
    }

    private func parseDate(_ s: String) -> Date? {
        SharedFormatters.parseISO8601(s)
    }

    private func formatResetDescription(_ date: Date, usage: String?) -> String {
        let day = DateFormat.string(from: date, format: "MMM d")
        let time = DateFormat.string(from: date, format: "h:mma")
        let base = "Resets \(day) at \(time)"
        return usage.map { "\($0), \(base)" } ?? base
    }
}
