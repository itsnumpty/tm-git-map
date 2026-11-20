using System.Text.Json.Nodes;
using MapGit.Core.Diff;
using MapGit.Core.Manifest;

namespace MapGit.Core.Merge;

public enum MergeStatus
{
    Clean,
    Conflicted,
}

public enum MergeConflictKind
{
    /// <summary>Both sides added different content at the same key.</summary>
    AddAdd,

    /// <summary>Both sides modified the same key differently.</summary>
    ModifyModify,

    /// <summary>Theirs deleted, ours modified (same key).</summary>
    ModifyDelete,

    /// <summary>Theirs modified, ours deleted (same key).</summary>
    DeleteModify,

    /// <summary>The same map info field changed differently on both sides.</summary>
    Metadata,

    /// <summary>Embedded zip diverged on both sides.</summary>
    Embedded,
}

/// <summary>One unresolved conflict, ready for in-editor resolution (ours/theirs/both/none).</summary>
public sealed record MergeConflict(
    MergeConflictKind Kind,
    string Section,
    string Key,
    string OursSummary,
    string TheirsSummary,
    string? BaseSummary);

public sealed record MergeResult
{
    public required MergeStatus Status { get; init; }

    /// <summary>The merged manifest; null while conflicts are unresolved.</summary>
    public required MapManifest? Merged { get; init; }

    public required IReadOnlyList<MergeConflict> Conflicts { get; init; }

    /// <summary>Human-readable list of changes taken from theirs (applied onto ours).</summary>
    public required IReadOnlyList<string> AppliedChanges { get; init; }

    public bool HasConflicts => Conflicts.Count > 0;
}

/// <summary>
/// Classic 3-way merge on keyed manifests: changes base→theirs are applied onto ours;
/// anything where ours also diverged from base becomes a conflict.
/// </summary>
public static class ThreeWayMerge
{
    public static MergeResult Merge(MapManifest @base, MapManifest ours, MapManifest theirs)
    {
        var b = IndexedManifest.From(@base);
        var o = IndexedManifest.From(ours);
        var t = IndexedManifest.From(theirs);
        var merged = IndexedManifest.From(ours);

        var conflicts = new List<MergeConflict>();
        var applied = new List<string>();

        foreach (var change in ManifestDiff.Compute(@base, theirs))
        {
            switch (change.Section)
            {
                case Sections.Block:
                    MergeKeyed(change, b.Blocks, o.Blocks, t.Blocks, merged.Blocks, conflicts, applied);
                    break;
                case Sections.Item:
                    MergeKeyed(change, b.Items, o.Items, t.Items, merged.Items, conflicts, applied);
                    break;
                case Sections.MapInfo:
                    MergeField(change, b, o, t, merged, conflicts, applied);
                    break;
                case Sections.Embedded:
                    MergeEmbedded(change, b, o, t, merged, conflicts, applied);
                    break;
            }
        }

        if (conflicts.Count > 0)
        {
            return new MergeResult
            {
                Status = MergeStatus.Conflicted,
                Merged = null,
                Conflicts = conflicts,
                AppliedChanges = applied,
            };
        }

        return new MergeResult
        {
            Status = MergeStatus.Clean,
            Merged = merged.ToManifest(),
            Conflicts = [],
            AppliedChanges = applied,
        };
    }

