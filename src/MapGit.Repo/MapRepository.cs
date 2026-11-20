using System.IO.Compression;
using System.Security.Cryptography;
using System.Text.Json;
using GBX.NET.Engines.Game;
using MapGit.Core.Diff;
using MapGit.Core.Manifest;
using MapGit.Core.Merge;
using MapGit.Git;
using MapGit.Maps;

namespace MapGit.Repo;

public sealed record RepoMeta
{
    public required string RepoId { get; init; }
    public required string MapName { get; init; }
    public required string DefaultAuthor { get; init; }
    public required DateTimeOffset CreatedAt { get; init; }
    public required string EngineVersion { get; init; }
}

/// <summary>A MapGit commit; metadata travels in the git commit message header.</summary>
public sealed record MapCommit
{
    public required string Id { get; init; }
    public required IReadOnlyList<string> Parents { get; init; }
    public required string Author { get; init; }
    public required string Message { get; init; }
    public required DateTimeOffset Timestamp { get; init; }
    public required string ManifestHash { get; init; }
    public required string MapBlobHash { get; init; }
}

public sealed record RepoStatus
{
    public required string Branch { get; init; }
    public required MapCommit? Head { get; init; }
    public required bool Clean { get; init; }
    public required int Added { get; init; }
    public required int Removed { get; init; }
    public required int Modified { get; init; }
}

public sealed record MergeOutcome
{
    public required bool Success { get; init; }
    public required string Message { get; init; }
    public required IReadOnlyList<MergeConflict> Conflicts { get; init; }
    public required IReadOnlyList<string> AppliedChanges { get; init; }
    public MapCommit? Commit { get; init; }
}

/// <summary>
/// A map repository: the repo directory is a real git repository (branches are git
/// branches), plus a content-addressed object store for map blobs (Brotli) and
/// canonical manifests. The working map lives at work/map.Map.Gbx and is tracked by
/// git, so checkout restores branch content natively.
/// </summary>
public sealed class MapRepository
{
    public const string MainBranch = "main";
    private const string MessageHeader = "mapgit:v1";

    private readonly string _dir;

    private string WorkFile => Path.Combine(_dir, "work", "map.Map.Gbx");
    private string ObjectsDir => Path.Combine(_dir, "objects");

    private MapRepository(string dir) => _dir = dir;

    public string RepoDir => _dir;

    public RepoMeta Meta { get; private set; } = null!;

    // ---------- open / init ----------

    public static MapRepository Init(string mapFile, string repoDir, string author)
    {
        Directory.CreateDirectory(repoDir);
        GitBackend.Init(repoDir);

        var meta = new RepoMeta
        {
            RepoId = Guid.NewGuid().ToString("N"),
            MapName = Path.GetFileName(mapFile),
            DefaultAuthor = author,
            CreatedAt = DateTimeOffset.Now,
            EngineVersion = typeof(MapRepository).Assembly.GetName().Version?.ToString() ?? "0.0.0",
        };
        File.WriteAllText(Path.Combine(repoDir, "map.meta.json"), JsonSerializer.Serialize(meta, MetaOptions));

        Directory.CreateDirectory(Path.Combine(repoDir, "work"));
        File.Copy(mapFile, Path.Combine(repoDir, "work", "map.Map.Gbx"), overwrite: true);
        File.WriteAllText(Path.Combine(repoDir, ".gitattributes"), "*.gbx.brotli binary\n");

        var repo = Open(repoDir);
        repo.CommitWorking(author, $"init: {meta.MapName}");
        return repo;
    }

    private static readonly JsonSerializerOptions MetaOptions = new() { PropertyNameCaseInsensitive = true };

    public static MapRepository Open(string repoDir)
    {
        var metaPath = Path.Combine(repoDir, "map.meta.json");
        if (!File.Exists(metaPath))
        {
            throw new InvalidOperationException($"'{repoDir}' is not a mapgit repository (map.meta.json missing).");
        }

        return new MapRepository(repoDir)
        {
            Meta = JsonSerializer.Deserialize<RepoMeta>(File.ReadAllText(metaPath), MetaOptions)!,
        };
    }

    // ---------- basics ----------

    public MapCommit? Head =>
        GitBackend.HeadCommit(_dir) is { } sha ? ReadCommit(sha) : null;

    public string CurrentBranch => GitBackend.HeadBranch(_dir);

    public IReadOnlyList<string> Branches => GitBackend.Branches(_dir);

    public MapCommit ReadCommit(string sha)
    {
        var (id, message, parents, author, when) = GitBackend.ReadCommit(_dir, sha);
        return ParseCommit(id, message, parents, author, when);
    }

    public MapManifest GetManifest(MapCommit commit)
    {
        var path = Path.Combine(ObjectsDir, "manifests", $"{commit.ManifestHash}.json");
        if (File.Exists(path))
        {
            return MapManifest.Deserialize(File.ReadAllBytes(path));
        }

        // object files can be absent from the working tree after branch switches
        // (git removes files not in the current branch) — read from the commit's tree
        return MapManifest.Deserialize(GitBackend.ReadFileFromCommit(_dir, commit.Id, $"objects/manifests/{commit.ManifestHash}.json"));
    }

