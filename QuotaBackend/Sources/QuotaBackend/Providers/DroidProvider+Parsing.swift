import Foundation

// MARK: - Droid Provider — Parsing

extension DroidProvider {
    func parseResponse(authInfo: [String: Any], usageInfo: [String: Any], auth: DroidAuth) -> ProviderUsage {
        let claims = parseJWTClaims(auth.bearerToken ?? "")
        let usageData = usageInfo["usage"] as? [String: Any] ?? [:]
        // /api/app/auth/me 现版返回的是 `userProfile`（旧版/部分场景为 `user`），两者都兜住。
        let userInfo = (authInfo["user"] as? [String: Any]) ?? (authInfo["userProfile"] as? [String: Any])

        let periodStart = parseFactoryDate(usageData["startDate"])
        let periodEnd = parseFactoryDate(usageData["endDate"])
        let resetDesc = periodEnd.map { formatResetDescription($0) } ?? "Reset date unknown"

        let standard = normalizeTokenUsage(usageData["standard"] as? [String: Any])
        let premium = normalizeTokenUsage(usageData["premium"] as? [String: Any])

        var usage = ProviderUsage(provider: "droid", label: "Droid")
        usage.accountEmail = (claims["email"] as? String)
            ?? (userInfo?["email"] as? String)
        usage.usageAccountId = (claims["sub"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? (userInfo?["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? (usageInfo["userId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? usage.accountEmail?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        usage.source = auth.source

        usage.primary = createUsageWindow(standard, periodEnd: periodEnd, resetDesc: resetDesc)
        usage.secondary = createUsageWindow(premium, periodEnd: periodEnd, resetDesc: resetDesc)

        let org = authInfo["organization"] as? [String: Any]
        let subscription = org?["subscription"] as? [String: Any]
        let orbSub = subscription?["orbSubscription"] as? [String: Any]
        // orbSubscription.plan 现为对象（plan.name 形如 "Factory Pro Annual Plan"），旧代码把它
        // 当字符串读会落空；这里补上对象取名，并以 factoryTier（如 team_annual）兜底。
        let orbPlan = orbSub?["plan"] as? [String: Any]
        let planName = (subscription?["planName"] as? String)
            ?? (orbPlan?["name"] as? String)
            ?? (orbSub?["planName"] as? String)
            ?? (orbSub?["name"] as? String)
            ?? (subscription?["factoryTier"] as? String)
            ?? ""

        usage.extra["planName"] = AnyCodable(planName)
        usage.extra["organizationName"] = AnyCodable(org?["name"] as? String ?? "")
        usage.extra["periodStart"] = AnyCodable(periodStart.map { SharedFormatters.iso8601String(from: $0) } ?? "")
        usage.extra["periodEnd"] = AnyCodable(periodEnd.map { SharedFormatters.iso8601String(from: $0) } ?? "")

        usage.extra["standard.userTokens"] = AnyCodable(standard.userTokens)
        usage.extra["standard.totalAllowance"] = AnyCodable(standard.totalAllowance)
        usage.extra["standard.unlimited"] = AnyCodable(standard.unlimited)
        usage.extra["premium.userTokens"] = AnyCodable(premium.userTokens)
        usage.extra["premium.totalAllowance"] = AnyCodable(premium.totalAllowance)
        usage.extra["premium.unlimited"] = AnyCodable(premium.unlimited)

        return usage
    }

    func normalizeTokenUsage(_ value: [String: Any]?) -> TokenUsage {
        guard let value else {
            return TokenUsage(
                userTokens: 0,
                totalAllowance: 0,
                usedPercent: 0,
                remainingPercent: 100,
                unlimited: false
            )
        }

        let userTokens = intValue(value["userTokens"]) ?? 0
        let totalAllowance = intValue(value["totalAllowance"]) ?? 0
        let usedRatio = doubleValue(value["usedRatio"])
        let unlimited = totalAllowance > Self.unlimitedThreshold

        let usedPercent: Double
        if let usedRatio {
            if usedRatio >= -0.001 && usedRatio <= 1.001 {
                usedPercent = min(100, max(0, usedRatio * 100))
            } else if usedRatio >= -0.1 && usedRatio <= 100.1 {
                usedPercent = min(100, max(0, usedRatio))
            } else if totalAllowance > 0 {
                usedPercent = min(100, Double(userTokens) / Double(totalAllowance) * 100)
            } else {
                usedPercent = 0
            }
        } else if totalAllowance > 0 {
            usedPercent = min(100, Double(userTokens) / Double(totalAllowance) * 100)
        } else {
            usedPercent = 0
        }

        return TokenUsage(
            userTokens: userTokens,
            totalAllowance: totalAllowance,
            usedPercent: usedPercent,
            remainingPercent: max(0, 100 - usedPercent),
            unlimited: unlimited
        )
    }

    func createUsageWindow(_ usage: TokenUsage, periodEnd: Date?, resetDesc: String) -> RawQuotaWindow {
        var window = RawQuotaWindow()
        window.usedPercent = usage.usedPercent
        window.remainingPercent = usage.remainingPercent
        window.resetAt = periodEnd.map { SharedFormatters.iso8601String(from: $0) }
        window.resetDescription = resetDesc
        window.unlimited = usage.unlimited
        return window
    }

    func formatResetDescription(_ date: Date) -> String {
        let day = DateFormat.string(from: date, format: "MMM d")
        let time = DateFormat.string(from: date, format: "h:mma")
        return "Resets \(day) at \(time)"
    }

    func parseFactoryDate(_ value: Any?) -> Date? {
        switch value {
        case let number as Int:
            return number > 0 ? Date(timeIntervalSince1970: Double(number) / 1000) : nil
        case let number as Double:
            return number > 0 ? Date(timeIntervalSince1970: number / 1000) : nil
        case let string as String:
            return Double(string).flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0 / 1000) : nil }
        default:
            return nil
        }
    }

    func parseJWTClaims(_ token: String) -> [String: Any] {
        guard token.contains(".") else { return [:] }
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return [:] }

        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = payload.count % 4
        if remainder > 0 {
            payload += String(repeating: "=", count: 4 - remainder)
        }

        guard let data = Data(base64Encoded: payload),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return json
    }

    func firstNonEmpty(_ values: String?...) -> String? {
        values.compactMap { $0.nilIfBlank }.first
    }

    func intValue(_ value: Any?) -> Int? {
        switch value {
        case let number as Int:
            return number
        case let number as Double:
            return Int(number)
        case let string as String:
            return Int(string)
        default:
            return nil
        }
    }

    func doubleValue(_ value: Any?) -> Double? {
        switch value {
        case let number as Double:
            return number
        case let number as Int:
            return Double(number)
        case let string as String:
            return Double(string)
        default:
            return nil
        }
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private extension Optional where Wrapped == String {
    var nilIfBlank: String? {
        switch self {
        case .some(let value):
            return value.nilIfBlank
        case .none:
            return nil
        }
    }
}
