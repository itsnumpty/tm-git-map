namespace MapGit.Core.Manifest;

/// <summary>A float vector as extracted from the map (values kept exactly as parsed).</summary>
public sealed record ManifestVec3(float X, float Y, float Z);

/// <summary>An integer vector (block grid coordinates, map size).</summary>
public sealed record ManifestInt3(int X, int Y, int Z);

/// <summary>Mergeable map-level metadata (field-level 3-way merge).
/// NOTE: map uid is deliberately NOT here — the game regenerates it on every save,
/// so it must never take part in diffs/merges/hashes.
/// Repo identity comes from MapGit's own stable repo id instead.</summary>
public sealed record ManifestMapInfo
{
    public required string Name { get; init; }
    public required string Comments { get; init; }
    public required string AuthorLogin { get; init; }
    public required string Collection { get; init; }
    public required string Decoration { get; init; }
    public required string TitleId { get; init; }
    public required string? MapType { get; init; }
    public required string? MapStyle { get; init; }
    public required int? AuthorTimeMs { get; init; }
    public required int? GoldTimeMs { get; init; }
    public required int? SilverTimeMs { get; init; }
    public required int? BronzeTimeMs { get; init; }
    public required int? AuthorScore { get; init; }
    public required int NbLaps { get; init; }
    public required bool IsLapRace { get; init; }
    public required string PlayMode { get; init; }
    public required int Cost { get; init; }
    public required ManifestInt3 Size { get; init; }
    public required bool CreatedWithSimpleEditor { get; init; }
    public required bool HasGhostBlocks { get; init; }
}

/// <summary>
/// One placed block (grid, ghost or free). <see cref="Key"/> is the merge identity:
/// grid blocks are keyed by cell coordinates, free blocks by rounded position+rotation.
/// </summary>
public sealed record ManifestBlock
{
    public required string Key { get; init; }
    public required string Name { get; init; }
    public required bool IsFree { get; init; }
    public required bool IsGhost { get; init; }
    public required bool IsGround { get; init; }
    public required bool IsClip { get; init; }
    public required bool IsPillar { get; init; }
    public required ManifestInt3 Coord { get; init; }
    public required int Direction { get; init; }
    public required int Variant { get; init; }
    public required int SubVariant { get; init; }
    public required string Color { get; init; }
    public required string LightmapQuality { get; init; }
    public required ManifestVec3? FreePosition { get; init; }
    public required ManifestVec3? FreeRotation { get; init; }
    public required bool HasSkin { get; init; }
    public required string? SkinFile { get; init; }
    public required string? SkinUrl { get; init; }
    public required bool HasWaypointProps { get; init; }
    public required string? DecalId { get; init; }
    public required bool HasMacroblockRef { get; init; }
}

/// <summary>One anchored object (item). Keyed by rounded position + rotation.</summary>
public sealed record ManifestItem
{
    public required string Key { get; init; }
    public required string ItemModel { get; init; }
    public required ManifestVec3 Position { get; init; }
    public required ManifestVec3 Rotation { get; init; }
    public required float? Scale { get; init; }
    public required ManifestVec3? Pivot { get; init; }
    public required string Color { get; init; }
    public required string LightmapQuality { get; init; }
    public required bool HasSkin { get; init; }
    public required string? SkinFile { get; init; }
    public required string? SkinUrl { get; init; }
    public required bool HasWaypointProps { get; init; }
}

/// <summary>One entry of the embedded zip (custom item, media, ...). Fingerprint is a
/// float-noise-tolerant content hash (see <see cref="TolerantHash"/>) so the game
/// re-saving embedded items cannot cause false diffs.</summary>
public sealed record ManifestEmbeddedEntry(string Name, long Size, string Fingerprint);

/// <summary>
/// Embedded data fingerprint. Merged atomically: identical content dedupes for free,
/// diverging content is a conflict (never silently mixed). Keyed per entry (not the
/// whole zip) so the game re-zipping on save doesn't destabilize manifests.
/// </summary>
public sealed record ManifestEmbedded
{
    public required int EntryCount { get; init; }
    public required IReadOnlyList<ManifestEmbeddedEntry> Entries { get; init; }
}

/// <summary>
/// Deterministic, canonical text extraction of a map. Two saves of the same map content
/// (even via different serializers) must produce an identical <see cref="ComputeHash"/>.
/// Volatile data (thumbnail bytes, lightmap caches, media tracker internals) is
/// intentionally NOT part of the manifest; those are tracked as blob-level changes on commits.
/// </summary>
public sealed record MapManifest
{
    public const string CurrentSchemaVersion = "0.1";

    public string SchemaVersion { get; init; } = CurrentSchemaVersion;
    public required ManifestMapInfo MapInfo { get; init; }
    public required IReadOnlyList<ManifestBlock> Blocks { get; init; }
    public required IReadOnlyList<ManifestItem> Items { get; init; }
    public required ManifestEmbedded Embedded { get; init; }

    public byte[] SerializeToCanonicalJson() => CanonicalJson.Serialize(this);

    public static MapManifest Deserialize(byte[] canonicalJson) => CanonicalJson.Deserialize<MapManifest>(canonicalJson);

    /// <summary>Stable content hash (SHA-256 over the canonical JSON, lowercase hex).</summary>
    public string ComputeHash() => CanonicalJson.HexLower(SerializeToCanonicalJson());
}
