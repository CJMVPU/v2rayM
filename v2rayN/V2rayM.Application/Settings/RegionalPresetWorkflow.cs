namespace V2rayM.Application.Settings;

public static class RegionalPresetWorkflow
{
    public static async Task<TResult> RunAsync<TStage, TResult>(
        Func<CancellationToken, Task<TStage>> stage,
        Func<TStage, CancellationToken, Task<TResult>> apply,
        CancellationToken cancellationToken)
    {
        TStage staged;
        try
        {
            staged = await stage(cancellationToken);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            throw;
        }
        catch (Exception exception)
        {
            throw new RegionalPresetStagingException(exception);
        }
        cancellationToken.ThrowIfCancellationRequested();
        return await apply(staged, cancellationToken);
    }
}

public sealed class RegionalPresetStagingException(Exception innerException)
    : Exception("Regional preset staging failed.", innerException) { }

public static class RegionalPresetApplyWorkflow
{
    public static async Task RunAsync(
        Func<CancellationToken, Task> applyConfiguration,
        Func<Func<Func<Task>, CancellationToken, Task>, CancellationToken, Task> updateGeoFilesTransaction,
        Func<Func<Task>, CancellationToken, Task> completeCoreApply,
        Func<Exception, Task> rollbackConfigurationAndRuntime,
        CancellationToken cancellationToken)
    {
        var configurationApplied = false;
        try
        {
            await applyConfiguration(cancellationToken);
            configurationApplied = true;
            cancellationToken.ThrowIfCancellationRequested();

            await updateGeoFilesTransaction(async (rollbackGeoFiles, transactionToken) =>
            {
                transactionToken.ThrowIfCancellationRequested();
                await completeCoreApply(rollbackGeoFiles, transactionToken);
            }, cancellationToken);
        }
        catch (RegionalPresetCoreApplyFailedException)
        {
            // CoreSettingsApply already restored its snapshot/runtime. The enclosing GeoFiles
            // transaction restores files before this exception is observed by its caller.
            throw;
        }
        catch (Exception applyException)
        {
            if (configurationApplied)
            {
                try
                {
                    await rollbackConfigurationAndRuntime(applyException);
                }
                catch (Exception rollbackException)
                {
                    throw new RegionalPresetApplyRollbackException(applyException, rollbackException);
                }
            }
            throw;
        }
    }
}

public sealed class RegionalPresetCoreApplyFailedException : Exception { }

public sealed class RegionalPresetApplyRollbackException(Exception applyException, Exception rollbackException)
    : Exception("The regional preset failed and its configuration/runtime rollback also failed.",
        new AggregateException(applyException, rollbackException)) { }

public sealed record RegionalPresetApplyResult(bool Success, bool RollbackSucceeded, Exception? Error);

public static class RegionalPresetTransaction
{
    public static async Task<RegionalPresetApplyResult> RunAsync(Func<Task> apply, Func<Task<bool>> rollback)
    {
        try
        {
            await apply();
            return new(true, true, null);
        }
        catch (Exception exception)
        {
            var rollbackSucceeded = false;
            try
            {
                rollbackSucceeded = await rollback();
            }
            catch
            {
                // Rollback failure is represented in the result; preserve the original apply failure.
            }
            return new(false, rollbackSucceeded, exception);
        }
    }
}
