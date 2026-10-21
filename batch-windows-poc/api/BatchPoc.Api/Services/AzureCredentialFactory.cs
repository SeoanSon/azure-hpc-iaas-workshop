using Azure.Core;
using Azure.Identity;

namespace BatchPoc.Api.Services;

public static class AzureCredentialFactory
{
    public static TokenCredential Create(IConfiguration configuration, IHostEnvironment environment)
    {
        if (environment.IsDevelopment())
            return new DefaultAzureCredential();

        var clientId = configuration["Azure:ApiManagedIdentityClientId"];
        return string.IsNullOrWhiteSpace(clientId)
            ? new ManagedIdentityCredential()
            : new ManagedIdentityCredential(clientId);
    }
}
