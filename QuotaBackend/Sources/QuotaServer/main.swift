import Foundation
import os.log
import QuotaBackend
import QuotaServerCore

private let startupLog = Logger(subsystem: "com.aiusage.quotaserver", category: "Startup")

setbuf(stdout, nil)
setbuf(stderr, nil)

// MARK: - QuotaServer Entry Point
// Usage: swift run QuotaServer [--port 4318] [--host 0.0.0.0]
//
// Claude Code Proxy (optional):
//   Set environment variables to enable proxy:
//     OPENAI_API_KEY=sk-xxx       (required)
//     OPENAI_BASE_URL=https://... (optional, defaults to https://api.openai.com)
//     OPENAI_API_MODE=chat_completions|responses (optional, defaults to chat_completions)
//     BIG_MODEL=gpt-4o            (optional, maps to opus)
//     MIDDLE_MODEL=gpt-4o         (optional, maps to sonnet)
//     SMALL_MODEL=gpt-4o-mini     (optional, maps to haiku)
//     ANTHROPIC_API_KEY=sk-ant-.. (optional, for client auth)
//
//   Then use Claude Code with:
//     ANTHROPIC_BASE_URL=http://127.0.0.1:4318 claude

let args = parseArgs()
let host = args["host"] ?? "127.0.0.1"
let port = Int(args["port"] ?? "4318") ?? 4318

startupLog.info("QuotaServer starting on \(host):\(port)")

// Load proxy configuration from environment
let proxyConfig = ClaudeProxyConfiguration.loadFromEnvironment()

if let cfg = proxyConfig {
    let modeStr = cfg.mode == .anthropicPassthrough ? "passthrough" : "openai-convert"
    let apiStr = cfg.mode == .openaiConvert ? cfg.openAIUpstreamAPI.rawValue : "n/a"
    startupLog.info("Claude Code Proxy: enabled (mode=\(modeStr), upstream_api=\(apiStr), upstream=\(cfg.upstreamBaseURL, privacy: .private))")
} else {
    startupLog.info("Claude Code Proxy: disabled")
}

var httpsConfig: HTTPSConfig?
if ProcessInfo.processInfo.environment["ENABLE_HTTPS"] == "1",
   let tlsPath = ProcessInfo.processInfo.environment["TLS_IDENTITY_PATH"] {
    let httpsPort = Int(ProcessInfo.processInfo.environment["HTTPS_PORT"] ?? "") ?? (port + 1)
    httpsConfig = HTTPSConfig(port: httpsPort, identityPath: tlsPath)
    startupLog.info("HTTPS: enabled on port \(httpsPort)")
}

let server = QuotaHTTPServer(host: host, port: port, proxyConfig: proxyConfig, httpsConfig: httpsConfig)
try await server.run()

private func parseArgs() -> [String: String] {
    var result: [String: String] = [:]
    let args = CommandLine.arguments.dropFirst()
    var index = args.startIndex

    while index < args.endIndex {
        let arg = args[index]
        if arg.hasPrefix("--") {
            let key = String(arg.dropFirst(2))
            let nextIndex = args.index(after: index)
            if nextIndex < args.endIndex && !args[nextIndex].hasPrefix("--") {
                result[key] = args[nextIndex]
                index = args.index(after: nextIndex)
                continue
            }
        }
        index = args.index(after: index)
    }

    return result
}
