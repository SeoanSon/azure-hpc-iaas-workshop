using System.Security.Cryptography;

if (args.Length != 1 || !File.Exists(args[0]))
{
    Console.Error.WriteLine("사용법: CopyProbe.exe <입력 파일>");
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
Console.WriteLine($"{result.bytes}바이트를 읽었습니다. SHA-256: {hash}. 결과 파일: {outputPath}");
return 0;
