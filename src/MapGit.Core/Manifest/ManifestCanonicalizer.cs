using System.Globalization;
using System.Text.Json;

namespace MapGit.Core.Manifest;

/// <summary>
/// Merge identity keys. Rounding is fixed (mm for positions, 1/100 for angles) so that
/// the same object extracted from identical bytes always yields the same key.
/// Deliberate duplicates (same key, different content) get deterministic "#2", "#3" suffixes
/// during canonicalization.
/// </summary>
public static class ManifestKeys
{
    public static string Block(ManifestBlock b)
    {
        if (b.IsFree || b.FreePosition is not null)
        {
            return $"f:{Fmt(b.FreePosition, 3)}|{Fmt(b.FreeRotation, 2)}{(b.IsGhost ? "|gh" : "")}";
        }

        return $"b:{b.Coord.X},{b.Coord.Y},{b.Coord.Z}{(b.IsGhost ? "#gh" : "")}";
    }

    public static string Item(ManifestItem i) => $"i:{Fmt(i.Position, 3)}|{Fmt(i.Rotation, 2)}";

    private static string Fmt(ManifestVec3? v, int decimals) =>
        v is null ? "n" : string.Join(",", Num(v.X, decimals), Num(v.Y, decimals), Num(v.Z, decimals));

    private static string Num(float value, int decimals)
    {
        var rounded = MathF.Round(value, decimals, MidpointRounding.AwayFromZero);
        if (rounded == 0f)
        {
            rounded = 0f; // normalize -0: file-saved floats carry -1e-7 noise where the
                          // game's memory holds exact 0 — both must format as "0.00"
        }
        return rounded.ToString(decimals == 3 ? "F3" : "F2", CultureInfo.InvariantCulture);
    }
}

/// <summary>
/// Produces the canonical form of a manifest: keys assigned, blocks/items sorted
/// (key, then name), duplicate keys suffixed deterministically, embedded entries sorted.
/// </summary>
public static class ManifestCanonicalizer
{
    public static MapManifest Canonicalize(MapManifest manifest)
    {
        // Note: sort must be TOTAL (key, then name, then full content). The game reorders
        // same-cell duplicate blocks between saves; without the content tiebreaker the
        // deterministic "#2" suffixes can flip between identical blocks, producing false
        // diffs (Phase 0 finding F15).
        var blocks = manifest.Blocks
            .Select(b => b with { Key = ManifestKeys.Block(b) })
            .OrderBy(b => b.Key, StringComparer.Ordinal)
            .ThenBy(b => b.Name, StringComparer.Ordinal)
            .ThenBy(ContentSortKey)
            .ToList();
        Suffixed(blocks, b => b.Key, (b, k) => b with { Key = k });

        var items = manifest.Items
            .Select(i => i with { Key = ManifestKeys.Item(i) })
            .OrderBy(i => i.Key, StringComparer.Ordinal)
            .ThenBy(i => i.ItemModel, StringComparer.Ordinal)
            .ThenBy(ContentSortKey)
            .ToList();
        Suffixed(items, i => i.Key, (i, k) => i with { Key = k });

        var entries = manifest.Embedded.Entries
            .OrderBy(e => e.Name, StringComparer.Ordinal)
            .ThenBy(e => e.Fingerprint, StringComparer.Ordinal)
            .ToList();

        return manifest with
        {
            Blocks = blocks,
            Items = items,
            Embedded = manifest.Embedded with { Entries = entries },
        };
    }

    private static string ContentSortKey<T>(T value) =>
        JsonSerializer.Serialize(value, CanonicalJson.Options);

    /// <summary>Assigns "#2", "#3", ... to duplicate keys in already-sorted order.</summary>
    private static void Suffixed<T>(List<T> sorted, Func<T, string> keyOf, Func<T, string, T> withKey)
    {
        var seen = new Dictionary<string, int>();
        for (var i = 0; i < sorted.Count; i++)
        {
            var key = keyOf(sorted[i]);
            if (seen.TryGetValue(key, out var n))
            {
                seen[key] = n + 1;
                sorted[i] = withKey(sorted[i], $"{key}#{n + 1}");
            }
            else
            {
                seen[key] = 1;
            }
        }
    }
}
