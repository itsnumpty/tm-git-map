using GBX.NET;
using GBX.NET.Engines.Game;
using GBX.NET.LZO;
using MapGit.Core.Manifest;

namespace MapGit.Maps;

/// <summary>Turns .Map.Gbx files into canonical manifests (via GBX.NET + GBX.NET.LZO).</summary>
public static class MapFile
{
    public static Gbx<CGameCtnChallenge> Parse(string path)
    {
        Gbx.LZO ??= new Lzo();
        return Gbx.Parse<CGameCtnChallenge>(path);
    }

    public static MapManifest ExtractManifest(string path)
    {
        var gbx = Parse(path);
        return ExtractManifest(gbx.Node);
    }

    public static MapManifest ExtractManifest(CGameCtnChallenge map)
    {
        var mapInfo = new ManifestMapInfo
        {
            Name = map.MapName ?? "",
            Comments = map.Comments ?? "",
            AuthorLogin = map.AuthorLogin ?? "",
            Collection = map.Collection ?? "",
            Decoration = map.Decoration.Id ?? "",
            TitleId = map.TitleId ?? "",
            // Times/score/type/style live in the header OR in ChallengeParameters
            // ("only used if ChallengeParameters is null"). The game moves them into
            // ChallengeParameters when a save bakes the map, so the fallback is
            // required for manifest stability across save cycles.
            MapType = map.MapType ?? map.ChallengeParameters?.MapType ?? "",
            MapStyle = map.MapStyle ?? map.ChallengeParameters?.MapStyle ?? "",
            AuthorTimeMs = map.AuthorTime?.TotalMilliseconds ?? Ms(map.ChallengeParameters?.AuthorTime),
            GoldTimeMs = map.GoldTime?.TotalMilliseconds ?? Ms(map.ChallengeParameters?.GoldTime),
            SilverTimeMs = map.SilverTime?.TotalMilliseconds ?? Ms(map.ChallengeParameters?.SilverTime),
            BronzeTimeMs = map.BronzeTime?.TotalMilliseconds ?? Ms(map.ChallengeParameters?.BronzeTime),
            AuthorScore = map.AuthorScore ?? map.ChallengeParameters?.AuthorScore,
            NbLaps = map.NbLaps,
            IsLapRace = map.IsLapRace,
            PlayMode = map.Mode.ToString(),
            Cost = map.Cost,
            Size = new ManifestInt3(map.Size.X, map.Size.Y, map.Size.Z),
            CreatedWithSimpleEditor = map.CreatedWithSimpleEditor,
            HasGhostBlocks = map.HasGhostBlocks,
        };

        var blocks = new List<ManifestBlock>();
        blocks.AddRange(map.GetBlocks().Select(ToManifestBlock));
        blocks.AddRange(map.GetBakedBlocks().Select(ToManifestBlock));

        var items = map.GetAnchoredObjects().Select(ToManifestItem).ToList();

        return ManifestCanonicalizer.Canonicalize(new MapManifest
        {
            MapInfo = mapInfo,
            Blocks = blocks,
            Items = items,
            Embedded = ExtractEmbedded(map),
        });
    }

    private static ManifestBlock ToManifestBlock(CGameCtnBlock b) => new()
    {
        Key = "",
        Name = b.Name ?? "",
        IsFree = b.IsFree,
        IsGhost = b.IsGhost,
        IsGround = b.IsGround,
        IsClip = b.IsClip,
        IsPillar = b.IsPillar,
        Coord = new ManifestInt3(b.Coord.X, b.Coord.Y, b.Coord.Z),
        Direction = (int)b.Direction,
        Variant = b.Variant,
        SubVariant = b.SubVariant,
        Color = b.Color.ToString(),
        LightmapQuality = b.LightmapQuality.ToString(),
        FreePosition = ToVec3(b.AbsolutePositionInMap),
        FreeRotation = ToVec3(b.YawPitchRoll),
        HasSkin = b.Skin is not null,
        SkinFile = b.Skin?.PackDesc?.FilePath,
        SkinUrl = b.Skin?.PackDesc?.LocatorUrl,
        HasWaypointProps = b.WaypointSpecialProperty is not null,
        DecalId = b.DecalId,
        HasMacroblockRef = b.MacroblockReference is not null,
    };

    private static ManifestItem ToManifestItem(CGameCtnAnchoredObject a) => new()
    {
        Key = "",
        ItemModel = a.ItemModel.Id ?? "",
        Position = ToVec3(a.AbsolutePositionInMap) ?? new ManifestVec3(0, 0, 0),
        Rotation = ToVec3(a.YawPitchRoll) ?? new ManifestVec3(0, 0, 0),
        Scale = a.Scale,
        Pivot = ToVec3(a.PivotPosition),
        Color = a.Color.ToString(),
        LightmapQuality = a.LightmapQuality.ToString(),
        HasSkin = a.PackDesc is not null,
        SkinFile = a.PackDesc?.FilePath,
        SkinUrl = a.PackDesc?.LocatorUrl,
        HasWaypointProps = a.WaypointSpecialProperty is not null,
    };

    private static ManifestEmbedded ExtractEmbedded(CGameCtnChallenge map)
    {
        var zip = map.EmbeddedZipData;
        if (zip is null || zip.Length == 0)
        {
            return new ManifestEmbedded { EntryCount = 0, Entries = [] };
        }

        var entries = new List<ManifestEmbeddedEntry>();
        try
        {
            using var archive = map.OpenReadEmbeddedZipData();
            foreach (var entry in archive.Entries)
            {
                if (string.IsNullOrEmpty(entry.Name))
                {
                    continue; // folder entries
                }

                using var stream = entry.Open();
                using var ms = new MemoryStream();
                stream.CopyTo(ms);
                var bytes = ms.ToArray();
                entries.Add(new ManifestEmbeddedEntry(
                    entry.FullName,
                    entry.Length,
                    TolerantHash.Fingerprint(bytes)));
            }
        }
        catch
        {
            // Zip unreadable — entries stay empty; this will surface as a diff flag.
        }

        return new ManifestEmbedded
        {
            EntryCount = entries.Count,
            Entries = entries,
        };
    }

    private static ManifestVec3? ToVec3(Vec3? v) =>
        v is null ? null : new ManifestVec3(v.Value.X, v.Value.Y, v.Value.Z);

    private static int? Ms(TmEssentials.TimeInt32? t) => t is null ? null : (int)t.Value.TotalMilliseconds;
}
