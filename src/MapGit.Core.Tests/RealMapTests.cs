using MapGit.Maps;
using Xunit.Abstractions;

namespace MapGit.Core.Tests;

/// <summary>
/// Phase 0 checks against real maps (fixtures/maps, git-ignored local files).
/// Silently passes when fixtures are absent.
/// </summary>
public class RealMapTests
{
    private readonly ITestOutputHelper _output;

    public RealMapTests(ITestOutputHelper output) => _output = output;

    private static string? RepoRoot()
    {
        var dir = new DirectoryInfo(AppContext.BaseDirectory);
        while (dir is not null && !Directory.Exists(Path.Combine(dir.FullName, "fixtures")))
        {
            dir = dir.Parent;
        }

        return dir?.FullName;
    }

    private static string[] MapFiles()
    {
        var root = RepoRoot();
        return root is null ? [] : Directory.GetFiles(Path.Combine(root, "fixtures", "maps"), "*.Map.Gbx");
    }

    [Fact]
    public void parsing_twice_produces_identical_manifest_hash()
    {
        var maps = MapFiles();
        if (maps.Length == 0)
        {
            return;
        }

        foreach (var map in maps)
        {
            var h1 = MapFile.ExtractManifest(map).ComputeHash();
            var h2 = MapFile.ExtractManifest(map).ComputeHash();

            Assert.True(h1 == h2, $"{Path.GetFileName(map)}: hash differs between two parses");
            _output.WriteLine($"{Path.GetFileName(map)}: {h1[..16]}...");
        }
    }

    [Fact]
    public void resaved_map_has_identical_manifest_to_original()
    {
        // Phase 1 acceptance: two real saves of the same map with no edits (vanilla is
        // the Sep-4 save, vanilla-resaved went through multiple Nov-19 in-game save
        // cycles) must produce the SAME canonical manifest: uid is excluded and the
        // embedded fingerprint is float-noise tolerant (F11/F14).
        var root = RepoRoot();
        var original = Path.Combine(root, "fixtures", "maps", "vanilla.Map.Gbx");
        var resaved = Path.Combine(root, "fixtures", "maps", "vanilla-resaved.Map.Gbx");
        if (!File.Exists(original) || !File.Exists(resaved))
        {
            return;
        }

        var a = MapFile.ExtractManifest(original);
        var b = MapFile.ExtractManifest(resaved);

        _output.WriteLine($"original manifest : {a.ComputeHash()}");
        _output.WriteLine($"resaved manifest  : {b.ComputeHash()}");

        if (a.Embedded.Entries.Count > 0 && b.Embedded.Entries.Count > 0)
        {
            _output.WriteLine($"embedded entry    : {a.Embedded.Entries[0].Fingerprint[..12]} vs {b.Embedded.Entries[0].Fingerprint[..12]}");
        }

        Assert.Equal(a.ComputeHash(), b.ComputeHash());
    }

    [Fact]
    public void gbxdotnet_resave_preserves_canonical_manifest()
    {
        var maps = MapFiles();
        if (maps.Length == 0)
        {
            return;
        }

        var outDir = Path.Combine(Path.GetTempPath(), "mapgit-tests");
        Directory.CreateDirectory(outDir);

        foreach (var map in maps)
        {
            var resave = Path.Combine(outDir, Path.GetFileName(map) + ".resaved.Map.Gbx");
            var report = MapFidelityProbe.Probe(map, resave);

            _output.WriteLine($"{Path.GetFileName(map)}:");
            _output.WriteLine($"  header   : {report.HeaderInfo}");
            _output.WriteLine($"  timing   : parse {report.ParseMs:F0} ms, save {report.SaveMs:F0} ms");
            _output.WriteLine($"  blob     : {report.SourceBlobSha256[..12]} -> {report.ResavedBlobSha256[..12]} " +
                              $"(byte-identical: {report.ByteIdentical}, size {report.SourceLength} -> {report.ResavedLength})");
            _output.WriteLine($"  manifest : {report.SourceManifestHash[..12]} -> {report.ResavedManifestHash[..12]} " +
                              $"(stable: {report.ManifestStable})");

            Assert.True(report.ManifestStable,
                $"{Path.GetFileName(map)}: canonical manifest drifted across GBX.NET round trip " +
                $"({report.SourceManifestHash[..12]} -> {report.ResavedManifestHash[..12]}); " +
                "the resaved file can be diffed manually via 'mapgit diff'.");
        }
    }
}
