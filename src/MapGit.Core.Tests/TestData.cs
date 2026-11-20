using MapGit.Core.Manifest;

namespace MapGit.Core.Tests;

internal static class TestData
{
    public static ManifestMapInfo Info() => new()
    {
        Name = "Test Map",
        Comments = "",
        AuthorLogin = "author",
        Collection = "Stadium",
        Decoration = "Sunrise",
        TitleId = "Trackmania",
        MapType = "Trackmania\\Race",
        MapStyle = "",
        AuthorTimeMs = 30000,
        GoldTimeMs = 31000,
        SilverTimeMs = 32000,
        BronzeTimeMs = 33000,
        AuthorScore = null,
        NbLaps = 0,
        IsLapRace = false,
        PlayMode = "TimeAttack",
        Cost = 0,
        Size = new ManifestInt3(32, 8, 32),
        CreatedWithSimpleEditor = false,
        HasGhostBlocks = false,
    };

    public static ManifestBlock Block(string key, string name, string color = "Primary") => new()
    {
        Key = key,
        Name = name,
        IsFree = false,
        IsGhost = false,
        IsGround = false,
        IsClip = false,
        IsPillar = false,
        Coord = new ManifestInt3(0, 0, 0),
        Direction = 0,
        Variant = 0,
        SubVariant = 0,
        Color = color,
        LightmapQuality = "Standard",
        FreePosition = null,
        FreeRotation = null,
        HasSkin = false,
        SkinFile = null,
        SkinUrl = null,
        HasWaypointProps = false,
        DecalId = null,
        HasMacroblockRef = false,
    };

    public static ManifestItem Item(string key, string model) => new()
    {
        Key = key,
        ItemModel = model,
        Position = new ManifestVec3(0, 0, 0),
        Rotation = new ManifestVec3(0, 0, 0),
        Scale = null,
        Pivot = null,
        Color = "Primary",
        LightmapQuality = "Standard",
        HasSkin = false,
        SkinFile = null,
        SkinUrl = null,
        HasWaypointProps = false,
    };

    public static ManifestEmbedded Emb(params string[] shas) => new()
    {
        EntryCount = shas.Length,
        Entries = shas.Select((s, i) => new ManifestEmbeddedEntry($"item{i}.Item.Gbx", 100, s)).ToList(),
    };

    public static MapManifest MakeManifest(
        IEnumerable<ManifestBlock>? blocks = null,
        IEnumerable<ManifestItem>? items = null,
        ManifestMapInfo? info = null,
        ManifestEmbedded? embedded = null) => new()
    {
        MapInfo = info ?? Info(),
        Blocks = (blocks ?? []).ToList(),
        Items = (items ?? []).ToList(),
        Embedded = embedded ?? new ManifestEmbedded { EntryCount = 0, Entries = [] },
    };
}
