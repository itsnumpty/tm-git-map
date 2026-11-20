using System.Text.Json;
using System.Text.Json.Nodes;
using GBX.NET;
using GBX.NET.Engines.Game;
using GBX.NET.Interfaces.Game;
using MapGit.Core.Diff;
using MapGit.Core.Manifest;

namespace MapGit.Maps;

/// <summary>
/// Headless materialization: transforms a parsed map (loaded from "ours") so that its
/// canonical manifest becomes the target manifest (typically a clean merge result).
/// The in-game plugin implements the same semantics on the live map in Phase 1.
///
/// Strictness: placement of blocks/items with skins, waypoint properties or decals is
/// not supported yet and throws — better a loud failure than silent content loss.
/// Every materialization is expected to be verified by re-extracting the manifest and
/// comparing hashes (see <c>MapRepository.Merge</c>).
/// </summary>
public static class MapMaterializer
{
    /// <summary>Applies the diff from the map's current manifest to <paramref name="target"/>. Returns a human-readable operation log.</summary>
    public static List<string> Apply(CGameCtnChallenge map, MapManifest target, CGameCtnChallenge? theirsMapForEmbedded = null)
    {
        var log = new List<string>();
        var current = MapFile.ExtractManifest(map);

        foreach (var change in ManifestDiff.Compute(current, target))
        {
            switch (change.Section)
            {
                case Sections.Block:
                    ApplyBlockChange(map, change, log);
                    break;
                case Sections.Item:
                    ApplyItemChange(map, change, log);
                    break;
                case Sections.MapInfo:
                    ApplyMapInfoChange(map, change, log);
                    break;
                case Sections.Embedded:
                    ApplyEmbeddedChange(map, theirsMapForEmbedded, change, log);
                    break;
            }
        }

        return log;
    }

    // ---------- blocks ----------

    private static void ApplyBlockChange(CGameCtnChallenge map, ManifestChange change, List<string> log)
    {
        var targetBlock = ChangeValue<ManifestBlock>(change.OtherValue);
        var baseBlock = ChangeValue<ManifestBlock>(change.BaseValue);

        switch (change.Kind)
        {
            case ManifestChangeKind.Added:
                PlaceManifestBlock(map, targetBlock!);
                log.Add($"+block {change.Key} ({targetBlock!.Name})");
                break;

            case ManifestChangeKind.Removed:
                if (RemoveBlock(map, baseBlock!))
                {
                    log.Add($"-block {change.Key} ({baseBlock!.Name})");
                }
                else
                {
                    log.Add($"!block {change.Key} ({baseBlock!.Name}) not found for removal");
                }

                break;

            case ManifestChangeKind.Modified:
                if (RemoveBlock(map, baseBlock!))
                {
                    PlaceManifestBlock(map, targetBlock!);
                    log.Add($"~block {change.Key} ({targetBlock!.Name})");
                }
                else
                {
                    log.Add($"!block {change.Key} base version not found for update");
                }

                break;
        }
    }

    /// <summary>Places a block described by a manifest record.</summary>
    public static void PlaceManifestBlock(CGameCtnChallenge map, ManifestBlock b)
    {
        if (b.HasSkin || b.HasWaypointProps || b.DecalId is not null)
        {
            throw new NotSupportedException(
                $"Placing blocks with skins/waypoint properties/decals is not supported yet ({b.Name} at {b.Key}).");
        }

        var ident = FindBlockModelIdent(map, b.Name) ?? new Ident(b.Name, "", "");

        CGameCtnBlock block;
        if (b.IsFree || b.FreePosition is not null)
        {
            block = new CGameCtnBlock
            {
                Name = b.Name,
                IsFree = true,
                Coord = new Int3(b.Coord.X, b.Coord.Y, b.Coord.Z), // free blocks carry -1 grid coords in files
                Direction = (Direction)b.Direction,
                AbsolutePositionInMap = new Vec3(b.FreePosition!.X, b.FreePosition.Y, b.FreePosition.Z),
                YawPitchRoll = new Vec3(b.FreeRotation?.X ?? 0, b.FreeRotation?.Y ?? 0, b.FreeRotation?.Z ?? 0),
            };
            block.CreateChunk<CGameCtnBlock.Chunk03057002>();
            map.PlaceBlock(block);
        }
        else
        {
            block = map.PlaceBlock(
                ident,
                new Int3(b.Coord.X, b.Coord.Y, b.Coord.Z),
                (Direction)b.Direction,
                b.IsGround,
                (byte)b.Variant,
                (byte)b.SubVariant);
        }

        block.IsGhost = b.IsGhost;
        block.IsClip = b.IsClip;
        block.IsPillar = b.IsPillar;
        block.Color = Enum.Parse<DifficultyColor>(b.Color);
        block.LightmapQuality = Enum.Parse<LightmapQuality>(b.LightmapQuality);
    }

