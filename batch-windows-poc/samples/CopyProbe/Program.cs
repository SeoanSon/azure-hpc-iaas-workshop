using System.Security.Cryptography;

if (args.Length != 1 || !File.Exists(args[0]))
{
    Console.Error.WriteLine("Usage: CopyProbe.exe <input-file>");
    return 2;
}

var path = Path.GetFullPath(args[0]);
await using var input = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read, 1024 * 1024, FileOptions.SequentialScan);
using var sha256 = SHA256.Create();
var hash = Convert.ToHexString(await sha256.ComputeHashAsync(input)).ToLowerInvariant();
var result = new
{
    input = Path.GetFileName(path),
    bytes = input.Length,
    sha256 = hash,
    processedUtc = DateTimeOffset.UtcNow
};
var outputPath = Path.Combine(Environment.CurrentDirectory, "copy-probe-result.json");
await File.WriteAllTextAsync(outputPath, System.Text.Json.JsonSerializer.Serialize(result, new System.Text.Json.JsonSerializerOptions { WriteIndented = true }));
Console.WriteLine($"Read {result.bytes} bytes; SHA-256 {hash}; result written to {outputPath}");
return 0;
