namespace v2rayN.WebAPI.Services;

internal static class RestoreDirectoryTransaction
{
    public static void Apply(Action prepareCandidate, Action replace, Action cleanupCandidate, Action cleanupDisplaced)
    {
        var replaced = false;
        try { prepareCandidate(); replace(); replaced = true; }
        finally
        {
            try { cleanupCandidate(); }
            finally
            {
                // A failed swap/rollback can leave the only old configuration in
                // the displaced directory. Never discard it on a failure path.
                if (replaced) cleanupDisplaced();
            }
        }
    }
}
