import Foundation
import os.log

// MARK: - QuotaServer Locator
// 查找（必要时按需构建）QuotaServer 可执行文件，供各代理运行时共用：
// 1. App bundle 内置 Helpers/QuotaServer（发行版）
// 2. 源码树 QuotaBackend/.build/{debug,release}/QuotaServer（开发版）
// 3. 兜底：调用 swift build 按需构建

private let locatorLog = Logger(subsystem: "com.aiusage.desktop", category: "QuotaServerLocator")

enum QuotaServerLocator {
    private static let sourceFileDir: String = {
        let filePath = #filePath
        return (filePath as NSString).deletingLastPathComponent
    }()

    static func find() async -> String? {
        let fileManager = FileManager.default

        if let bundledExecutable = bundledQuotaServerExecutable(fileManager: fileManager) {
            locatorLog.info("Found bundled QuotaServer at \(bundledExecutable, privacy: .public)")
            return bundledExecutable
        }

        let sourceProjectRoot = (sourceFileDir as NSString).deletingLastPathComponent
        let projectRootFromSource = (sourceProjectRoot as NSString).deletingLastPathComponent

        if let sourceTreeExecutable = sourceTreeQuotaServerExecutable(from: projectRootFromSource, fileManager: fileManager) {
            locatorLog.info("Found QuotaServer in source tree at \(sourceTreeExecutable, privacy: .public)")
            return sourceTreeExecutable
        }

        let packageRoot = (projectRootFromSource as NSString).appendingPathComponent("QuotaBackend")
        if fileManager.fileExists(atPath: packageRoot),
           let builtExecutable = await buildQuotaServerIfNeeded(packageRoot: packageRoot) {
            locatorLog.info("Built QuotaServer on demand at \(builtExecutable, privacy: .public)")
            return builtExecutable
        }

        let bundlePath = Bundle.main.bundlePath
        locatorLog.error(
            """
            QuotaServer executable not found in bundle or expected build outputs.
            sourceFileDir=\(sourceFileDir, privacy: .public)
            bundlePath=\(bundlePath, privacy: .public)
            """
        )
        return nil
    }

    private static func bundledQuotaServerExecutable(fileManager: FileManager) -> String? {
        guard let resourceURL = Bundle.main.resourceURL else { return nil }
        let bundledPath = resourceURL
            .appendingPathComponent("Helpers", isDirectory: true)
            .appendingPathComponent("QuotaServer")
            .path
        return fileManager.fileExists(atPath: bundledPath) ? bundledPath : nil
    }

    private static func sourceTreeQuotaServerExecutable(from projectRoot: String, fileManager: FileManager) -> String? {
        let relativePaths = [
            "QuotaBackend/.build/debug/QuotaServer",
            "QuotaBackend/.build/release/QuotaServer",
        ]

        let candidateRoots = [
            projectRoot,
            Bundle.main.bundlePath,
        ]

        for root in candidateRoots {
            for relPath in relativePaths {
                let fullPath = (root as NSString).appendingPathComponent(relPath)
                if fileManager.fileExists(atPath: fullPath) {
                    return fullPath
                }
            }
        }

        var searchDir = projectRoot
        for _ in 0..<5 {
            for relPath in relativePaths {
                let fullPath = (searchDir as NSString).appendingPathComponent(relPath)
                if fileManager.fileExists(atPath: fullPath) {
                    return fullPath
                }
            }
            searchDir = (searchDir as NSString).deletingLastPathComponent
        }

        return nil
    }

    private static func buildQuotaServerIfNeeded(packageRoot: String) async -> String? {
        let buildConfiguration: String
#if DEBUG
        buildConfiguration = "debug"
#else
        buildConfiguration = "release"
#endif

        do {
            return try await QuotaServerBuilder.shared.buildQuotaServer(
                packageRoot: packageRoot,
                configuration: buildConfiguration
            )
        } catch {
            locatorLog.error("Failed to build QuotaServer on demand: \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}

// MARK: - On-Demand Builder

actor QuotaServerBuilder {
    static let shared = QuotaServerBuilder()

    func buildQuotaServer(packageRoot: String, configuration: String) async throws -> String? {
        let buildLog = Logger(
            subsystem: "com.aiusage.desktop",
            category: "QuotaServerBuild"
        )
        let executablePath = (packageRoot as NSString).appendingPathComponent(".build/\(configuration)/QuotaServer")
        if FileManager.default.fileExists(atPath: executablePath) {
            return executablePath
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = [
            "swift",
            "build",
            "--package-path", packageRoot,
            "--product", "QuotaServer",
            "-c", configuration
        ]

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        try process.run()
        process.waitUntilExit()

        let output = String(
            data: outputPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""

        guard process.terminationStatus == 0 else {
            buildLog.error("QuotaServer build failed with exit code \(process.terminationStatus, privacy: .public): \(output, privacy: .public)")
            return nil
        }

        return FileManager.default.fileExists(atPath: executablePath) ? executablePath : nil
    }
}