    private static void MergeKeyed(
        ManifestChange change,
        Dictionary<string, JsonObject> b,
        Dictionary<string, JsonObject> o,
        Dictionary<string, JsonObject> t,
        Dictionary<string, JsonObject> merged,
        List<MergeConflict> conflicts,
        List<string> applied)
    {
        var key = change.Key;
        var label = change.Section;

        switch (change.Kind)
        {
            case ManifestChangeKind.Added:
            {
                if (!o.TryGetValue(key, out var oursVal))
                {
                    merged[key] = (JsonObject)t[key].DeepClone()!;
                    applied.Add($"take theirs: +{label} {key} ({Summarize(t[key])})");
                }
                else if (JsonNode.DeepEquals(oursVal, t[key]))
                {
                    // Both sides added identical content — nothing to do.
                }
                else
                {
                    conflicts.Add(new MergeConflict(MergeConflictKind.AddAdd, change.Section, key,
                        Summarize(oursVal), Summarize(t[key]), null));
                }

                break;
            }

            case ManifestChangeKind.Removed:
            {
                if (!o.ContainsKey(key))
                {
                    return; // both sides removed it
                }

                if (JsonNode.DeepEquals(o[key], b[key]))
                {
                    merged.Remove(key);
                    applied.Add($"take theirs: -{label} {key} ({Summarize(b[key])})");
                }
                else
                {
                    conflicts.Add(new MergeConflict(MergeConflictKind.ModifyDelete, change.Section, key,
                        Summarize(o[key]), "(deleted)", Summarize(b[key])));
                }

                break;
            }

            case ManifestChangeKind.Modified:
            {
                if (!o.TryGetValue(key, out var oursVal))
                {
                    conflicts.Add(new MergeConflict(MergeConflictKind.DeleteModify, change.Section, key,
                        "(deleted)", Summarize(t[key]), Summarize(b[key])));
                    break;
                }

                if (JsonNode.DeepEquals(oursVal, t[key]))
                {
                    return; // both sides made the same modification
                }

                if (JsonNode.DeepEquals(oursVal, b[key]))
                {
                    merged[key] = (JsonObject)t[key].DeepClone()!;
                    applied.Add($"take theirs: ~{label} {key} ({Summarize(t[key])})");
                }
                else
                {
                    conflicts.Add(new MergeConflict(MergeConflictKind.ModifyModify, change.Section, key,
                        Summarize(oursVal), Summarize(t[key]), Summarize(b[key])));
                }

                break;
            }
        }
    }

    private static void MergeField(
        ManifestChange change,
        IndexedManifest b,
        IndexedManifest o,
        IndexedManifest t,
        IndexedManifest merged,
        List<MergeConflict> conflicts,
        List<string> applied)
    {
        var field = change.Key;
        var oursVal = o.MapInfo[field];
        var theirsVal = t.MapInfo[field];
        var baseVal = b.MapInfo[field];

        if (JsonNode.DeepEquals(oursVal, theirsVal))
        {
            return;
        }

        if (JsonNode.DeepEquals(oursVal, baseVal))
        {
            merged.MapInfo[field] = theirsVal?.DeepClone();
            applied.Add($"take theirs: mapInfo.{field} = {NodeString(theirsVal)}");
        }
        else
        {
            conflicts.Add(new MergeConflict(MergeConflictKind.Metadata, Sections.MapInfo, field,
                NodeString(oursVal), NodeString(theirsVal), NodeString(baseVal)));
        }
    }

    private static void MergeEmbedded(
        ManifestChange change,
        IndexedManifest b,
        IndexedManifest o,
        IndexedManifest t,
        IndexedManifest merged,
        List<MergeConflict> conflicts,
        List<string> applied)
    {
        if (JsonNode.DeepEquals(o.Embedded, t.Embedded))
        {
            return;
        }

        if (JsonNode.DeepEquals(o.Embedded, b.Embedded))
        {
            merged.Embedded = (JsonObject)t.Embedded.DeepClone()!;
            applied.Add("take theirs: embedded zip");
        }
        else
        {
            conflicts.Add(new MergeConflict(MergeConflictKind.Embedded, Sections.Embedded, "zip",
                EmbeddedSummary(o.Embedded), EmbeddedSummary(t.Embedded), EmbeddedSummary(b.Embedded)));
        }
    }

    internal static string Summarize(JsonObject? node)
    {
        if (node is null)
        {
            return "(none)";
        }

        var name = node["name"] ?? node["itemModel"] ?? node["uid"];
        return name?.ToString() ?? node.ToJsonString(CanonicalJson.Options);
    }

    private static string NodeString(JsonNode? node) => node?.ToJsonString(CanonicalJson.Options) ?? "null";

    private static string EmbeddedSummary(JsonObject embedded) =>
        embedded["entries"] is JsonArray { Count: > 0 } entries
            ? $"{entries.Count} entries (first fingerprint {ShortFingerprint(entries[0])})"
            : "0 entries";

    private static string ShortFingerprint(JsonNode? entry)
    {
        var s = entry?["fingerprint"]?.ToString();
        return s is null ? "?" : s[..Math.Min(12, s.Length)];
    }
}
