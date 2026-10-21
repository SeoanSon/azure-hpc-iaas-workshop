using System.ComponentModel.DataAnnotations;
using System.Text.RegularExpressions;

namespace BatchPoc.Api;

public sealed record SubmitJobRequest
{
    [Required, StringLength(128, MinimumLength = 1)]
    public string ExecutableBlob { get; init; } = "";

    [Required, StringLength(128, MinimumLength = 1)]
    public string ExecutableVersion { get; init; } = "";

    [RegularExpression("^[a-fA-F0-9]{64}$")]
    public string? ExecutableSha256 { get; init; }

    [Required, RegularExpression("^(azureFiles|blob)$")]
    public string CopyMode { get; init; } = "";

    [Required, MinLength(1), MaxLength(100)]
    public List<JobInput> Inputs { get; init; } = [];

    [MaxLength(100)]
    public List<string> Arguments { get; init; } = [];

    [Range(1, 86400)]
    public int TimeoutSeconds { get; init; } = 3600;
}

public sealed record JobInput
{
    [Required, StringLength(1024, MinimumLength = 1)]
    public string BlobName { get; init; } = "";

    [Range(0, long.MaxValue)]
    public long? ExpectedBytes { get; init; }

    [RegularExpression("^[a-fA-F0-9]{64}$")]
    public string? ExpectedSha256 { get; init; }
}

public sealed record SubmitJobResponse(string Id, string Status);

public sealed record JobStatusResponse(
    string Id,
    string Status,
    string CopyMode,
    DateTimeOffset CreatedAt,
    DateTimeOffset? StartedAt,
    DateTimeOffset? CompletedAt,
    string? ErrorCode,
    string? ErrorMessage);

public sealed record ArtifactResponse(string Name, string Url, long Bytes, string? Sha256);

public static class InputValidation
{
    private static readonly Regex BlobNamePattern = new(
        "^[A-Za-z0-9][A-Za-z0-9._/-]{0,1023}$",
        RegexOptions.CultureInvariant | RegexOptions.Compiled);

    public static bool IsSafeBlobName(string name) =>
        BlobNamePattern.IsMatch(name) &&
        !name.Contains('\\') &&
        !name.Split('/').Any(segment => segment is "." or "..");
}
