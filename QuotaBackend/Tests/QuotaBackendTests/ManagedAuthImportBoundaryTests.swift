import Foundation
import XCTest
@testable import QuotaBackend

final class ManagedAuthImportBoundaryTests: XCTestCase {
    private let base = URL(fileURLWithPath: "/tmp/aiusage-boundary-tests", isDirectory: true)

    func testProductionReadsAndWritesOnlyProductionRoot() {
        let boundary = ManagedAuthImportBoundary(
            bundleIdentifier: ManagedAuthImportBoundary.productionBundleIdentifier,
            applicationSupportDirectory: base
        )
        let productionFile = base.appendingPathComponent("AIUsage/AuthImports/codex/account.json").path
        let debugFile = base.appendingPathComponent(
            "AIUsage/AuthImports-com.aiusage.desktop.debug/codex/account.json"
        ).path

        XCTAssertEqual(boundary.readableRootURLs, [boundary.productionRootURL])
        XCTAssertNotNil(boundary.readableManagedPath(productionFile))
        XCTAssertNotNil(boundary.writableManagedPath(productionFile))
        XCTAssertNil(boundary.readableManagedPath(debugFile))
        XCTAssertNil(boundary.writableManagedPath(debugFile))
    }

    func testDebugMayReadProductionButCanOnlyWriteItsOwnRoot() {
        let boundary = ManagedAuthImportBoundary(
            bundleIdentifier: "com.aiusage.desktop.debug",
            applicationSupportDirectory: base
        )
        let productionFile = base.appendingPathComponent("AIUsage/AuthImports/codex/account.json").path
        let debugFile = base.appendingPathComponent(
            "AIUsage/AuthImports-com.aiusage.desktop.debug/codex/account.json"
        ).path

        XCTAssertEqual(boundary.readableRootURLs, [boundary.activeRootURL, boundary.productionRootURL])
        XCTAssertNotNil(boundary.readableManagedPath(productionFile))
        XCTAssertNil(boundary.writableManagedPath(productionFile))
        XCTAssertNotNil(boundary.readableManagedPath(debugFile))
        XCTAssertNotNil(boundary.writableManagedPath(debugFile))
    }

    func testLookalikeAndTraversalPathsAreRejected() {
        let boundary = ManagedAuthImportBoundary(
            bundleIdentifier: "com.aiusage.desktop.debug",
            applicationSupportDirectory: base
        )
        let lookalike = base.appendingPathComponent("AIUsage/AuthImports-evil/codex/account.json").path
        let traversal = boundary.activeRootURL
            .appendingPathComponent("../AuthImports/codex/account.json")
            .path

        XCTAssertNil(boundary.readableManagedPath(lookalike))
        XCTAssertNil(boundary.writableManagedPath(lookalike))
        XCTAssertNotNil(boundary.readableManagedPath(traversal))
        XCTAssertNil(boundary.writableManagedPath(traversal))
    }

    func testDebugBuildRejectsProductionBundleIdentifier() {
        XCTAssertFalse(ManagedAuthImportBoundary.isBundleIdentityValid(
            bundleIdentifier: ManagedAuthImportBoundary.productionBundleIdentifier,
            isDebugBuild: true
        ))
        XCTAssertTrue(ManagedAuthImportBoundary.isBundleIdentityValid(
            bundleIdentifier: "com.aiusage.desktop.debug",
            isDebugBuild: true
        ))
        XCTAssertTrue(ManagedAuthImportBoundary.isBundleIdentityValid(
            bundleIdentifier: ManagedAuthImportBoundary.productionBundleIdentifier,
            isDebugBuild: false
        ))
    }
}
