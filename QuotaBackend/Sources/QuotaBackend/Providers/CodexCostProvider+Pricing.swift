import Foundation

extension CodexCostProvider {
    struct Pricing {
        let inputPerToken: Double
        let outputPerToken: Double
        let cacheReadPerToken: Double
        let threshold: Int?
        let inputAbove: Double?
        let outputAbove: Double?
        let cacheReadAbove: Double?

        init(
            _ input: Double,
            _ output: Double,
            _ cacheRead: Double,
            threshold: Int? = nil,
            inputAbove: Double? = nil,
            outputAbove: Double? = nil,
            cacheReadAbove: Double? = nil
        ) {
            inputPerToken = input
            outputPerToken = output
            cacheReadPerToken = cacheRead
            self.threshold = threshold
            self.inputAbove = inputAbove
            self.outputAbove = outputAbove
            self.cacheReadAbove = cacheReadAbove
        }
    }

    // OpenAI official API prices per token. Source values are published per
    // million tokens, so each table entry stores the converted per-token rate.
    static let pricing: [String: Pricing] = [
        "gpt-5": Pricing(1.25e-6, 1e-5, 1.25e-7),
        "gpt-5-codex": Pricing(1.25e-6, 1e-5, 1.25e-7),
        "gpt-5-mini": Pricing(2.5e-7, 2e-6, 2.5e-8),
        "gpt-5-nano": Pricing(5e-8, 4e-7, 5e-9),
        "gpt-5-pro": Pricing(1.5e-5, 1.2e-4, 1.5e-5),
        "gpt-5.1": Pricing(1.25e-6, 1e-5, 1.25e-7),
        "gpt-5.1-codex": Pricing(1.25e-6, 1e-5, 1.25e-7),
        "gpt-5.1-codex-max": Pricing(1.25e-6, 1e-5, 1.25e-7),
        "gpt-5.1-codex-mini": Pricing(2.5e-7, 2e-6, 2.5e-8),
        "gpt-5.2": Pricing(1.75e-6, 1.4e-5, 1.75e-7),
        "gpt-5.2-codex": Pricing(1.75e-6, 1.4e-5, 1.75e-7),
        "gpt-5.2-pro": Pricing(2.1e-5, 1.68e-4, 2.1e-5),
        "gpt-5.3-codex": Pricing(1.75e-6, 1.4e-5, 1.75e-7),
        "gpt-5.4": Pricing(2.5e-6, 1.5e-5, 2.5e-7, threshold: 272_000, inputAbove: 5e-6, outputAbove: 2.25e-5, cacheReadAbove: 5e-7),
        "gpt-5.4-mini": Pricing(7.5e-7, 4.5e-6, 7.5e-8),
        "gpt-5.4-nano": Pricing(2e-7, 1.25e-6, 2e-8),
        "gpt-5.4-pro": Pricing(3e-5, 1.8e-4, 3e-5, threshold: 272_000, inputAbove: 6e-5, outputAbove: 2.7e-4, cacheReadAbove: 6e-5),
        "gpt-5.5": Pricing(5e-6, 3e-5, 5e-7, threshold: 272_000, inputAbove: 1e-5, outputAbove: 4.5e-5, cacheReadAbove: 1e-6),
        "gpt-5.5-pro": Pricing(3e-5, 1.8e-4, 3e-5),
        "codex-mini-latest": Pricing(1.5e-6, 6e-6, 3.75e-7)
    ]

    func estimateCost(model: String, input: Int, cacheRead: Int, output: Int) -> Double? {
        guard let p = Self.pricing[model] else { return nil }
        let rawInput = input + cacheRead
        let usesLongContext = p.threshold.map { rawInput > $0 } ?? false
        let inputRate = usesLongContext ? (p.inputAbove ?? p.inputPerToken) : p.inputPerToken
        let cacheRate = usesLongContext ? (p.cacheReadAbove ?? p.cacheReadPerToken) : p.cacheReadPerToken
        let outputRate = usesLongContext ? (p.outputAbove ?? p.outputPerToken) : p.outputPerToken
        return roundUsd(Double(input) * inputRate + Double(cacheRead) * cacheRate + Double(output) * outputRate)
    }

    func pricingCacheSignature() -> String {
        "\(Self.cacheSchemaVersion):\(Self.pricing.keys.sorted().joined(separator: ","))"
    }

    func normalizeModel(_ raw: String) -> String {
        Self.normalizeModelStatic(raw)
    }

    static func normalizeModelStatic(_ raw: String) -> String {
        var model = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if model.hasPrefix("openai/") {
            model = String(model.dropFirst("openai/".count))
        }
        if pricing[model] != nil { return model }
        if let range = model.range(of: #"-\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) {
            let base = String(model[..<range.lowerBound])
            if pricing[base] != nil { return base }
        }
        if let range = model.range(of: #"-\d{8}$"#, options: .regularExpression) {
            let base = String(model[..<range.lowerBound])
            if pricing[base] != nil { return base }
        }
        return model
    }

    // MARK: - Date and misc helpers
}
