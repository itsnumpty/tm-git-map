using System.Diagnostics;
using System.Security.Cryptography;
using System.Text;
using MapGit.Core.Manifest;

namespace MapGit.Maps;

public sealed record RoundTripReport
{
    public required string SourcePath { get; init; }
    public required long SourceLength { get; init; }
    public required string SourceBlobSha256 { get; init; }
    public required string SourceManifestHash { get; init; }
    public required long ResavedLength { get; init; }
    public required string ResavedBlobSha256 { get; init; }
    public required string ResavedManifestHash { get; init; }
    public required bool ByteIdentical { get; init; }
    public required bool ManifestStable { get; init; }
    public required double ParseMs { get; init; }
    public required double SaveMs { get; init; }
    public required string HeaderInfo { get; init; }
}

/// <summary>
/// Phase 0 fidelity probe: parse a map with GBX.NET, re-save it with GBX.NET, reparse,
/// and measure whether the canonical manifest survives the round trip (structural
/// fidelity) even if raw bytes change (recompression etc. is fine).
/// </summary>
public static class MapFidelityProbe
{
    public static RoundTripReport Probe(string path, string resavePath)
    {
        var sw = Stopwatch.StartNew();
        var gbx = MapFile.Parse(path);
        var sourceManifest = MapFile.ExtractManifest(gbx.Node);
        sw.Stop();
        var parseMs = sw.Elapsed.TotalMilliseconds;

        var sourceBlob = File.ReadAllBytes(path);
        var sourceSha = CanonicalJson.HexLower(SHA256.HashData(sourceBlob));

        sw.Restart();
        gbx.Save(resavePath);
        sw.Stop();
        var saveMs = sw.Elapsed.TotalMilliseconds;

        var resavedBlob = File.ReadAllBytes(resavePath);
        var resavedSha = CanonicalJson.HexLower(SHA256.HashData(resavedBlob));
        var resavedManifest = MapFile.ExtractManifest(resavePath);

        return new RoundTripReport
        {
            SourcePath = path,
            SourceLength = sourceBlob.Length,
            SourceBlobSha256 = sourceSha,
            SourceManifestHash = sourceManifest.ComputeHash(),
            ResavedLength = resavedBlob.Length,
            ResavedBlobSha256 = resavedSha,
            ResavedManifestHash = resavedManifest.ComputeHash(),
            ByteIdentical = sourceSha == resavedSha,
            ManifestStable = sourceManifest.ComputeHash() == resavedManifest.ComputeHash(),
            ParseMs = parseMs,
            SaveMs = saveMs,
            HeaderInfo = DescribeHeader(sourceBlob),
        };
    }

    private static string DescribeHeader(byte[] blob)
    {
        if (blob.Length < 16)
        {
            return "too short";
        }

        var magic = Encoding.ASCII.GetString(blob, 0, 3);
        var version = BitConverter.ToUInt16(blob, 3);
        var format = (char)blob[5];
        var compressionFlags = blob[6];
        var reserved = $"{blob[7]:X2} {blob[8]:X2}";
        var classId = BitConverter.ToUInt32(blob, 9);

        return $"magic={magic} version={version} format={format} " +
               $"compressionFlags=0x{compressionFlags:X2} ({CompressionName(compressionFlags)}) " +
               $"reserved={reserved} classId=0x{classId:X8}";
    }

    private static string CompressionName(byte flags) => (flags & 0x01) != 0 ? "lzo" : flags == 0 ? "none" : "unknown";
}
