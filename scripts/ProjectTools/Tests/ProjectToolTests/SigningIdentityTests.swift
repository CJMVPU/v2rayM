import XCTest
@testable import ProjectTool

final class SigningIdentityTests: XCTestCase {
    func testUsesCertificateTeamAndUsableFingerprint() throws {
        let fingerprint = String(repeating: "A1", count: 20)
        let identities = "1) \(fingerprint) \"Apple Development: Test (PERSONALID)\""
        func choose(_ list: String, _ team: String) throws -> String {
            try signingIdentity(team: "TARGET", identities: list, certificates: "-----BEGIN CERTIFICATE-----\nfixture\n-----END CERTIFICATE-----") { _ in
                "sha1 Fingerprint=\(fingerprint)\nsubject=\n    OU = \(team)\n    CN = Test (TARGET)"
            }
        }
        XCTAssertEqual(try choose(identities, "TARGET"), fingerprint)
        XCTAssertThrowsError(try choose(identities, "OTHER"))
        XCTAssertThrowsError(try choose("0 valid identities found", "TARGET"))
        XCTAssertThrowsError(try choose(identities.replacingOccurrences(of: "A1", with: "B2"), "TARGET"))
    }
}
