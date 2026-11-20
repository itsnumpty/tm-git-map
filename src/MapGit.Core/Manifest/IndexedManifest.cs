using System.Text.Json;
using System.Text.Json.Nodes;

namespace MapGit.Core.Manifest;

/// <summary>
/// A manifest projected into a merge-friendly shape: keyed block/item maps, field-addressable
/// map info and atomic embedded section. All manipulation happens on JSON nodes so merge,
/// diff and rebuild share one uniform representation.
/// </summary>
internal sealed class IndexedManifest
{
    private const string SchemaVersionName = "schemaVersion";
    private const string MapInfoName = "mapInfo";
    private const string BlocksName = "blocks";
    private const string ItemsName = "items";
    private const string EmbeddedName = "embedded";
    private const string KeyName = "key";

    public required string SchemaVersion { get; init; }
    public required JsonObject MapInfo { get; init; }
    public required Dictionary<string, JsonObject> Blocks { get; init; }
    public required Dictionary<string, JsonObject> Items { get; init; }
    public required JsonObject Embedded { get; set; }

    public static IndexedManifest From(MapManifest manifest)
    {
        var root = (JsonObject)JsonSerializer.SerializeToNode(manifest, CanonicalJson.Options)!;
        return new IndexedManifest
        {
            SchemaVersion = (string)root[SchemaVersionName]!,
            MapInfo = (JsonObject)root[MapInfoName]!.DeepClone(),
            Blocks = ToKeyed((JsonArray)root[BlocksName]!),
            Items = ToKeyed((JsonArray)root[ItemsName]!),
            Embedded = (JsonObject)root[EmbeddedName]!.DeepClone(),
        };
    }

    public MapManifest ToManifest()
    {
        var root = new JsonObject
        {
            [SchemaVersionName] = SchemaVersion,
            [MapInfoName] = MapInfo.DeepClone(),
            [BlocksName] = ToSortedArray(Blocks),
            [ItemsName] = ToSortedArray(Items),
            [EmbeddedName] = Embedded.DeepClone(),
        };
        return root.Deserialize<MapManifest>(CanonicalJson.Options)
            ?? throw new InvalidOperationException("Failed to rebuild manifest from indexed form.");
    }

    private static Dictionary<string, JsonObject> ToKeyed(JsonArray array)
    {
        var dict = new Dictionary<string, JsonObject>();
        foreach (var node in array)
        {
            var obj = (JsonObject)node!;
            var key = (string)obj[KeyName]!;
            dict[key] = obj;
        }
        return dict;
    }

    private static JsonArray ToSortedArray(Dictionary<string, JsonObject> keyed) =>
        new(keyed
            .OrderBy(kv => kv.Key, StringComparer.Ordinal)
            .Select(kv => kv.Value.DeepClone())
            .ToArray());
}
