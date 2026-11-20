using System.Security.Cryptography;
using System.Text.Json;

namespace MapGit.Core.Manifest;

/// <summary>
/// Canonical JSON serialization: fixed property order (declaration order), camelCase,
/// no indentation, invariant number formatting. The output must be byte-stable for a
/// given manifest value so hashes are reproducible across machines and runs.
/// </summary>
public static class CanonicalJson
{
    public static readonly JsonSerializerOptions Options = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        WriteIndented = false,
    };

    public static byte[] Serialize<T>(T value) => JsonSerializer.SerializeToUtf8Bytes(value, Options);

    public static T Deserialize<T>(byte[] json) =>
        JsonSerializer.Deserialize<T>(json, Options)
        ?? throw new InvalidOperationException($"Failed to deserialize {typeof(T).Name} from canonical JSON.");

    public static string HexLower(byte[] bytes) => Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant();
}
