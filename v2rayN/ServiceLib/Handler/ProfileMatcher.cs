namespace ServiceLib.Handler;

/// Pure identity matching shared by deduplication and subscription refresh.
internal static class ProfileMatcher
{
    public static bool CompareProfileItem(ProfileItem? o, ProfileItem? n, bool remarks)
    {
        if (o == null || n == null)
        {
            return false;
        }

        var oProtocolExtra = o.GetProtocolExtra();
        var nProtocolExtra = n.GetProtocolExtra();
        var oTransport = o.GetTransportExtra();
        var nTransport = n.GetTransportExtra();

        return o.ConfigType == n.ConfigType
               && AreEqual(o.Address, n.Address)
               && o.Port == n.Port
               && AreEqual(o.Password, n.Password)
               && AreEqual(o.Username, n.Username)
               && AreEqual(oProtocolExtra.VlessEncryption, nProtocolExtra.VlessEncryption)
               && AreEqual(oProtocolExtra.SsMethod, nProtocolExtra.SsMethod)
               && AreEqual(oProtocolExtra.VmessSecurity, nProtocolExtra.VmessSecurity)
               && AreEqual(o.Network, n.Network)
               && AreEqual(oTransport.RawHeaderType, nTransport.RawHeaderType)
               && AreEqual(oTransport.Host, nTransport.Host)
               && AreEqual(oTransport.Path, nTransport.Path)
               && AreEqual(oTransport.XhttpMode, nTransport.XhttpMode)
               && AreEqual(oTransport.XhttpExtra, nTransport.XhttpExtra)
               && AreEqual(oTransport.GrpcAuthority, nTransport.GrpcAuthority)
               && AreEqual(oTransport.GrpcServiceName, nTransport.GrpcServiceName)
               && AreEqual(oTransport.GrpcMode, nTransport.GrpcMode)
               && AreEqual(oTransport.KcpHeaderType, nTransport.KcpHeaderType)
               && AreEqual(oTransport.KcpSeed, nTransport.KcpSeed)
               && (o.ConfigType == EConfigType.Trojan || o.StreamSecurity == n.StreamSecurity)
               && AreEqual(oProtocolExtra.Flow, nProtocolExtra.Flow)
               && AreEqual(oProtocolExtra.SalamanderPass, nProtocolExtra.SalamanderPass)
               && AreEqual(o.Sni, n.Sni)
               && AreEqual(o.Alpn, n.Alpn)
               && AreEqual(o.Fingerprint, n.Fingerprint)
               && AreEqual(o.PublicKey, n.PublicKey)
               && AreEqual(o.ShortId, n.ShortId)
               && AreEqual(o.Finalmask, n.Finalmask)
               && (!remarks || o.Remarks == n.Remarks);

        static bool AreEqual(string? a, string? b)
        {
            return string.Equals(a, b) || (string.IsNullOrEmpty(a) && string.IsNullOrEmpty(b));
        }
    }

    public static ProfileItem? FindMatchedProfileItem(IEnumerable<ProfileItem>? source, ProfileItem? target)
    {
        if (source == null || target == null)
        {
            return null;
        }

        var matchedItem = source.FirstOrDefault(t => CompareProfileItem(t, target, true));
        if (matchedItem != null)
        {
            return matchedItem;
        }

        if (target.Remarks.IsNotEmpty())
        {
            matchedItem = source.FirstOrDefault(t => t.Remarks == target.Remarks);
            if (matchedItem != null)
            {
                return matchedItem;
            }
        }

        if (target.Address.IsNotEmpty() && target.Port > 0 && target.Password.IsNotEmpty())
        {
            matchedItem = source.FirstOrDefault(t =>
                IsSameText(t.Address, target.Address) &&
                t.Port == target.Port &&
                IsSameText(t.Password, target.Password));
            if (matchedItem != null)
            {
                return matchedItem;
            }
        }

        if (target.Address.IsNotEmpty() && target.Port > 0)
        {
            matchedItem = source.FirstOrDefault(t =>
                IsSameText(t.Address, target.Address) &&
                t.Port == target.Port);
            if (matchedItem != null)
            {
                return matchedItem;
            }
        }

        if (target.Address.IsNotEmpty())
        {
            matchedItem = source.FirstOrDefault(t => IsSameText(t.Address, target.Address));
            if (matchedItem != null)
            {
                return matchedItem;
            }
        }

        return null;

        static bool IsSameText(string? left, string? right)
        {
            if (left.IsNullOrEmpty() || right.IsNullOrEmpty())
            {
                return false;
            }

            return string.Equals(left.TrimEx(), right.TrimEx(), StringComparison.OrdinalIgnoreCase);
        }
    }
}
