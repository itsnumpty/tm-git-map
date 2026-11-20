using System.Text.Json.Nodes;
using MapGit.Core.Manifest;

namespace MapGit.Core.Diff;

public enum ManifestChangeKind
{
    Added,
    Removed,
    Modified,
}

/// <summary>One detected difference between two manifests (base → other).</summary>
public sealed record ManifestChange(
    ManifestChangeKind Kind,
    string Section,
    string Key,
    JsonNode? BaseValue,
    JsonNode? OtherValue);

public static class Sections
{
    public const string Block = "block";
    public const string Item = "item";
    public const string MapInfo = "mapInfo";
    public const string Embedded = "embedded";
}

/// <summary>Keyed diff of two manifests.</summary>
public static class ManifestDiff
{
    public static IReadOnlyList<ManifestChange> Compute(MapManifest @base, MapManifest other)
    {
        var b = IndexedManifest.From(@base);
        var o = IndexedManifest.From(other);
        var changes = new List<ManifestChange>();

        ComputeKeyed(b.Blocks, o.Blocks, Sections.Block, changes);
        ComputeKeyed(b.Items, o.Items, Sections.Item, changes);

        foreach (var field in b.MapInfo)
        {
            if (!JsonNode.DeepEquals(field.Value, o.MapInfo[field.Key]))
            {
                changes.Add(new ManifestChange(
                    ManifestChangeKind.Modified,
                    Sections.MapInfo,
                    field.Key,
                    field.Value?.DeepClone(),
                    o.MapInfo[field.Key]?.DeepClone()));
            }
        }

        if (!JsonNode.DeepEquals(b.Embedded, o.Embedded))
        {
            changes.Add(new ManifestChange(
                ManifestChangeKind.Modified,
                Sections.Embedded,
                "zip",
                b.Embedded.DeepClone(),
                o.Embedded.DeepClone()));
        }

        return changes;
    }

    private static void ComputeKeyed(
        Dictionary<string, JsonObject> baseMap,
        Dictionary<string, JsonObject> otherMap,
        string section,
        List<ManifestChange> changes)
    {
        foreach (var key in baseMap.Keys.Concat(otherMap.Keys).Distinct().OrderBy(k => k, StringComparer.Ordinal))
        {
            var hasBase = baseMap.TryGetValue(key, out var baseVal);
            var hasOther = otherMap.TryGetValue(key, out var otherVal);

            if (hasBase && !hasOther)
            {
                changes.Add(new ManifestChange(ManifestChangeKind.Removed, section, key, baseVal!.DeepClone(), null));
            }
            else if (!hasBase && hasOther)
            {
                changes.Add(new ManifestChange(ManifestChangeKind.Added, section, key, null, otherVal!.DeepClone()));
            }
            else if (hasBase && hasOther && !JsonNode.DeepEquals(baseVal, otherVal))
            {
                changes.Add(new ManifestChange(ManifestChangeKind.Modified, section, key, baseVal!.DeepClone(), otherVal!.DeepClone()));
            }
        }
    }
}
