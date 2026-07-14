import Foundation
import os.log

// MARK: - QuotaServer Executable Discovery
// 只负责回答「有哪些可执行候选、能否按需构建」；统一冷启动（spawn/健康/诊断分类）
// 见 QuotaServerLauncher.swift。

private let locatorLog = Logger(subsystem: "com.aiusage.desktop", category: "QuotaServerLocator")

/// QuotaServer 的来源会影响候选顺序，但不会影响代理协议。
/// Debug 始终优先源码树，Release 始终优先 App 内已签名的 nested helper。
struct QuotaServerExecutable: Equatable {
    enum Origin: String {
        case sourceDebug = "source-debug"
        case bundledHelper = "bundle-helper"
        case onDemandBuild = "on-demand-build"
    }

    let path: String
    let origin: Origin
}

enum QuotaServerLocator {
    private static let sourceFileDir: String = {
        (#filePath as NSString).deletingLastPathComponent
    }()

    private static var projectRootFromSource: String {
        let sourceProjectRoot = (sourceFileDir as NSString).deletingLastPathComponent
        return (sourceProjectRoot as NSString).deletingLastPathComponent
    }

    private static var packageRootFromSource: String {
        (projectRootFromSource as NSString).appendingPathComponent("QuotaBackend")
    }

    static func availableExecutables(fileManager: FileManager = .default) -> [QuotaServerExecutable] {
        var result: [QuotaServerExecutable] = []

        func append(_ path: String, origin: QuotaServerExecutable.Origin) {
            guard fileManager.isExecutableFile(atPath: path) else { return }
            let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
            guard !result.contains(where: { $0.path == normalized }) else { return }
            result.append(QuotaServerExecutable(path: normalized, origin: origin))
        }

        let sourceDebug = (projectRootFromSource as NSString)
            .appendingPathComponent("QuotaBackend/.build/debug/QuotaServer")
        let nestedHelper = Bundle.main.bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Helpers", isDirectory: true)
            .appendingPathComponent("QuotaServer")
            .path
#if DEBUG
        append(sourceDebug, origin: .sourceDebug)
        append(nestedHelper, origin: .bundledHelper)
#else
        append(nestedHelper, origin: .bundledHelper)
#endif

        return result
    }

    static func buildFallback() async -> QuotaServerExecutable? {
#if DEBUG
        let packageRoot = packageRootFromSource
        guard FileManager.default.fileExists(atPath: packageRoot) else { return nil }

        do {
            guard let path = try await QuotaServerBuilder.shared.buildQuotaServer(
                packageRoot: packageRoot,
                configuration: "debug"
            ) else { return nil }
            return QuotaServerExecutable(path: path, origin: .onDemandBuild)
        } catch {
            locatorLog.error("Failed to build QuotaServer on demand: \(String(describing: error), privacy: .public)")
            return nil
        }
#else
        // Release 只允许运行 App 内经过发布签名与 nested-code 校验的 helper。
        // 绝不从编译机路径执行或在用户机器上临时构建，以免掩盖损坏的发布包。
        return nil
#endif
    }
}

// MARK: - On-Demand Builder

actor QuotaServerBuilder {
    static let shared = QuotaServerBuilder()

    func buildQuotaServer(packageRoot: String, configuration: String) async throws -> String? {
        let buildLog = Logger(subsystem: "com.aiusage.desktop", category: "QuotaServerBuild")
        let executablePath = (packageRoot as NSString)
            .appendingPathComponent(".build/\(configuration)/QuotaServer")
        if FileManager.default.isExecutableFile(atPath: executablePath) {
            return URL(fileURLWithPath: executablePath).standardizedFileURL.path
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = [
            "swift", "build",
            "--package-path", packageRoot,
            "--product", "QuotaServer",
            "-c", configuration,
        ]

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        try process.run()
        // 先持续排空再 wait；否则编译输出超过 pipe 容量时父子进程会互相等待。
        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let output = String(
            data: outputData,
            encoding: .utf8
        ) ?? ""
        guard process.terminationStatus == 0 else {
            buildLog.error(
                "QuotaServer build failed with exit code \(process.terminationStatus, privacy: .public): \(output, privacy: .private)"
            )
            return nil
        }
        guard FileManager.default.isExecutableFile(atPath: executablePath) else { return nil }
        return URL(fileURLWithPath: executablePath).standardizedFileURL.path
    }
}
