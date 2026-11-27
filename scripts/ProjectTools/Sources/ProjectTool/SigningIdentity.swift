import Foundation

private func captures(_ pattern: String, _ text: String, _ index: Int = 1) throws -> [String] {
    let regex = try NSRegularExpression(pattern: pattern)
    let value = text as NSString
    return regex.matches(in: text, range: NSRange(location: 0, length: value.length)).map { value.substring(with: $0.range(at: index)) }
}

func signingIdentity(team: String, identities: String, certificates: String, inspect: (String) throws -> String) throws -> String {
    let usable = Set(try captures(#"(?m)^\s*\d+\)\s+([A-Fa-f0-9]{40})\s+""#, identities).map { $0.uppercased() })
    guard !usable.isEmpty else { throw ToolFailure("系统未列出可用代码签名身份。请检查证书及私钥状态。") }
    for certificate in try captures("(?s)-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----", certificates, 0) {
        let details = try inspect(certificate)
        guard try captures(#"(?m)^\s*OU\s*=\s*(.*?)\s*$"#, details).contains(team),
              let sha = try captures(#"(?im)^sha1 Fingerprint=([A-Fa-f0-9:]+)\s*$"#, details).first else { continue }
        let fingerprint = sha.replacingOccurrences(of: ":", with: "").uppercased()
        if usable.contains(fingerprint) { return fingerprint }
    }
    throw ToolFailure("没有匹配团队 \(team) 的可用代码签名证书。")
}

func selectSigningIdentity(team: String) throws -> String {
    try signingIdentity(team: team, identities: commandText(["/usr/bin/security", "find-identity", "-v", "-p", "codesigning"]),
                        certificates: commandText(["/usr/bin/security", "find-certificate", "-a", "-p"])) { cert in
        try commandText(["/usr/bin/openssl", "x509", "-noout", "-fingerprint", "-sha1", "-subject", "-nameopt", "sep_multiline,utf8"], input: Data(cert.utf8))
    }
}
