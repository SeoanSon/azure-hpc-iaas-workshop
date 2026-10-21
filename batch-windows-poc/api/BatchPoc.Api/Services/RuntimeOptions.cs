namespace BatchPoc.Api.Services;

public sealed class RuntimeOptions
{
    public string SqlConnectionString { get; init; } = "";
    public string BatchEndpoint { get; init; } = "";
    public string BatchPoolId { get; init; } = "";
    public string BatchApiVersion { get; init; } = "2024-07-01.20.0";
    public string StorageAccountUrl { get; init; } = "";
    public string InputContainer { get; init; } = "inputs";
    public string OutputContainer { get; init; } = "outputs";
    public string BootstrapContainer { get; init; } = "bootstrap";
    public string PayloadContainer { get; init; } = "jobpayloads";
    public string FileShareAccountName { get; init; } = "";
    public string FileShareName { get; init; } = "";
    public string KeyVaultUrl { get; init; } = "";
    public string FileShareKeySecretName { get; init; } = "azure-files-account-key";
    public string ApiManagedIdentityClientId { get; init; } = "";
    public string WorkerManagedIdentityClientId { get; init; } = "";
    public string WorkerDirectory { get; init; } = "worker";
    public string PoolId { get; init; } = "";
    public int MonitorIntervalSeconds { get; init; } = 15;
    public int ArtifactSasMinutes { get; init; } = 30;
    public int BootstrapSasMinutes { get; init; } = 240;
}
