using MapGit.Core.Manifest;
using MapGit.Core.Merge;
using MapGit.Maps;
using MapGit.Repo;
using Xunit;

namespace MapGit.Core.Tests;

/// <summary>
/// End-to-end repository flows on a real map (fixtures/maps/vanilla.Map.Gbx):
/// init → edit → commit → branch → diverge → merge, with the materialization
/// verification invariant enforced inside MapRepository.Merge.
/// </summary>
public class RepoFlowTests
{
    private static string RepoRoot()
    {
        var dir = new DirectoryInfo(AppContext.BaseDirectory);
        while (dir is not null && !Directory.Exists(Path.Combine(dir.FullName, "fixtures")))
        {
            dir = dir.Parent;
        }

        return dir?.FullName ?? throw new InvalidOperationException("repo root not found");
    }

    private static string VanillaMap => Path.Combine(RepoRoot(), "fixtures", "maps", "vanilla.Map.Gbx");

    private static string TempDir() => Path.Combine(Path.GetTempPath(), "mapgit-repo-" + Guid.NewGuid().ToString("N"));

    private static string WorkFile(string repoDir) => Path.Combine(repoDir, "work", "map.Map.Gbx");

    private static MapManifest WorkManifest(string repoDir) => MapFile.ExtractManifest(WorkFile(repoDir));

    private static (string Name, string Color, string Lm) BlockTemplate(IEnumerable<ManifestBlock> blocks)
    {
        var b = blocks.First(x => !x.IsFree && !x.IsGhost && !x.HasSkin && !x.HasWaypointProps && x.DecalId is null);
        return (b.Name, b.Color, b.LightmapQuality);
    }

    private static (int X, int Y, int Z) FreeCoord(MapManifest m)
    {
        var used = m.Blocks.Where(b => !b.IsFree).Select(b => (b.Coord.X, b.Coord.Y, b.Coord.Z)).ToHashSet();
        for (var z = 2; z < 40; z++)
        {
            for (var y = 1; y < 8; y++)
            {
                for (var x = 2; x < 40; x++)
                {
                    if (!used.Contains((x, y, z)))
                    {
                        return (x, y, z);
                    }
                }
            }
        }

        throw new InvalidOperationException("no free coordinate found");
    }

    private static void PlaceGridBlock(string repoDir, string name, string color, string lm, int x, int y, int z)
    {
        var work = WorkFile(repoDir);
        var gbx = MapFile.Parse(work);
        MapMaterializer.PlaceManifestBlock(gbx.Node, new ManifestBlock
        {
            Key = "",
            Name = name,
            IsFree = false,
            IsGhost = false,
            IsGround = false,
            IsClip = false,
            IsPillar = false,
            Coord = new ManifestInt3(x, y, z),
            Direction = 0,
            Variant = 0,
            SubVariant = 0,
            Color = color,
            LightmapQuality = lm,
            FreePosition = null,
            FreeRotation = null,
            HasSkin = false,
            SkinFile = null,
            SkinUrl = null,
            HasWaypointProps = false,
            DecalId = null,
            HasMacroblockRef = false,
        });
        gbx.Save(work);
    }

    private void WithTempRepo(Action<MapRepository, string> test)
    {
        var dir = TempDir();
        try
        {
            var repo = MapRepository.Init(VanillaMap, dir, "Tester");
            test(repo, dir);
        }
        finally
        {
            try
            {
                Directory.Delete(dir, recursive: true);
            }
            catch
            {
                // best effort
            }
        }
    }

    [Fact]
    public void init_commit_and_status_flow()
    {
        WithTempRepo((repo, dir) =>
        {
            Assert.Equal(MapRepository.MainBranch, repo.CurrentBranch);
            Assert.True(repo.Status().Clean);

            var head0 = repo.Head!;
            var template = BlockTemplate(WorkManifest(dir).Blocks);
            var (x, y, z) = FreeCoord(WorkManifest(dir));

            PlaceGridBlock(dir, template.Name, template.Color, template.Lm, x, y, z);

            var dirty = repo.Status();
            Assert.False(dirty.Clean);
            Assert.Equal(1, dirty.Added);
            Assert.Equal(0, dirty.Removed);

            var commit = repo.CommitWorking("Tester", "add one block");
            Assert.NotNull(commit);
            Assert.Equal([head0.Id], commit!.Parents);
            Assert.Equal("add one block", commit.Message);
            Assert.True(repo.Status().Clean);
            Assert.Equal(2, repo.Log().Count);

            // committing again without changes is a no-op
            Assert.Null(repo.CommitWorking("Tester", "should be skipped"));
        });
    }

    [Fact]
    public void checkout_restores_branch_content()
    {
        WithTempRepo((repo, dir) =>
        {
            var initManifest = WorkManifest(dir);
            var template = BlockTemplate(initManifest.Blocks);
            var (x, y, z) = FreeCoord(initManifest);

            repo.CreateBranch("snapshot");
            PlaceGridBlock(dir, template.Name, template.Color, template.Lm, x, y, z);
            Assert.NotNull(repo.CommitWorking("Tester", "add block on main"));

            // snapshot branch still has the original content
            repo.Checkout("snapshot");
            Assert.Equal(initManifest.ComputeHash(), WorkManifest(dir).ComputeHash());

            // main still has the block
            repo.Checkout("main");
            Assert.Contains(WorkManifest(dir).Blocks, b => b.Coord.X == x && b.Coord.Y == y && b.Coord.Z == z);
        });
    }

