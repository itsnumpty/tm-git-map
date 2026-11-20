using MapGit.Core.Merge;
using MapGit.Core.Manifest;
using Xunit;
using static MapGit.Core.Tests.TestData;

namespace MapGit.Core.Tests;

public class MergeScenarioTests
{
    [Fact]
    public void clean_union_of_independent_additions()
    {
        var @base = MakeManifest([Block("b:10,1,10", "Road"), Block("b:10,1,11", "Road")]);
        var ours = MakeManifest([Block("b:10,1,10", "Road"), Block("b:10,1,11", "Road"), Block("b:20,1,20", "Wall")]);
        var theirs = MakeManifest([Block("b:10,1,10", "Road"), Block("b:10,1,11", "Road"), Block("b:30,1,30", "Grass")]);

        var result = ThreeWayMerge.Merge(@base, ours, theirs);

        Assert.Equal(MergeStatus.Clean, result.Status);
        Assert.Equal(4, result.Merged!.Blocks.Count);
        Assert.Contains(result.Merged.Blocks, b => b.Name == "Wall" && b.Key == "b:20,1,20");
        Assert.Contains(result.Merged.Blocks, b => b.Name == "Grass" && b.Key == "b:30,1,30");
        Assert.Single(result.AppliedChanges); // only theirs' addition is applied onto ours
    }

    [Fact]
    public void identical_additions_on_both_sides_do_not_conflict()
    {
        var @base = MakeManifest([Block("b:1,1,1", "Road")]);
        var ours = MakeManifest([Block("b:1,1,1", "Road"), Block("b:2,1,2", "Wall", "Red")]);
        var theirs = MakeManifest([Block("b:1,1,1", "Road"), Block("b:2,1,2", "Wall", "Red")]);

        var result = ThreeWayMerge.Merge(@base, ours, theirs);

        Assert.Equal(MergeStatus.Clean, result.Status);
        Assert.Equal(2, result.Merged!.Blocks.Count);
        Assert.Empty(result.AppliedChanges);
    }

    [Fact]
    public void add_add_with_different_content_conflicts()
    {
        var @base = MakeManifest([Block("b:1,1,1", "Road")]);
        var ours = MakeManifest([Block("b:1,1,1", "Road"), Block("b:5,1,5", "Wall")]);
        var theirs = MakeManifest([Block("b:1,1,1", "Road"), Block("b:5,1,5", "Tree")]);

        var result = ThreeWayMerge.Merge(@base, ours, theirs);

        Assert.Equal(MergeStatus.Conflicted, result.Status);
        Assert.Null(result.Merged);
        var conflict = Assert.Single(result.Conflicts);
        Assert.Equal(MergeConflictKind.AddAdd, conflict.Kind);
        Assert.Equal("b:5,1,5", conflict.Key);
        Assert.Equal("Wall", conflict.OursSummary);
        Assert.Equal("Tree", conflict.TheirsSummary);
    }

    [Fact]
    public void modification_only_on_theirs_applies()
    {
        var @base = MakeManifest([Block("b:1,1,1", "Road")]);
        var ours = MakeManifest([Block("b:1,1,1", "Road")]);
        var theirs = MakeManifest([Block("b:1,1,1", "Road", "Red")]);

        var result = ThreeWayMerge.Merge(@base, ours, theirs);

        Assert.Equal(MergeStatus.Clean, result.Status);
        Assert.Equal("Red", Assert.Single(result.Merged!.Blocks).Color);
        Assert.Single(result.AppliedChanges);
    }

    [Fact]
    public void modification_only_on_ours_is_kept()
    {
        var @base = MakeManifest([Block("b:1,1,1", "Road")]);
        var ours = MakeManifest([Block("b:1,1,1", "Road", "Red")]);
        var theirs = MakeManifest([Block("b:1,1,1", "Road")]);

        var result = ThreeWayMerge.Merge(@base, ours, theirs);

        Assert.Equal(MergeStatus.Clean, result.Status);
        Assert.Empty(result.AppliedChanges);
        Assert.Equal("Red", Assert.Single(result.Merged!.Blocks).Color);
    }