    private static bool RemoveBlock(CGameCtnChallenge map, ManifestBlock b)
    {
        foreach (var list in new[] { map.Blocks, map.BakedBlocks })
        {
            if (list is null)
            {
                continue;
            }

            foreach (var candidate in list)
            {
                if (!Matches(candidate, b))
                {
                    continue;
                }

                list.Remove(candidate);
                return true;
            }
        }

        return false;
    }

    private static bool Matches(CGameCtnBlock c, ManifestBlock b)
    {
        if (c.Name != b.Name
            || c.IsGhost != b.IsGhost
            || c.IsGround != b.IsGround
            || c.IsClip != b.IsClip
            || c.IsPillar != b.IsPillar
            || c.Variant != b.Variant
            || c.SubVariant != b.SubVariant
            || (int)c.Direction != b.Direction
            || c.Color.ToString() != b.Color
            || c.LightmapQuality.ToString() != b.LightmapQuality)
        {
            return false;
        }

        if (b.IsFree || b.FreePosition is not null)
        {
            return CloseTo(c.AbsolutePositionInMap, b.FreePosition!)
                && CloseTo(c.YawPitchRoll, b.FreeRotation ?? new ManifestVec3(0, 0, 0));
        }

        return c.Coord.X == b.Coord.X && c.Coord.Y == b.Coord.Y && c.Coord.Z == b.Coord.Z;
    }

    private static Ident? FindBlockModelIdent(CGameCtnChallenge map, string name)
    {
        var match = map.GetBlocks().Concat(map.GetBakedBlocks()).FirstOrDefault(x => x.Name == name);
        return match?.BlockModel;
    }

    // ---------- items ----------

    private static void ApplyItemChange(CGameCtnChallenge map, ManifestChange change, List<string> log)
    {
        var targetItem = ChangeValue<ManifestItem>(change.OtherValue);
        var baseItem = ChangeValue<ManifestItem>(change.BaseValue);

        switch (change.Kind)
        {
            case ManifestChangeKind.Added:
                PlaceManifestItem(map, targetItem!);
                log.Add($"+item {change.Key} ({targetItem!.ItemModel})");
                break;

            case ManifestChangeKind.Removed:
                if (RemoveItem(map, baseItem!))
                {
                    log.Add($"-item {change.Key} ({baseItem!.ItemModel})");
                }
                else
                {
                    log.Add($"!item {change.Key} not found for removal");
                }

                break;

            case ManifestChangeKind.Modified:
                if (RemoveItem(map, baseItem!))
                {
                    PlaceManifestItem(map, targetItem!);
                    log.Add($"~item {change.Key} ({targetItem!.ItemModel})");
                }
                else
                {
                    log.Add($"!item {change.Key} base version not found for update");
                }

                break;
        }
    }

    /// <summary>Places an item described by a manifest record.</summary>
    public static void PlaceManifestItem(CGameCtnChallenge map, ManifestItem i)
    {
        if (i.HasSkin || i.HasWaypointProps)
        {
            throw new NotSupportedException(
                $"Placing items with skins/waypoint properties is not supported yet ({i.ItemModel} at {i.Key}).");
        }

        var ident = FindItemModelIdent(map, i.ItemModel) ?? new Ident(i.ItemModel, "", "");

        var anchored = map.PlaceAnchoredObject(
            ident,
            new Vec3(i.Position.X, i.Position.Y, i.Position.Z),
            new Vec3(i.Rotation.X, i.Rotation.Y, i.Rotation.Z),
            i.Pivot is null ? default : new Vec3(i.Pivot.X, i.Pivot.Y, i.Pivot.Z));

        anchored.Scale = i.Scale ?? 1f;
        anchored.Color = Enum.Parse<DifficultyColor>(i.Color);
        anchored.LightmapQuality = Enum.Parse<LightmapQuality>(i.LightmapQuality);
    }

    private static bool RemoveItem(CGameCtnChallenge map, ManifestItem i)
    {
        var found = map.GetAnchoredObjects().FirstOrDefault(a => Matches(a, i));
        return found is not null && map.RemoveAnchoredObject(found);
    }

    private static bool Matches(CGameCtnAnchoredObject a, ManifestItem i)
    {
        if (a.ItemModel.Id != i.ItemModel
            || a.Color.ToString() != i.Color
            || a.LightmapQuality.ToString() != i.LightmapQuality
            || (a.PackDesc is not null) != i.HasSkin)
        {
            return false;
        }

        if (!CloseTo(a.AbsolutePositionInMap, i.Position)
            || !CloseTo(a.YawPitchRoll, i.Rotation)
            || MathF.Abs(a.Scale - (i.Scale ?? 1f)) > 0.001f)
        {
            return false;
        }

        return true;
    }

    private static Ident? FindItemModelIdent(CGameCtnChallenge map, string name)
    {
        var match = map.GetAnchoredObjects().FirstOrDefault(x => x.ItemModel.Id == name);
        return match?.ItemModel;
    }

    // ---------- map info ----------

