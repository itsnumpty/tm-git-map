using MapGit.Core.Manifest;
using Xunit;
using static MapGit.Core.Tests.TestData;

namespace MapGit.Core.Tests;

public class ManifestCanonicalizerTests
{
    [Fact]
    public void duplicate_grid_blocks_get_deterministic_suffixes()
    {
        var manifest = MakeManifest([Block("", "Zeta"), Block("", "Alpha")]);

        var canonical = ManifestCanonicalizer.Canonicalize(manifest);

        // Same cell, different content (blockmix duplicate): Alpha sorts first by name,
        // Zeta gets the deterministic suffix.
        Assert.Equal("b:0,0,0", canonical.Blocks[0].Key);
        Assert.Equal("Alpha", canonical.Blocks[0].Name);
        Assert.Equal("b:0,0,0#2", canonical.Blocks[1].Key);
        Assert.Equal("Zeta", canonical.Blocks[1].Name);
    }

    [Fact]
    public void ghost_and_normal_block_in_same_cell_coexist()
    {
        var manifest = MakeManifest([Block("", "Road", "Primary") with { IsGhost = true }, Block("", "Road")]);

        var canonical = ManifestCanonicalizer.Canonicalize(manifest);

        Assert.Equal(2, canonical.Blocks.Count);
        Assert.Equal(["b:0,0,0", "b:0,0,0#gh"], canonical.Blocks.Select(b => b.Key).ToArray());
    }

    [Fact]
    public void free_block_key_uses_rounded_position_and_rotation()
    {
        var free = Block("", "Platform") with
        {
            IsFree = true,
            FreePosition = new ManifestVec3(1.237f, -2.5f, 0f),
            FreeRotation = new ManifestVec3(10.126f, 0f, 0f),
        };

        Assert.Equal("f:1.237,-2.500,0.000|10.13,0.00,0.00", ManifestKeys.Block(free));
    }

    [Fact]
    public void item_key_uses_rounded_position_and_rotation()
    {
        var item = Item("", "Tree.Item.Gbx") with
        {
            Position = new ManifestVec3(3.456f, 1.5f, 2f),
            Rotation = new ManifestVec3(90f, 0.5f, 179.994f),
        };

        Assert.Equal("i:3.456,1.500,2.000|90.00,0.50,179.99", ManifestKeys.Item(item));
    }

    [Fact]
    public void same_cell_duplicates_are_ordered_by_content_not_input_order()
    {
        // Real-world case from Ninconpoop (F15): two DecoCliffVFC blocks in one cell; the
        // game reorders them between saves, and a non-total sort made the "#2" suffix flip
        // between identical-key blocks, producing false direction/variant diffs.
        var b1 = Block("", "DecoCliffVFC") with { Direction = 1, Variant = 4 };
        var b2 = Block("", "DecoCliffVFC") with { Direction = 0, Variant = 2 };

        var m1 = ManifestCanonicalizer.Canonicalize(MakeManifest([b1, b2]));
        var m2 = ManifestCanonicalizer.Canonicalize(MakeManifest([b2, b1]));

        Assert.Equal(m1.SerializeToCanonicalJson(), m2.SerializeToCanonicalJson());

        // Content ordering is deterministic: variant 2 gets the plain key, variant 4 the suffix.
        Assert.Equal(2, m1.Blocks[0].Variant);
        Assert.Equal("b:0,0,0", m1.Blocks[0].Key);
        Assert.Equal(4, m1.Blocks[1].Variant);
        Assert.Equal("b:0,0,0#2", m1.Blocks[1].Key);
    }

    [Fact]
    public void canonical_json_roundtrip_is_byte_stable()
    {
        var manifest = MakeManifest(
            blocks: [Block("b:1,2,3", "Road"), Block("b:1,2,3", "Road") with { IsGhost = true }],
            items: [Item("i:1.000,2.000,3.000|0.00,90.00,0.00", "Tree.Item.Gbx")]);

        var canonical = ManifestCanonicalizer.Canonicalize(manifest);

        var json1 = canonical.SerializeToCanonicalJson();
        var roundtripped = MapManifest.Deserialize(json1);
        var json2 = roundtripped.SerializeToCanonicalJson();

        Assert.Equal(json1, json2);
        Assert.Equal(canonical.ComputeHash(), roundtripped.ComputeHash());
    }

    [Fact]
    public void canonicalization_is_idempotent()
    {
        var manifest = MakeManifest([Block("", "Road"), Block("", "Road"), Block("", "Wall")]);

        var once = ManifestCanonicalizer.Canonicalize(manifest);
        var twice = ManifestCanonicalizer.Canonicalize(once);

        // Records do not give structural equality through list properties, so compare the canonical form.
        Assert.Equal(once.SerializeToCanonicalJson(), twice.SerializeToCanonicalJson());
        Assert.Equal(once.ComputeHash(), twice.ComputeHash());
    }
}
