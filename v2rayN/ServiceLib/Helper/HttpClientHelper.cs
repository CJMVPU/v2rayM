namespace ServiceLib.Helper;

/// <summary>
/// </summary>
public class HttpClientHelper
{
    private static readonly Lazy<HttpClientHelper> _instance = new(() =>
    {
        SocketsHttpHandler handler = new() { UseCookies = false };
        HttpClientHelper helper = new(new HttpClient(handler));
        return helper;
    });

    public static HttpClientHelper Instance => _instance.Value;
    private readonly HttpClient httpClient;

    private HttpClientHelper(HttpClient httpClient)
    {
        this.httpClient = httpClient;
    }

    public async Task<string?> TryGetAsync(string url, CancellationToken cancellationToken = default)
    {
        if (url.IsNullOrEmpty())
        {
            return null;
        }

        try
        {
            using var response = await httpClient.GetAsync(url, cancellationToken);
            return await response.Content.ReadAsStringAsync(cancellationToken);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            throw;
        }
        catch
        {
            return null;
        }
    }

    public async Task<string?> GetAsync(string url)
    {
        if (url.IsNullOrEmpty())
        {
            return null;
        }
        return await httpClient.GetStringAsync(url);
    }

}