    [Fact]
    public void modify_modify_conflicts()
    {
        var @base = MakeManifest([Block("b:1,1,1", "Road")]);
        var ours = MakeManifest([Block("b:1,1,1", "Road", "Red")]);
        var theirs = MakeManifest([Block("b:1,1,1", "Road", "Blue")]);

        var result = ThreeWayMerge.Merge(@base, ours, theirs);

        Assert.Equal(MergeStatus.Conflicted, result.Status);
        var conflict = Assert.Single(result.Conflicts);
        Assert.Equal(MergeConflictKind.ModifyModify, conflict.Kind);
        Assert.Equal("b:1,1,1", conflict.Key);
        Assert.Equal("Road", conflict.OursSummary);   // summaries name the object; the differing fields are in the values
        Assert.Equal("Road", conflict.TheirsSummary);
    }

    [Fact]
    public void removal_by_theirs_applies_when_ours_unchanged()
    {
        var @base = MakeManifest([Block("b:1,1,1", "Road"), Block("b:2,1,2", "Wall")]);
        var ours = MakeManifest([Block("b:1,1,1", "Road"), Block("b:2,1,2", "Wall")]);
        var theirs = MakeManifest([Block("b:1,1,1", "Road")]);

        var result = ThreeWayMerge.Merge(@base, ours, theirs);

        Assert.Equal(MergeStatus.Clean, result.Status);
        Assert.Equal("Road", Assert.Single(result.Merged!.Blocks).Name);
        Assert.Contains("take theirs: -block", Assert.Single(result.AppliedChanges));
    }

    [Fact]
    public void removal_on_both_sides_is_fine()
    {
        var @base = MakeManifest([Block("b:1,1,1", "Road"), Block("b:2,1,2", "Wall")]);
        var ours = MakeManifest([Block("b:1,1,1", "Road")]);
        var theirs = MakeManifest([Block("b:1,1,1", "Road")]);

        var result = ThreeWayMerge.Merge(@base, ours, theirs);

        Assert.Equal(MergeStatus.Clean, result.Status);
        Assert.Single(result.Merged!.Blocks);
    }

    [Fact]
    public void theirs_deleted_ours_modified_conflicts()
    {
        var @base = MakeManifest([Block("b:1,1,1", "Road")]);
        var ours = MakeManifest([Block("b:1,1,1", "Road", "Red")]);
        var theirs = MakeManifest([]);

        var result = ThreeWayMerge.Merge(@base, ours, theirs);

        Assert.Equal(MergeStatus.Conflicted, result.Status);
        var conflict = Assert.Single(result.Conflicts);
        Assert.Equal(MergeConflictKind.ModifyDelete, conflict.Kind);
        Assert.Equal("(deleted)", conflict.TheirsSummary);
    }

    [Fact]
    public void theirs_modified_ours_deleted_conflicts()
    {
        var @base = MakeManifest([Block("b:1,1,1", "Road")]);
        var ours = MakeManifest([]);
        var theirs = MakeManifest([Block("b:1,1,1", "Road", "Red")]);

        var result = ThreeWayMerge.Merge(@base, ours, theirs);

        Assert.Equal(MergeStatus.Conflicted, result.Status);
        var conflict = Assert.Single(result.Conflicts);
        Assert.Equal(MergeConflictKind.DeleteModify, conflict.Kind);
        Assert.Equal("(deleted)", conflict.OursSummary);
    }

    [Fact]
    public void metadata_fields_merge_independently()
    {
        var @base = MakeManifest();
        var ours = MakeManifest(info: Info() with { Name = "Ours Name" });
        var theirs = MakeManifest(info: Info() with { Comments = "changed by theirs", AuthorTimeMs = 25000 });

        var result = ThreeWayMerge.Merge(@base, ours, theirs);

        Assert.Equal(MergeStatus.Clean, result.Status);
        Assert.Equal(2, result.AppliedChanges.Count);
        Assert.Equal("Ours Name", result.Merged!.MapInfo.Name);
        Assert.Equal("changed by theirs", result.Merged.MapInfo.Comments);
        Assert.Equal(25000, result.Merged.MapInfo.AuthorTimeMs);
    }

    [Fact]
    public void metadata_field_changed_on_both_sides_conflicts()
    {
        var @base = MakeManifest();
        var ours = MakeManifest(info: Info() with { Name = "A name" });
        var theirs = MakeManifest(info: Info() with { Name = "B name" });

        var result = ThreeWayMerge.Merge(@base, ours, theirs);

        Assert.Equal(MergeStatus.Conflicted, result.Status);
        var conflict = Assert.Single(result.Conflicts);
        Assert.Equal(MergeConflictKind.Metadata, conflict.Kind);
        Assert.Equal("name", conflict.Key);
    }

