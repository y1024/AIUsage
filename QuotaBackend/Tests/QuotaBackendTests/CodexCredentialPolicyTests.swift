import Foundation
import XCTest
@testable import QuotaBackend

final class CodexCredentialPolicyTests: XCTestCase {
    func testWorkspaceIdentityUsesAccountAndUserNotPlan() {
        XCTAssertTrue(CodexCredentialPolicy.belongsToSameWorkspace(
            lhsAccountID: "workspace-1",
            lhsUserID: "member-1",
            rhsAccountID: " WORKSPACE-1 ",
            rhsUserID: "MEMBER-1"
        ))
        XCTAssertFalse(CodexCredentialPolicy.belongsToSameWorkspace(
            lhsAccountID: "workspace-1",
            lhsUserID: "member-1",
            rhsAccountID: "workspace-1",
            rhsUserID: "member-2"
        ))
        XCTAssertFalse(CodexCredentialPolicy.belongsToSameWorkspace(
            lhsAccountID: "workspace-1",
            lhsUserID: "member-1",
            rhsAccountID: "workspace-2",
            rhsUserID: "member-1"
        ))
    }

    func testWorkspaceIdentityRequiresUserOnBothSides() {
        XCTAssertFalse(CodexCredentialPolicy.belongsToSameWorkspace(
            lhsAccountID: "workspace-1",
            lhsUserID: nil,
            rhsAccountID: "workspace-1",
            rhsUserID: "member-1"
        ))
        XCTAssertFalse(CodexCredentialPolicy.belongsToSameWorkspace(
            lhsAccountID: "workspace-1",
            lhsUserID: nil,
            rhsAccountID: "workspace-1",
            rhsUserID: nil
        ))
    }

    func testRefreshFailureSeparatesRotationExpiryAndGenericInvalidGrant() {
        let reused = CodexCredentialPolicy.refreshFailure(
            statusCode: 400,
            data: Data(#"{"error":"invalid_grant","error_description":"refresh token already used"}"#.utf8)
        )
        let expired = CodexCredentialPolicy.refreshFailure(
            statusCode: 400,
            data: Data(#"{"error":"invalid_grant","error_description":"refresh token expired"}"#.utf8)
        )
        let rotated = CodexCredentialPolicy.refreshFailure(
            statusCode: 400,
            data: Data(#"{"error":"invalid_grant","error_description":"refresh token has been rotated"}"#.utf8)
        )
        let invalid = CodexCredentialPolicy.refreshFailure(
            statusCode: 400,
            data: Data(#"{"error":"invalid_grant"}"#.utf8)
        )

        XCTAssertEqual(reused.code, "refresh_token_reused")
        XCTAssertEqual(rotated.code, "refresh_token_reused")
        XCTAssertEqual(expired.code, "refresh_token_expired")
        XCTAssertEqual(invalid.code, "refresh_token_invalid")
    }

    func testRefreshFailureSeparatesRateLimitAndServerFailure() {
        XCTAssertEqual(
            CodexCredentialPolicy.refreshFailure(statusCode: 429, data: Data()).code,
            "oauth_rate_limited"
        )
        XCTAssertEqual(
            CodexCredentialPolicy.refreshFailure(statusCode: 503, data: Data()).code,
            "oauth_server_error"
        )
    }

    func testRefreshTransportFailureSeparatesTimeoutAndOffline() {
        XCTAssertEqual(
            CodexCredentialPolicy.refreshTransportFailure(URLError(.timedOut)).code,
            "oauth_network_timeout"
        )
        XCTAssertEqual(
            CodexCredentialPolicy.refreshTransportFailure(URLError(.notConnectedToInternet)).code,
            "oauth_network_unavailable"
        )
    }
}
