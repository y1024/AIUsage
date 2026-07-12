import Foundation

nonisolated struct CLIProxyManagementClient: Sendable {
    private struct FilesResponse: Decodable { let files: [CLIProxyAuthFile] }
    private struct ModelsResponse: Decodable { let models: [CLIProxyModel] }
    private struct APIErrorResponse: Decodable { let error: String? }

    let baseURL: URL
    let managementKey: String
    let clientAPIKey: String
    var session: URLSession = .shared

    func listAuthFiles() async throws -> [CLIProxyAuthFile] {
        let response: FilesResponse = try await request(method: "GET", path: "v0/management/auth-files")
        return response.files
    }

    func models(forAuthFile name: String) async throws -> [CLIProxyModel] {
        let response: ModelsResponse = try await request(
            method: "GET",
            path: "v0/management/auth-files/models",
            query: [URLQueryItem(name: "name", value: name)]
        )
        return response.models
    }

    func availableModels() async throws -> [CLIProxyModel] {
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/models"), timeoutInterval: 15)
        request.setValue("Bearer \(clientAPIKey)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
        struct List: Decodable { let data: [CLIProxyModel] }
        return try decode(List.self, from: data).data
    }

    func setDisabled(_ disabled: Bool, name: String) async throws {
        let body = try JSONEncoder().encode([
            "name": AnyCodable.string(name),
            "disabled": AnyCodable.bool(disabled)
        ])
        let _: EmptyResponse = try await request(
            method: "PATCH",
            path: "v0/management/auth-files/status",
            body: body
        )
    }

    func deleteAuthFile(name: String) async throws {
        let _: EmptyResponse = try await request(
            method: "DELETE",
            path: "v0/management/auth-files",
            query: [URLQueryItem(name: "name", value: name)]
        )
    }

    func uploadAuthFile(data: Data, name: String) async throws {
        guard name.lowercased().hasSuffix(".json"),
              name == URL(fileURLWithPath: name).lastPathComponent else {
            throw CLIProxyGatewayError.configuration("invalid auth file name")
        }
        let _: EmptyResponse = try await request(
            method: "POST",
            path: "v0/management/auth-files",
            query: [URLQueryItem(name: "name", value: name)],
            body: data
        )
    }

    func beginOAuth(_ provider: CLIProxyOAuthProvider) async throws -> CLIProxyOAuthSession {
        try await request(
            method: "GET",
            path: "v0/management/\(provider.endpoint)",
            query: [URLQueryItem(name: "is_webui", value: "true")]
        )
    }

    func oauthStatus(state: String) async throws -> CLIProxyOAuthStatus {
        try await request(
            method: "GET",
            path: "v0/management/get-auth-status",
            query: [URLQueryItem(name: "state", value: state)]
        )
    }

    func cancelOAuth(state: String) async throws {
        let _: EmptyResponse = try await request(
            method: "DELETE",
            path: "v0/management/oauth-session",
            query: [URLQueryItem(name: "state", value: state)]
        )
    }

    private func request<T: Decodable>(
        method: String,
        path: String,
        query: [URLQueryItem] = [],
        headers: [String: String] = [:],
        body: Data? = nil
    ) async throws -> T {
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw CLIProxyGatewayError.configuration("invalid Management API URL") }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("Bearer \(managementKey)", forHTTPHeaderField: "Authorization")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        do {
            let (data, response) = try await session.data(for: request)
            try validate(response: response, data: data)
            if T.self == EmptyResponse.self, data.isEmpty {
                return EmptyResponse() as! T
            }
            return try decode(T.self, from: data)
        } catch let error as CLIProxyGatewayError {
            throw error
        } catch {
            throw CLIProxyGatewayError.network(error.localizedDescription)
        }
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw CLIProxyGatewayError.invalidResponse("missing HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONDecoder().decode(APIErrorResponse.self, from: data).error)
                ?? String(data: data, encoding: .utf8)
                ?? "unknown error"
            throw CLIProxyGatewayError.managementAPI(http.statusCode, message)
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        if T.self == EmptyResponse.self { return EmptyResponse() as! T }
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw CLIProxyGatewayError.invalidResponse(error.localizedDescription) }
    }
}

nonisolated private struct EmptyResponse: Decodable { init() {} }

/// Small Codable bridge used only for a two-field JSON request body.
nonisolated private enum AnyCodable: Codable {
    case string(String)
    case bool(Bool)

    init(_ value: String) { self = .string(value) }
    init(_ value: Bool) { self = .bool(value) }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Bool.self) { self = .bool(value); return }
        self = .string(try container.decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        }
    }
}
