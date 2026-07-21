import Foundation

private enum FixtureFailure: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case .failed(let message): return message
        }
    }
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw FixtureFailure.failed(message) }
}

private func object(_ value: Any?, _ message: String) throws -> [String: Any] {
    guard let value = value as? [String: Any] else {
        throw FixtureFailure.failed(message)
    }
    return value
}

private func array(_ value: Any?, _ message: String) throws -> [Any] {
    guard let value = value as? [Any] else {
        throw FixtureFailure.failed(message)
    }
    return value
}

private struct ClaudeDesktopFixtureRegression {
    private static let fixtureDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("fixtures/claude-desktop", isDirectory: true)

    static func run() throws {
        try testNormalDeploymentConfig()
        try testThirdPartyDeploymentConfig()
        try testMetadataShape()
        try testMappedGatewayProfile()
        try testOfficialProfile()
        try testFixturesContainNoLiveIdentifiersOrSecrets()
        print("Claude Desktop fixture regression checks passed.")
    }

    private static func load(_ name: String) throws -> [String: Any] {
        let url = fixtureDirectory.appendingPathComponent(name)
        let data = try Data(contentsOf: url)
        return try object(
            JSONSerialization.jsonObject(with: data),
            "Fixture \(name) must contain a JSON object"
        )
    }

    private static func testNormalDeploymentConfig() throws {
        let root = try load("normal-1p.json")
        let preferences = try object(root["preferences"], "1P preferences must be an object")
        try expect(preferences["coworkWebSearchEnabled"] as? Bool == true,
                   "1P preference shape changed")
        try expect(root["deploymentMode"] == nil,
                   "A 1P live config may legitimately omit deploymentMode")
    }

    private static func testThirdPartyDeploymentConfig() throws {
        let root = try load("threep-live.json")
        try expect(root["deploymentMode"] as? String == "3p",
                   "3P deployment mode changed")
        _ = try object(root["enterpriseConfig"], "enterpriseConfig must remain an object")
        let preferences = try object(root["preferences"], "3P preferences must be an object")
        let fallback = try object(
            preferences["coworkModelAutoFallbackByAccount"],
            "Account-keyed preferences must remain an object"
        )
        try expect(fallback["<redacted-account-id>"] as? Bool == true,
                   "Account-keyed preference shape changed")
        try expect(root["coworkUserFilesPath"] as? String == "<redacted-user-files-path>",
                   "User files path was not redacted")
    }

    private static func testMetadataShape() throws {
        let root = try load("meta-multiple-profiles.json")
        try expect(root["appliedId"] as? String == "profile-mapped",
                   "Applied profile ID changed")
        let entries = try array(root["entries"], "Profile metadata entries must be an array")
        try expect(entries.count == 3, "Multiple profile entries must be preserved")
        let external = try object(entries[2], "External profile entry must be an object")
        try expect(external["futureField"] as? String == "must-survive",
                   "Unknown profile entry fields must survive a merge")
        try expect(root["futureTopLevelField"] != nil,
                   "Unknown metadata fields must survive a merge")
    }

    private static func testMappedGatewayProfile() throws {
        let root = try load("profile-gateway-mapped.json")
        try expect(root["inferenceProvider"] as? String == "gateway",
                   "Mapped profile provider changed")
        try expect(root["inferenceGatewayApiKey"] as? String == "<redacted-api-key>",
                   "Mapped profile key was not redacted")
        let models = try array(root["inferenceModels"], "inferenceModels must be an array")
        try expect(models.count == 2, "Mapped model fixture must cover optional supports1m")
        let first = try object(models[0], "Mapped model must be an object")
        let second = try object(models[1], "Mapped model must be an object")
        try expect(first["labelOverride"] as? String == "provider/model-large",
                   "Desktop display label shape changed")
        try expect(first["supports1m"] as? Bool == true,
                   "supports1m=true shape changed")
        try expect(second["supports1m"] == nil,
                   "supports1m must remain optional")
        try expect(root["futureProfileField"] != nil,
                   "Unknown profile fields must survive a merge")
    }

    private static func testOfficialProfile() throws {
        let root = try load("profile-official.json")
        try expect(root.count == 1 && root["inferenceProvider"] as? String == "firstParty",
                   "Minimal official profile shape changed")
    }

    private static func testFixturesContainNoLiveIdentifiersOrSecrets() throws {
        let names = [
            "normal-1p.json",
            "threep-live.json",
            "meta-multiple-profiles.json",
            "profile-gateway-mapped.json",
            "profile-official.json",
        ]
        let uuid = try NSRegularExpression(
            pattern: #"\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b"#
        )
        for name in names {
            let text = try String(
                contentsOf: fixtureDirectory.appendingPathComponent(name),
                encoding: .utf8
            )
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            try expect(uuid.firstMatch(in: text, range: range) == nil,
                       "Fixture \(name) contains a UUID-like live identifier")
            try expect(!text.localizedCaseInsensitiveContains("sk-ant-"),
                       "Fixture \(name) contains an Anthropic-style secret")
            try expect(!text.localizedCaseInsensitiveContains("bearer "),
                       "Fixture \(name) contains a bearer value")
        }
    }
}

try ClaudeDesktopFixtureRegression.run()