    private static void ApplyMapInfoChange(CGameCtnChallenge map, ManifestChange change, List<string> log)
    {
        var v = change.OtherValue;
        switch (change.Key)
        {
            case "name": map.MapName = String(v) ?? ""; break;
            case "comments": map.Comments = String(v) ?? ""; break;
            case "authorLogin": map.AuthorLogin = String(v) ?? ""; break;
            case "mapType": map.MapType = String(v) ?? ""; break;
            case "mapStyle": map.MapStyle = String(v) ?? ""; break;
            case "titleId": map.TitleId = String(v) ?? ""; break;
            case "authorTimeMs": map.AuthorTime = ToTime(v); break;
            case "goldTimeMs": map.GoldTime = ToTime(v); break;
            case "silverTimeMs": map.SilverTime = ToTime(v); break;
            case "bronzeTimeMs": map.BronzeTime = ToTime(v); break;
            case "authorScore": map.AuthorScore = v is null ? null : v.GetValue<int>(); break;
            case "nbLaps": map.NbLaps = Int(v); break;
            case "isLapRace": map.IsLapRace = v!.GetValue<bool>(); break;
            case "playMode": map.Mode = Enum.Parse<CGameCtnChallenge.PlayMode>(v!.GetValue<string>()); break;
            case "cost": map.Cost = Int(v); break;
            case "createdWithSimpleEditor": map.CreatedWithSimpleEditor = v!.GetValue<bool>(); break;
            case "hasGhostBlocks": map.HasGhostBlocks = v!.GetValue<bool>(); break;
            case "decoration":
                map.Decoration = new Ident(v!.GetValue<string>(), map.Decoration.Collection, map.Decoration.Author);
                break;
            case "size":
                var size = ChangeValue<ManifestInt3>(v)!;
                map.Size = new Int3(size.X, size.Y, size.Z);
                break;
            case "collection":
                log.Add("!mapInfo.collection changes are not materializable yet (environment change)");
                break;
            default:
                log.Add($"!mapInfo.{change.Key} is not materializable yet");
                break;
        }

        log.Add($"~mapInfo.{change.Key}");
    }

    // ---------- embedded ----------

    private static void ApplyEmbeddedChange(CGameCtnChallenge map, CGameCtnChallenge? theirs, ManifestChange change, List<string> log)
    {
        var target = ChangeValue<ManifestEmbedded>(change.OtherValue);
        if (target is null)
        {
            return;
        }

        if (map.EmbeddedZipData is null || map.EmbeddedZipData.Length == 0)
        {
            log.Add($"!embedded: source map has no embedded data; target expects {target.Entries.Count} entries");
            return;
        }

        try
        {
            using var theirsArchive = theirs is null ? null : theirs.OpenReadEmbeddedZipData();
            map.UpdateEmbeddedZipData(ours =>
            {
                var oursEntries = ours.Entries.Where(e => !string.IsNullOrEmpty(e.Name)).ToList();
                var targetEntries = target.Entries.ToList();

                // remove entries not in target
                foreach (var entry in oursEntries)
                {
                    if (targetEntries.All(t => t.Name != entry.FullName))
                    {
                        entry.Delete();
                        log.Add($"-embedded {entry.FullName}");
                    }
                }

                // add entries (or replace entries whose fingerprint changed) from theirs
                foreach (var t in targetEntries)
                {
                    var existing = oursEntries.FirstOrDefault(e => e.FullName == t.Name);
                    if (existing is not null)
                    {
                        continue; // same name kept as-is; fingerprint differences were resolved as "ours"
                    }

                    var source = theirsArchive?.Entries.FirstOrDefault(e => e.FullName == t.Name);
                    if (source is null)
                    {
                        log.Add($"!embedded {t.Name}: content not available in theirs; skipped");
                        continue;
                    }

                    var newEntry = ours.CreateEntry(t.Name);
                    using var src = source.Open();
                    using var dst = newEntry.Open();
                    src.CopyTo(dst);
                    log.Add($"+embedded {t.Name}");
                }
            });
        }
        catch (Exception ex)
        {
            log.Add($"!embedded update failed: {ex.Message}");
        }
    }

    // ---------- helpers ----------

    private static T? ChangeValue<T>(JsonNode? node) where T : class =>
        node?.Deserialize<T>(CanonicalJson.Options);

    private static string? String(JsonNode? node) => node?.GetValue<string>();

    private static int Int(JsonNode? node) => node is null ? 0 : node.GetValue<int>();

    private static TmEssentials.TimeInt32? ToTime(JsonNode? node) =>
        node is null ? null : new TmEssentials.TimeInt32(node.GetValue<int>());

    private static bool Close(Vec3 a, ManifestVec3 b) =>
        MathF.Abs(a.X - b.X) < 0.001f && MathF.Abs(a.Y - b.Y) < 0.001f && MathF.Abs(a.Z - b.Z) < 0.001f;

    private static bool CloseTo(Vec3? a, ManifestVec3 b) => a is not null && Close(a.Value, b);
}
