import Foundation
import Security

public struct SigningPolicy {
    public let team: String

    public init() throws {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else {
            throw HelperFailure("signing_identity_missing")
        }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else {
            throw HelperFailure("signing_identity_missing")
        }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let info = information as? [String: Any],
              let team = info[kSecCodeInfoTeamIdentifier as String] as? String,
              team.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil else {
            throw HelperFailure("apple_team_signature_required")
        }
        self.team = team
    }

    public func requirement(identifiers: [String]) -> String {
        let ids = identifiers.map { "identifier \"\($0)\"" }.joined(separator: " or ")
        return "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\" and (\(ids))"
    }

    public func validateCore(_ url: URL, kind: String) throws {
        var code: SecStaticCode?
        var requirement: SecRequirement?
        let text = self.requirement(identifiers: [HelperIdentity.app + ".core." + kind])
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess,
              SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess,
              let code, let requirement,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures), requirement) == errSecSuccess else {
            throw HelperFailure("core_signature_invalid")
        }
    }
}