    [Fact]
    public void branch_merge_produces_clean_union()
    {
        WithTempRepo((repo, dir) =>
        {
            var template = BlockTemplate(WorkManifest(dir).Blocks);
            var (ax, ay, az) = FreeCoord(WorkManifest(dir));

            repo.CreateBranch("bob");
            repo.Checkout("bob");
            PlaceGridBlock(dir, template.Name, template.Color, template.Lm, ax, ay, az);
            Assert.NotNull(repo.CommitWorking("Bob", "bob adds a block"));

            repo.Checkout("main");
            var (bx, by, bz) = FreeCoord(WorkManifest(dir));
            PlaceGridBlock(dir, template.Name, template.Color, template.Lm, bx, by, bz);
            Assert.NotNull(repo.CommitWorking("Alice", "alice adds a different block"));

            var outcome = repo.Merge("bob", "Alice", "bob's scenery");
            Assert.True(outcome.Success, outcome.Message);
            Assert.Empty(outcome.Conflicts);

            // union: both blocks present in the materialized working map
            var merged = WorkManifest(dir);
            Assert.Contains(merged.Blocks, b => b.Coord.X == ax && b.Coord.Y == ay && b.Coord.Z == az);
            Assert.Contains(merged.Blocks, b => b.Coord.X == bx && b.Coord.Y == by && b.Coord.Z == bz);

            // merge commit with two parents, clean tree
            var head = repo.Head!;
            Assert.Equal(2, head.Parents.Count);
            Assert.True(repo.Status().Clean);
            Assert.StartsWith("merge bob", head.Message);
        });
    }

    [Fact]
    public void conflicting_merge_reports_conflict_and_preserves_work()
    {
        WithTempRepo((repo, dir) =>
        {
            var manifest = WorkManifest(dir);
            var template = BlockTemplate(manifest.Blocks);
            var second = BlockTemplate(manifest.Blocks.Where(b => b.Name != template.Name));
            Assert.NotEqual(template.Name, second.Name); // guard the test's premise: genuinely different content
            var (x, y, z) = FreeCoord(manifest);

            repo.CreateBranch("bob");
            repo.Checkout("bob");
            PlaceGridBlock(dir, template.Name, template.Color, template.Lm, x, y, z);
            Assert.NotNull(repo.CommitWorking("Bob", "bob claims the cell"));

            repo.Checkout("main");
            PlaceGridBlock(dir, second.Name, second.Color, second.Lm, x, y, z);
            Assert.NotNull(repo.CommitWorking("Alice", "alice claims the same cell"));
            var mainManifest = WorkManifest(dir); // main's committed state before the merge attempt

            var outcome = repo.Merge("bob", "Alice", "conflicting builds");
            Assert.False(outcome.Success);
            var conflict = Assert.Single(outcome.Conflicts);
            Assert.Equal(MergeConflictKind.AddAdd, conflict.Kind);
            Assert.Equal($"b:{x},{y},{z}", conflict.Key);
            Assert.Equal(second.Name, conflict.OursSummary);   // ours = main (current branch)
            Assert.Equal(template.Name, conflict.TheirsSummary); // theirs = bob

            // no merge commit, working map untouched (still main's content)
            Assert.Single(repo.Head!.Parents);
            Assert.Equal(mainManifest.ComputeHash(), WorkManifest(dir).ComputeHash());
        });
    }

    [Fact]
    public void fast_forward_merge_takes_theirs_content()
    {
        WithTempRepo((repo, dir) =>
        {
            var template = BlockTemplate(WorkManifest(dir).Blocks);
            var (x, y, z) = FreeCoord(WorkManifest(dir));

            repo.CreateBranch("solo");
            repo.Checkout("solo");
            PlaceGridBlock(dir, template.Name, template.Color, template.Lm, x, y, z);
            var theirsCommit = repo.CommitWorking("Bob", "bob builds alone");

            repo.Checkout("main");
            var outcome = repo.Merge("solo", "Alice", "take bob's work");
            Assert.True(outcome.Success, outcome.Message);
            Assert.Contains(WorkManifest(dir).Blocks, b => b.Coord.X == x && b.Coord.Y == y && b.Coord.Z == z);
        });
    }

    [Fact]
    public void materializer_roundtrips_free_block_and_item()
    {
        var dir = TempDir();
        try
        {
            var mapPath = Path.Combine(dir, "map.Map.Gbx");
            Directory.CreateDirectory(dir);
            File.Copy(VanillaMap, mapPath);

            var gbx = MapFile.Parse(mapPath);
            var original = MapFile.ExtractManifest(gbx.Node);

            var freeBlock = original.Blocks.First(b =>
                b.IsFree && !b.HasSkin && !b.HasWaypointProps && b.DecalId is null && !b.HasMacroblockRef);
            var item = original.Items.First(i => !i.HasSkin && !i.HasWaypointProps);

            // 1) remove the free block and the item
            var without = original with
            {
                Blocks = original.Blocks.Where(b => b.Key != freeBlock.Key).ToList(),
                Items = original.Items.Where(i => i.Key != item.Key).ToList(),
            };
            MapMaterializer.Apply(gbx.Node, without);
            var step2 = Path.Combine(dir, "step2.Map.Gbx");
            gbx.Save(step2);
            Assert.Equal(without.ComputeHash(), MapFile.ExtractManifest(step2).ComputeHash());

            // 2) re-add them: materializing the original manifest must reproduce it exactly
            var gbx2 = MapFile.Parse(step2);
            MapMaterializer.Apply(gbx2.Node, original);
            var step3 = Path.Combine(dir, "step3.Map.Gbx");
            gbx2.Save(step3);
            Assert.Equal(original.ComputeHash(), MapFile.ExtractManifest(step3).ComputeHash());
        }
        finally
        {
            try
            {
                Directory.Delete(dir, recursive: true);
            }
            catch
            {
                // best effort
            }
        }
    }
}