    private byte[] ReadBlob(MapCommit commit)
    {
        var relative = $"objects/maps/{commit.MapBlobHash}.gbx.brotli";
        var path = Path.Combine(_dir, relative);
        var compressed = File.Exists(path)
            ? File.ReadAllBytes(path)
            : GitBackend.ReadFileFromCommit(_dir, commit.Id, relative);

        using var input = new MemoryStream(compressed);
        using var brotli = new BrotliStream(input, CompressionMode.Decompress);
        using var ms = new MemoryStream();
        brotli.CopyTo(ms);
        return ms.ToArray();
    }

    /// <summary>Creates a commit from the working map. Returns null when there is nothing to commit
    /// (unchanged canonical manifest — volatile-only saves like uid/embedded churn are skipped).</summary>
    public MapCommit? CommitWorking(string author, string message, params string[] extraParents)
    {
        var manifest = MapFile.ExtractManifest(WorkFile);
        var manifestHash = manifest.ComputeHash();
        var blobHash = BlobStore.Store(ObjectsDir, File.ReadAllBytes(WorkFile));
        ManifestStore.Store(ObjectsDir, manifest);

        var head = Head;
        var parentList = new List<string>();
        if (head is not null)
        {
            parentList.Add(head.Id);
        }

        foreach (var parent in extraParents)
        {
            if (head is null || parent != head.Id)
            {
                parentList.Add(parent);
            }
        }

        var parents = parentList.Distinct().ToArray();

        if (head is not null && head.ManifestHash == manifestHash && parents.Length == head.Parents.Count)
        {
            return null; // nothing content-worthy changed
        }

        // unborn HEAD (first commit of a repo): the default branch name would be whatever
        // git chose ("master") — commit on our canonical MainBranch instead
        var branch = head is not null ? CurrentBranch : MainBranch;
        var sha = GitBackend.CommitAll(_dir, branch, author, FormatMessage(manifestHash, blobHash, message), parents);
        return ReadCommit(sha);
    }

    public void CreateBranch(string name)
    {
        GitBackend.CreateBranch(_dir, name);
    }

    public void Checkout(string branch)
    {
        if (!GitBackend.IsClean(_dir))
        {
            throw new InvalidOperationException("working map has uncommitted changes; commit or discard them first (like git).");
        }

        GitBackend.Checkout(_dir, branch);
    }

    public RepoStatus Status()
    {
        var head = Head;
        var manifest = MapFile.ExtractManifest(WorkFile);
        var clean = head is null || manifest.ComputeHash() == head.ManifestHash;

        var (added, removed, modified) = (0, 0, 0);
        if (!clean && head is not null)
        {
            foreach (var change in ManifestDiff.Compute(GetManifest(head), manifest))
            {
                switch (change.Kind)
                {
                    case ManifestChangeKind.Added: added++; break;
                    case ManifestChangeKind.Removed: removed++; break;
                    default: modified++; break;
                }
            }
        }

        return new RepoStatus
        {
            Branch = CurrentBranch,
            Head = head,
            Clean = clean,
            Added = added,
            Removed = removed,
            Modified = modified,
        };
    }

    public IReadOnlyList<MapCommit> Log(int max = 50)
    {
        var result = new List<MapCommit>();
        var seen = new HashSet<string>();
        var stack = new Stack<string>();
        if (GitBackend.HeadCommit(_dir) is { } head)
        {
            stack.Push(head);
        }

        while (stack.Count > 0 && result.Count < max)
        {
            var sha = stack.Pop();
            if (!seen.Add(sha))
            {
                continue;
            }

            var commit = ReadCommit(sha);
            result.Add(commit);
            foreach (var parent in commit.Parents)
            {
                stack.Push(parent);
            }
        }

        return result.OrderByDescending(c => c.Timestamp).ToList();
    }

    // ---------- merge ----------

