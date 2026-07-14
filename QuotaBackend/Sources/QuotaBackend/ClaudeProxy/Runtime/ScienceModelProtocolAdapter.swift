import Foundation

/// The single compatibility boundary between an AIUsage node catalog and the
/// model protocol understood by Claude Science.
///
/// Raw upstream IDs stay in `upstreamModel`; only `id` is sent back by Science
/// in requests, and only `displayName` contains presentation workarounds.
public struct ScienceModelProtocolAdapter: Sendable {
    public struct Model: Sendable, Equatable {
        public let id: String
        public let upstreamModel: String
        public let displayName: String
    }

    /// Science wrote this built-in selection ID into existing session frames.
    /// Keeping it as the one default selection identity avoids mutating history
    /// or publishing a duplicate compatibility row.
    static let persistentDefaultSelectionID = "claude-opus-4-8"

    /// Some Science releases accept only Claude-shaped model IDs.
    static let generatedIDPrefix = "claude-aiusage-v1-"

    /// Prevents Science's display-only `Internal` heuristic from matching.
    /// It must never be used as an upstream model ID.
    static let presentationGuard = "\u{2060}"

    public let models: [Model]
    public let defaultModelID: String?
    public let defaultUpstreamModel: String?

    private let upstreamBySelectionID: [String: String]
    private let upstreamModels: Set<String>

    public init(upstreamModels: [String], requestedDefault: String?) {
        let normalized = Self.normalize(upstreamModels)
        let requested = requestedDefault?.trimmingCharacters(in: .whitespacesAndNewlines)
        let preferred = requested.flatMap { normalized.contains($0) ? $0 : nil }
            ?? normalized.first

        var routing: [String: String] = [:]
        self.models = normalized.map { upstream in
            let id = upstream == preferred
                ? Self.persistentDefaultSelectionID
                : Self.generatedSelectionID(for: upstream)
            routing[id] = upstream
            return Model(
                id: id,
                upstreamModel: upstream,
                displayName: Self.presentationName(for: upstream)
            )
        }
        self.defaultModelID = preferred == nil ? nil : Self.persistentDefaultSelectionID
        self.defaultUpstreamModel = preferred
        self.upstreamBySelectionID = routing
        self.upstreamModels = Set(normalized)
    }

    /// Resolves live picker selections, optionally accepted raw catalog IDs,
    /// and generated selections retained after a node switch, in that order.
    /// Legacy Claude family IDs are deliberately left to the caller's normal
    /// routing policy.
    public func resolveRequestModel(
        _ requestModel: String,
        acceptingRawUpstreamIDs: Bool
    ) -> String? {
        if let upstream = upstreamBySelectionID[requestModel] {
            return upstream
        }
        if acceptingRawUpstreamIDs, upstreamModels.contains(requestModel) {
            return requestModel
        }
        if requestModel.hasPrefix(Self.generatedIDPrefix) {
            return defaultUpstreamModel
        }
        return nil
    }

    static func normalize(_ models: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        result.reserveCapacity(min(models.count, 1_000))

        for raw in models {
            let model = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !model.isEmpty,
                  model.utf8.count <= 512,
                  !model.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                  seen.insert(model).inserted else { continue }
            result.append(model)
            if result.count == 1_000 { break }
        }
        return result
    }

    static func generatedSelectionID(for upstreamModel: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in upstreamModel.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }

        var slug = ""
        var previousWasDash = false
        for scalar in upstreamModel.lowercased().unicodeScalars {
            let isASCIIAlphaNumeric = (48...57).contains(scalar.value)
                || (97...122).contains(scalar.value)
            if isASCIIAlphaNumeric {
                slug.unicodeScalars.append(scalar)
                previousWasDash = false
            } else if !previousWasDash, !slug.isEmpty {
                slug.append("-")
                previousWasDash = true
            }
            if slug.utf8.count >= 40 { break }
        }
        slug = slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if slug.isEmpty { slug = "model" }
        return "\(generatedIDPrefix)\(slug)-\(String(hash, radix: 16))"
    }

    static func presentationName(for upstreamModel: String) -> String {
        presentationNameNeedsGuard(upstreamModel)
            ? presentationGuard + upstreamModel
            : upstreamModel
    }

    static func presentationNameNeedsGuard(_ upstreamModel: String) -> Bool {
        if wouldBeMaskedByScience(upstreamModel) { return true }
        if let range = upstreamModel.range(
            of: #"^Claude\s+"#,
            options: [.regularExpression, .caseInsensitive]
        ) {
            return wouldBeMaskedByScience(String(upstreamModel[range.upperBound...]))
        }
        return false
    }

    private static func wouldBeMaskedByScience(_ value: String) -> Bool {
        if let first = value.unicodeScalars.first,
           !first.isASCII,
           first.properties.isEmoji {
            return true
        }

        let segments = value.split(separator: "-", omittingEmptySubsequences: false)
        guard segments.count >= 2,
              let firstByte = segments[0].utf8.first,
              (97...122).contains(firstByte) else {
            return false
        }
        return segments.allSatisfy { segment in
            !segment.isEmpty && segment.utf8.allSatisfy { byte in
                (97...122).contains(byte) || (48...57).contains(byte)
            }
        }
    }
}
