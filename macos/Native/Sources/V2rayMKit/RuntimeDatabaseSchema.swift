import Foundation

extension RuntimeDatabase {
    /// Additive migrations preserve unknown fields and unsupported profiles from earlier versions.
    func installSchema() throws {
        let tables: [(name: String, primaryKey: String, columns: String)] = [
            ("SubItem", "Id",
                "Remarks varchar, Url varchar, MoreUrl varchar, Enabled integer, UserAgent varchar, " +
                "RequestHeaders varchar, Sort integer, Filter varchar, AutoUpdateInterval integer, " +
                "UpdateTime integer, ConvertTarget varchar, PrevProfile varchar, NextProfile varchar, " +
                "PreSocksPort integer, Memo varchar, CustomCoreType integer"),
            ("ProfileItem", "IndexId",
                "ConfigType integer, CoreType integer, ConfigVersion integer, Subid varchar, IsSub integer, " +
                "PreSocksPort integer, DisplayLog integer, Remarks varchar, Address varchar, Port integer, " +
                "Password varchar, Username varchar, Network varchar, HeaderType varchar, RequestHost varchar, " +
                "Path varchar, StreamSecurity varchar, AllowInsecure varchar, Sni varchar, Alpn varchar, " +
                "Fingerprint varchar, PublicKey varchar, ShortId varchar, SpiderX varchar, Mldsa65Verify varchar, " +
                "Extra varchar, MuxEnabled integer, Cert varchar, CertSha varchar, EchConfigList varchar, " +
                "VerifyPeerCertByName varchar, Finalmask varchar, ProtoExtra varchar, TransportExtra varchar, " +
                "Ports varchar, AlterId integer, Flow varchar, Id varchar, Security varchar"),
            ("ServerStatItem", "IndexId",
                "TotalUp integer, TotalDown integer, TodayUp integer, TodayDown integer, DateNow integer"),
            ("RoutingItem", "Id",
                "Remarks varchar, Url varchar, RuleSet varchar, RuleNum integer, Enabled integer, Locked integer, " +
                "CustomIcon varchar, DomainStrategy varchar, Sort integer, IsActive integer"),
            ("ProfileExItem", "IndexId",
                "Delay integer, Speed float, Sort integer, Message varchar, IpInfo varchar"),
            ("DNSItem", "Id",
                "Remarks varchar, Enabled integer, CoreType integer, UseSystemHosts integer, NormalDNS varchar, " +
                "TunDNS varchar, DomainStrategy4Freedom varchar, DomainDNSAddress varchar"),
            ("FullConfigTemplateItem", "Id",
                "Remarks varchar, Enabled integer, CoreType integer, Config varchar, TunConfig varchar, " +
                "AddProxyOnly integer, ProxyDetour varchar"),
            ("ProfileGroupItem", "IndexId",
                "ChildItems varchar, SubChildItems varchar, Filter varchar, MultipleLoad integer"),
        ]
        try transaction {
            for table in tables {
                let definitions = table.columns.components(separatedBy: ", ")
                let primary = table.primaryKey + " varchar PRIMARY KEY NOT NULL"
                _ = try query("CREATE TABLE IF NOT EXISTS \(table.name) (\(primary), \(table.columns))")
                let metadata = try query("PRAGMA table_info(\(table.name))")
                guard metadata.contains(where: { $0["name"] == .text(table.primaryKey) && $0["pk"] == .integer(1) }) else {
                    throw ClientFailure("database_schema_incompatible")
                }
                let existing = Set(metadata.compactMap { row -> String? in
                    if case let .text(name) = row["name"] { return name.lowercased() }
                    return nil
                })
                for definition in definitions {
                    guard let name = definition.split(separator: " ").first else { continue }
                    if !existing.contains(name.lowercased()) {
                        _ = try query("ALTER TABLE \(table.name) ADD COLUMN \(definition)")
                    }
                }
            }
        }
    }
}