    public MergeOutcome Merge(string branch, string author, string message)
    {
        var ours = Head ?? throw new InvalidOperationException("repository has no commits");
        var theirsSha = GitBackend.BranchHead(_dir, branch)
            ?? throw new InvalidOperationException($"branch '{branch}' not found");
        var theirs = ReadCommit(theirsSha);

        if (theirs.Id == ours.Id)
        {
            return new MergeOutcome { Success = true, Message = $"{branch} is already merged (same head).", Conflicts = [], AppliedChanges = [] };
        }

        var baseSha = GitBackend.FindMergeBase(_dir, ours.Id, theirs.Id)
            ?? throw new InvalidOperationException("branches have no common ancestor; refusing to merge unrelated histories");

        if (baseSha == ours.Id)
        {
            // fast-forward: take theirs' content wholesale
            File.WriteAllBytes(WorkFile, ReadBlob(theirs));
            var ff = CommitWorking(author, $"fast-forward {branch}: {message}");
            return new MergeOutcome { Success = true, Message = $"fast-forwarded to {branch}", Conflicts = [], AppliedChanges = ["fast-forward"], Commit = ff };
        }

        if (baseSha == theirsSha)
        {
            return new MergeOutcome { Success = true, Message = $"{branch} is behind the current branch; nothing to merge.", Conflicts = [], AppliedChanges = [] };
        }

        var baseCommit = ReadCommit(baseSha);
        var baseManifest = GetManifest(baseCommit);
        var oursManifest = GetManifest(ours);
        var theirsManifest = GetManifest(theirs);

        var result = ThreeWayMerge.Merge(baseManifest, oursManifest, theirsManifest);
        if (result.HasConflicts)
        {
            return new MergeOutcome
            {
                Success = false,
                Message = $"{result.Conflicts.Count} conflict(s) between {CurrentBranch} and {branch}",
                Conflicts = result.Conflicts,
                AppliedChanges = result.AppliedChanges,
            };
        }

        // materialize the merged content from ours' blob (theirs' blob provides embedded content)
        var oursBlobPath = Path.Combine(Path.GetTempPath(), $"mapgit-blob-{ours.MapBlobHash}.Map.Gbx");
        var theirsBlobPath = Path.Combine(Path.GetTempPath(), $"mapgit-blob-{theirs.MapBlobHash}.Map.Gbx");
        File.WriteAllBytes(oursBlobPath, ReadBlob(ours));
        File.WriteAllBytes(theirsBlobPath, ReadBlob(theirs));
        var oursBackup = File.ReadAllBytes(WorkFile);
        try
        {
            var gbx = MapFile.Parse(oursBlobPath);
            var theirsGbx = MapFile.Parse(theirsBlobPath);
            MapMaterializer.Apply(gbx.Node, result.Merged!, theirsGbx.Node);
            gbx.Save(WorkFile);

            // verification invariant: the saved file must have EXACTLY the merged manifest
            var actual = MapFile.ExtractManifest(WorkFile);
            if (actual.ComputeHash() != result.Merged!.ComputeHash())
            {
                var mismatches = ManifestDiff.Compute(result.Merged, actual);
                File.WriteAllBytes(WorkFile, oursBackup);
                return new MergeOutcome
                {
                    Success = false,
                    Message = "materialization verification failed — merge aborted, working map restored. " +
                              $"First mismatch: {Describe(mismatches.FirstOrDefault())}",
                    Conflicts = [],
                    AppliedChanges = [],
                };
            }

            var commit = CommitWorking(author, $"merge {branch}: {message}", theirs.Id);
            return new MergeOutcome
            {
                Success = true,
                Message = $"merged {branch} into {CurrentBranch} ({result.AppliedChanges.Count} change(s) applied)",
                Conflicts = [],
                AppliedChanges = result.AppliedChanges,
                Commit = commit,
            };
        }
        finally
        {
            TryDelete(oursBlobPath);
            TryDelete(theirsBlobPath);
        }
    }

    // ---------- message format ----------

    private static string FormatMessage(string manifestHash, string blobHash, string message) =>
        $"{MessageHeader}\nmanifest:{manifestHash}\nblob:{blobHash}\n\n{message}";

    private static MapCommit ParseCommit(string id, string message, IReadOnlyList<string> parents, string author, DateTimeOffset when)
    {
        var lines = message.Split('\n');
        string manifestHash = "";
        string blobHash = "";
        var userMessage = message;

        if (lines.Length >= 3 && lines[0].Trim() == MessageHeader)
        {
            manifestHash = lines[1].Trim()["manifest:".Length..];
            blobHash = lines[2].Trim()["blob:".Length..];
            userMessage = string.Join('\n', lines.Skip(3)).TrimStart('\n', '\r');
        }

        return new MapCommit
        {
            Id = id,
            Parents = parents,
            Author = author,
            Message = userMessage,
            Timestamp = when,
            ManifestHash = manifestHash,
            MapBlobHash = blobHash,
        };
    }

    private static string Describe(ManifestChange? change) =>
        change is null ? "n/a" : $"{change.Kind} {change.Section} {change.Key}";

    private static void TryDelete(string path)
    {
        try
        {
            File.Delete(path);
        }
        catch
        {
            // best effort
        }
    }

    // ---------- object stores ----------

    internal static class BlobStore
    {
        public static string Store(string objectsDir, byte[] raw)
        {
            var hash = Convert.ToHexString(SHA256.HashData(raw)).ToLowerInvariant();
            var path = Path.Combine(objectsDir, "maps", $"{hash}.gbx.brotli");
            if (!File.Exists(path))
            {
                Directory.CreateDirectory(Path.GetDirectoryName(path)!);
                using var output = File.Create(path);
                using (var brotli = new BrotliStream(output, CompressionLevel.Optimal, leaveOpen: true))
                {
                    brotli.Write(raw);
                }
            }

            return hash;
        }
    }

    internal static class ManifestStore
    {
        public static void Store(string objectsDir, MapManifest manifest)
        {
            var hash = manifest.ComputeHash();
            var path = Path.Combine(objectsDir, "manifests", $"{hash}.json");
            if (!File.Exists(path))
            {
                Directory.CreateDirectory(Path.GetDirectoryName(path)!);
                File.WriteAllBytes(path, manifest.SerializeToCanonicalJson());
            }
        }
    }
}