    [Fact]
    public void embedded_changed_only_by_theirs_applies()
    {
        var @base = MakeManifest(embedded: Emb("shaB"));
        var ours = MakeManifest(embedded: Emb("shaB"));
        var theirs = MakeManifest(embedded: Emb("shaT"));

        var result = ThreeWayMerge.Merge(@base, ours, theirs);

        Assert.Equal(MergeStatus.Clean, result.Status);
        Assert.Equal("shaT", Assert.Single(result.Merged!.Embedded.Entries).Fingerprint);
    }

    [Fact]
    public void embedded_changed_on_both_sides_conflicts()
    {
        var @base = MakeManifest(embedded: Emb("shaB"));
        var ours = MakeManifest(embedded: Emb("shaO"));
        var theirs = MakeManifest(embedded: Emb("shaT"));

        var result = ThreeWayMerge.Merge(@base, ours, theirs);

        Assert.Equal(MergeStatus.Conflicted, result.Status);
        var conflict = Assert.Single(result.Conflicts);
        Assert.Equal(MergeConflictKind.Embedded, conflict.Kind);
    }

    [Fact]
    public void items_union_and_item_conflicts()
    {
        var @base = MakeManifest(items: [Item("i:1.000,0.000,0.000|0.00,0.00,0.00", "Tree.Item.Gbx")]);
        var ours = MakeManifest(items:
        [
            Item("i:1.000,0.000,0.000|0.00,0.00,0.00", "Tree.Item.Gbx"),
            Item("i:5.000,0.000,0.000|0.00,0.00,0.00", "Rock.Item.Gbx"),
        ]);
        var theirs = MakeManifest(items:
        [
            Item("i:1.000,0.000,0.000|0.00,0.00,0.00", "Tree.Item.Gbx"),
            Item("i:9.000,0.000,0.000|0.00,0.00,0.00", "Sign.Item.Gbx"),
            Item("i:5.000,0.000,0.000|0.00,0.00,0.00", "Bush.Item.Gbx"),
        ]);

        var result = ThreeWayMerge.Merge(@base, ours, theirs);

        Assert.Equal(MergeStatus.Conflicted, result.Status);
        var conflict = Assert.Single(result.Conflicts);
        Assert.Equal(MergeConflictKind.AddAdd, conflict.Kind);
        Assert.Equal("Rock.Item.Gbx", conflict.OursSummary);
        Assert.Equal("Bush.Item.Gbx", conflict.TheirsSummary);
    }

    [Fact]
    public void blocks_and_items_and_metadata_merge_together()
    {
        var @base = MakeManifest(
            blocks: [Block("b:1,1,1", "Road")],
            items: [Item("i:1.000,0.000,0.000|0.00,0.00,0.00", "Tree.Item.Gbx")]);

        var ours = MakeManifest(
            blocks: [Block("b:1,1,1", "Road"), Block("b:2,1,2", "Wall")],
            items: [Item("i:1.000,0.000,0.000|0.00,0.00,0.00", "Tree.Item.Gbx")],
            info: Info() with { BronzeTimeMs = 35000 });

        var theirs = MakeManifest(
            blocks: [Block("b:1,1,1", "Road", "Red")],
            items: [Item("i:1.000,0.000,0.000|0.00,0.00,0.00", "Tree.Item.Gbx"), Item("i:7.000,0.000,0.000|0.00,0.00,0.00", "Bench.Item.Gbx")],
            info: Info() with { SilverTimeMs = 31500 });

        var result = ThreeWayMerge.Merge(@base, ours, theirs);

        Assert.Equal(MergeStatus.Clean, result.Status);
        Assert.Equal(2, result.Merged!.Blocks.Count);
        Assert.Equal(2, result.Merged.Items.Count);
        Assert.Equal("Red", result.Merged.Blocks.Single(b => b.Key == "b:1,1,1").Color);
        Assert.Equal(35000, result.Merged.MapInfo.BronzeTimeMs);
        Assert.Equal(31500, result.Merged.MapInfo.SilverTimeMs);
    }
}
