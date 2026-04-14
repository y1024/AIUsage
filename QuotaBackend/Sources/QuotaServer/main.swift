import Foundation
import os.log
import QuotaBackend

private let startupLog = Logger(subsystem: "com.aiusage.quotaserver", category: "Startup")

setbuf(stdout, nil)
setbuf(stderr, nil)

// MARK: - QuotaServer Entry Point
// Usage: swift run QuotaServer [--port 4318] [--host 0.0.0.0]
//
// Claude Code Proxy (optional):
//   Set environment variables to enable proxy:
//     OPENAI_API_KEY=sk-xxx       (required)
//     OPENAI_BASE_URL=https://... (optional, defaults to OpenAI)
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
    startupLog.info("Claude Code Proxy: enabled (mode=\(modeStr), upstream=\(cfg.upstreamBaseURL, privacy: .private))")
} else {
    startupLog.info("Claude Code Proxy: disabled")
}

let server = QuotaHTTPServer(host: host, port: port, proxyConfig: proxyConfig)
try await server.run()
