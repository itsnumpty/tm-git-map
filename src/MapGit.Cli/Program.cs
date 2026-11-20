using System.Text.Json.Nodes;
using MapGit.Core.Diff;
using MapGit.Core.Manifest;
using MapGit.Git;
using MapGit.Maps;
using MapGit.Repo;

if (args.Length == 0 || args[0] is "--help" or "-h" or "help")
{
    Console.WriteLine("""
        mapgit � git-style version control for Trackmania maps (Phase 0 tooling)

        Usage:
          mapgit manifest <file.Map.Gbx> [--out <manifest.json>]
          mapgit diff <base.Map.Gbx> <other.Map.Gbx> [--fields]
          mapgit probe <file.Map.Gbx> [--out-dir <dir>]
          mapgit crosscheck <file.Map.Gbx> <spike-dump.csv>
          mapgit embedded <file.Map.Gbx> [--extract <dir>]
          mapgit git-spike <dir>

        Repository commands (--repo <dir>, default: current directory):
          mapgit init <file.Map.Gbx> [--repo <dir>] [--author <name>]
          mapgit status
          mapgit commit -m <message> [--author <name>]
          mapgit log [-n <count>]
          mapgit branch [<name>]
          mapgit checkout <branch>
          mapgit merge <branch> [-m <message>] [--author <name>]
        """);
    return 0;
}

try
{
        return args[0].ToLowerInvariant() switch
        {
            "manifest" => ManifestCmd(args),
            "diff" => DiffCmd(args),
            "probe" => ProbeCmd(args),
            "crosscheck" => CrosscheckCmd(args),
            "embedded" => EmbeddedCmd(args),
            "git-spike" => GitSpikeCmd(args),
            "init" => InitCmd(args),
            "status" => StatusCmd(args),
            "commit" => CommitCmd(args),
            "log" => LogCmd(args),
            "branch" => BranchCmd(args),
            "checkout" => CheckoutCmd(args),
            "merge" => MergeCmd(args),
            _ => Unknown(args[0]),
        };
}
catch (Exception ex)
{
    Console.Error.WriteLine($"error: {ex.GetType().Name}: {ex.Message}");
    return 1;
}

static int Unknown(string cmd)
{
    Console.Error.WriteLine($"Unknown command: {cmd}");
    return 1;
}

static string? OptionValue(string[] args, string name) =>
    Array.IndexOf(args, name) is var i && i >= 0 && i + 1 < args.Length ? args[i + 1] : null;

static string[] PositionalArgs(string[] args)
{
    string[] optionsWithValues = ["--repo", "--author", "--out", "--out-dir", "-m", "-n"];

    var result = new List<string>();
    for (var i = 1; i < args.Length; i++)
    {
        if (optionsWithValues.Contains(args[i]))
        {
            i++; // skip the option's value
        }
        else if (!args[i].StartsWith("--"))
        {
            result.Add(args[i]);
        }
    }

    return [.. result];
}

static int ManifestCmd(string[] args)
{
    var path = args[1];
    var gbx = MapFile.Parse(path);
    var manifest = MapFile.ExtractManifest(gbx.Node);

    Console.WriteLine($"Map          : {manifest.MapInfo.Name}");
    Console.WriteLine($"Uid          : {gbx.Node.MapUid ?? ""}  (game regenerates this on every save)");
    Console.WriteLine($"Author       : {manifest.MapInfo.AuthorLogin}");
    Console.WriteLine($"Collection   : {manifest.MapInfo.Collection} / {manifest.MapInfo.Decoration}");
    Console.WriteLine($"Manifest     : {manifest.ComputeHash()}");
    Console.WriteLine($"Blocks       : {manifest.Blocks.Count}" +
                      $" (free {manifest.Blocks.Count(b => b.IsFree)}, ghost {manifest.Blocks.Count(b => b.IsGhost)}," +
                      $" ground {manifest.Blocks.Count(b => b.IsGround)}, skinned {manifest.Blocks.Count(b => b.HasSkin)})");
    Console.WriteLine($"Items        : {manifest.Items.Count} (skinned {manifest.Items.Count(i => i.HasSkin)})");
    Console.WriteLine($"Embedded     : {manifest.Embedded.EntryCount} entries" +
                      (manifest.Embedded.Entries.Count > 0
                          ? $", first {manifest.Embedded.Entries[0].Name} ({manifest.Embedded.Entries[0].Fingerprint[..Math.Min(12, manifest.Embedded.Entries[0].Fingerprint.Length)]}...)"
                          : ""));
    Console.WriteLine($"Times (ms)   : author {manifest.MapInfo.AuthorTimeMs} / gold {manifest.MapInfo.GoldTimeMs}" +
                      $" / silver {manifest.MapInfo.SilverTimeMs} / bronze {manifest.MapInfo.BronzeTimeMs}");

    var outPath = OptionValue(args, "--out");
    if (outPath is not null)
    {
        File.WriteAllBytes(outPath, manifest.SerializeToCanonicalJson());
        Console.WriteLine($"Written      : {outPath}");
    }

    return 0;
}

static int DiffCmd(string[] args)
{
    var showFields = args.Contains("--fields");
    var paths = PositionalArgs(args);
    if (paths.Length < 2)
    {
        Console.Error.WriteLine("usage: mapgit diff <base.Map.Gbx> <other.Map.Gbx> [--fields]");
        return 1;
    }

    var baseManifest = MapFile.ExtractManifest(paths[0]);
    var otherManifest = MapFile.ExtractManifest(paths[1]);

    Console.WriteLine($"Base  : {baseManifest.MapInfo.Name} [{baseManifest.ComputeHash()[..16]}]");
    Console.WriteLine($"Other : {otherManifest.MapInfo.Name} [{otherManifest.ComputeHash()[..16]}]");
    Console.WriteLine();

    var changes = ManifestDiff.Compute(baseManifest, otherManifest);
    foreach (var change in changes)
    {
        var sign = change.Kind switch
        {
            ManifestChangeKind.Added => '+',
            ManifestChangeKind.Removed => '-',
            ManifestChangeKind.Modified => '~',
            _ => '?',
        };
        var summary = ChangeSummary(change.OtherValue) is { Length: > 0 } ours ? ours : ChangeSummary(change.BaseValue);
        Console.WriteLine($"{sign} {change.Section} {change.Key}  {summary}");

        if (showFields)
        {
            PrintFieldDiff(change.BaseValue, change.OtherValue);
        }
    }

    Console.WriteLine();
    Console.WriteLine($"{changes.Count} change(s).");
    return 0;
}

static void PrintFieldDiff(JsonNode? baseNode, JsonNode? otherNode)
{
    if (baseNode is not JsonObject b || otherNode is not JsonObject o)
    {
        return;
    }

    foreach (var prop in b.Select(p => p.Key).Concat(o.Select(p => p.Key)).Distinct())
    {
        var bv = b[prop];
        var ov = o[prop];

        if (JsonNode.DeepEquals(bv, ov))
        {
            continue;
        }

        if (bv is JsonArray bArr && ov is JsonArray oArr && AllNamedObjects(bArr) && AllNamedObjects(oArr))
        {
            PrintArrayDiffByName(prop, bArr, oArr);
        }
        else
        {
            Console.WriteLine($"      {prop}: {ShortValue(bv)} -> {ShortValue(ov)}");
        }
    }
}

static bool AllNamedObjects(JsonArray arr) => arr.All(n => n is JsonObject obj && obj["name"] is not null);

static void PrintArrayDiffByName(string prop, JsonArray baseArr, JsonArray otherArr)
{
    var others = otherArr.OfType<JsonObject>().ToList();
    foreach (var bObj in baseArr.OfType<JsonObject>())
    {
        var name = bObj["name"]!.ToString();
        var oObj = others.FirstOrDefault(x => x["name"]?.ToString() == name);
        if (oObj is null)
        {
            Console.WriteLine($"      {prop}[{name}]: removed");
            continue;
        }

        foreach (var field in bObj.Select(p => p.Key).Concat(oObj.Select(p => p.Key)).Distinct())
        {
            if (!JsonNode.DeepEquals(bObj[field], oObj[field]))
            {
                Console.WriteLine($"      {prop}[{name}].{field}: {ShortValue(bObj[field])} -> {ShortValue(oObj[field])}");
            }
        }
    }

    var baseNames = baseArr.OfType<JsonObject>().Select(x => x["name"]?.ToString()).ToHashSet();
    foreach (var oObj in otherArr.OfType<JsonObject>())
    {
        var name = oObj["name"]?.ToString();
        if (!baseNames.Contains(name))
        {
            Console.WriteLine($"      {prop}[{name}]: added");
        }
    }
}

static string ShortValue(JsonNode? node)
{
    var s = node?.ToJsonString(CanonicalJson.Options) ?? "null";
    return s.Length > 40 ? s[..37] + "..." : s;
}

static int ProbeCmd(string[] args)
{
    var path = args[1];
    var outDir = OptionValue(args, "--out-dir") ?? Path.Combine(Path.GetTempPath(), "mapgit-probe");
    Directory.CreateDirectory(outDir);

    var resavePath = Path.Combine(outDir, Path.GetFileNameWithoutExtension(Path.GetFileNameWithoutExtension(path)) + ".resaved.Map.Gbx");
    var report = MapFidelityProbe.Probe(path, resavePath);

    Console.WriteLine($"Source       : {report.SourcePath} ({report.SourceLength / 1024.0:F1} KB)");
    Console.WriteLine($"Header       : {report.HeaderInfo}");
    Console.WriteLine($"Parse time   : {report.ParseMs:F1} ms");
    Console.WriteLine($"Save time    : {report.SaveMs:F1} ms");
    Console.WriteLine($"Blob sha     : {report.SourceBlobSha256[..16]}... -> {report.ResavedBlobSha256[..16]}... (byte-identical: {report.ByteIdentical})");
    Console.WriteLine($"Manifest     : {report.SourceManifestHash[..16]}... -> {report.ResavedManifestHash[..16]}...");
    Console.WriteLine($"Result       : {(report.ManifestStable ? "MANIFEST STABLE � GBX.NET round trip preserves canonical content" : "MANIFEST DRIFT � content changed across round trip, investigate!")}");
    Console.WriteLine($"Resaved file : {resavePath}");
    return report.ManifestStable ? 0 : 2;
}

static int CrosscheckCmd(string[] args)
{
    var mapPath = args[1];
    var dumpPath = args[2];

    var gbx = MapFile.Parse(mapPath);
    var manifest = MapFile.ExtractManifest(gbx.Node);
    var engineUid = gbx.Node.MapUid ?? "";

    // Engine side: grid blocks keyed by (name, x, y, z, ghost). Free blocks can carry
    // -1 grid coords in the file (their real identity is the free-position key), so we
    // skip those on both sides and count them separately.
    var engineBlocks = new Dictionary<(string Name, long X, long Y, long Z, bool Ghost), int>();
    var skippedEngineBlocks = 0;
    foreach (var b in manifest.Blocks)
    {
        if (b.Coord.X == -1 && b.Coord.Z == -1)
        {
            skippedEngineBlocks++;
            continue;
        }

        var key = (b.Name, X: (long)b.Coord.X, Y: (long)b.Coord.Y, Z: (long)b.Coord.Z, b.IsGhost);
        engineBlocks[key] = engineBlocks.GetValueOrDefault(key) + 1;
    }

    var engineItems = manifest.Items
        .GroupBy(i => (i.ItemModel, Mm(i.Position.X), Mm(i.Position.Y), Mm(i.Position.Z)))
        .ToDictionary(g => g.Key, g => g.Count());

    string? dumpUid = null;
    long dumpBlockCount = 0;
    long dumpItemCount = 0;
    long dumpBakedCount = 0;
    var skippedDumpBlocks = 0;
    var dumpBlocks = new List<(string Name, long X, long Y, long Z, bool Ghost)>();
    var dumpItems = new List<(string Model, int X, int Y, int Z)>();

    foreach (var line in File.ReadLines(dumpPath))
    {
        if (string.IsNullOrWhiteSpace(line))
        {
            continue;
        }

        var p = line.Split(',');
        switch (p[0])
        {
            case "M":
                dumpUid = p.Length > 1 ? p[1] : null;
                dumpBlockCount = p.Length > 2 && long.TryParse(p[2], out var bc) ? bc : 0;
                dumpItemCount = p.Length > 3 && long.TryParse(p[3], out var ic) ? ic : 0;
                dumpBakedCount = p.Length > 4 && long.TryParse(p[4], out var bk) ? bk : 0;
                break;
            case "B":
            case "B2":
                if (p.Length >= 8)
                {
                    var x = long.Parse(p[2]);
                    var y = long.Parse(p[3]);
                    var z = long.Parse(p[4]);
                    if (x is 4_294_967_295 or -1 || z is 4_294_967_295 or -1)
                    {
                        skippedDumpBlocks++;
                    }
                    else
                    {
                        dumpBlocks.Add((p[1], x, y, z, p[7] == "1"));
                    }
                }
                break;
            case "I":
                if (p.Length >= 5)
                {
                    dumpItems.Add((p[1], int.Parse(p[2]), int.Parse(p[3]), int.Parse(p[4])));
                }
                break;
        }
    }

    Console.WriteLine($"Map              : {manifest.MapInfo.Name}");
    Console.WriteLine($"Uid engine/dump  : {engineUid} / {dumpUid}" +
                      (engineUid == dumpUid
                          ? "  (match)"
                          : "  (differs � the game regenerates the uid on every save; never rely on it)"));
    Console.WriteLine($"Counts engine    : {manifest.Blocks.Count} blocks, {manifest.Items.Count} items");
    Console.WriteLine($"Counts dump      : {dumpBlockCount} blocks ({dumpBakedCount} baked), {dumpItemCount} items");
    Console.WriteLine($"Free(-1) skipped : engine {skippedEngineBlocks}, dump {skippedDumpBlocks}");

    // GBX.NET normalizes block coords by -(1,0,1) relative to raw in-game values on chunk v>=6,
    // so try both alignments and report which one matches.
    foreach (var (dx, dz) in new[] { (0, 0), (1, 1) })
    {
        var normalized = dumpBlocks
            .GroupBy(b => (b.Name, X: b.X - dx, b.Y, Z: b.Z - dz, b.Ghost))
            .ToDictionary(g => g.Key, g => g.Count());
        var engineOnly = new List<string>();
        var dumpOnly = new List<string>();
        var matched = 0;

        foreach (var (key, count) in engineBlocks)
        {
            var dumpCount = normalized.GetValueOrDefault(key);
            matched += Math.Min(count, dumpCount);
            for (var i = dumpCount; i < count; i++)
            {
                engineOnly.Add($"{key.Name} @({key.X},{key.Y},{key.Z}){(key.Ghost ? " ghost" : "")}");
            }
        }
        foreach (var (key, count) in normalized)
        {
            var engineCount = engineBlocks.GetValueOrDefault(key);
            for (var i = engineCount; i < count; i++)
            {
                dumpOnly.Add($"{key.Name} @({key.X},{key.Y},{key.Z}){(key.Ghost ? " ghost" : "")}");
            }
        }

        Console.WriteLine($"Blocks off({dx},{dz})  : matched {matched}/{dumpBlocks.Count}" +
                          $", engine-only {engineOnly.Count}, dump-only {dumpOnly.Count}");
        if (engineOnly.Count > 0)
        {
            Console.WriteLine("  engine-only e.g.: " + string.Join("; ", engineOnly.Take(5)));
        }
        if (dumpOnly.Count > 0)
        {
            Console.WriteLine("  dump-only e.g.  : " + string.Join("; ", dumpOnly.Take(5)));
        }
    }

    var normalizedItems = dumpItems
        .GroupBy(i => (i.Model, i.X, i.Y, i.Z))
        .ToDictionary(g => g.Key, g => g.Count());
    var itemEngineOnly = new List<string>();
    var itemDumpOnly = new List<string>();

    foreach (var (key, count) in engineItems)
    {
        var dumpCount = normalizedItems.GetValueOrDefault(key);
        for (var i = dumpCount; i < count; i++)
        {
            itemEngineOnly.Add($"{key.ItemModel} @mm({key.Item2},{key.Item3},{key.Item4})");
        }
    }
    foreach (var (key, count) in normalizedItems)
    {
        var engineCount = engineItems.GetValueOrDefault(key);
        for (var i = engineCount; i < count; i++)
        {
            itemDumpOnly.Add($"{key.Model} @mm({key.X},{key.Y},{key.Z})");
        }
    }

    Console.WriteLine($"Items            : engine-only {itemEngineOnly.Count}, dump-only {itemDumpOnly.Count}");
    if (itemEngineOnly.Count > 0)
    {
        Console.WriteLine("  engine-only e.g.: " + string.Join("; ", itemEngineOnly.Take(5)));
    }
    if (itemDumpOnly.Count > 0)
    {
        Console.WriteLine("  dump-only e.g.  : " + string.Join("; ", itemDumpOnly.Take(5)));
    }

    return 0;
}

static int EmbeddedCmd(string[] args)
{
    var path = args[1];
    var extractDir = OptionValue(args, "--extract");

    var gbx = MapFile.Parse(path);
    var map = gbx.Node;

    if (map.EmbeddedZipData is null || map.EmbeddedZipData.Length == 0)
    {
        Console.WriteLine("No embedded data.");
        return 0;
    }

    using var archive = map.OpenReadEmbeddedZipData();
    foreach (var entry in archive.Entries)
    {
        if (string.IsNullOrEmpty(entry.Name))
        {
            continue;
        }

        using var s = entry.Open();
        using var ms = new MemoryStream();
        s.CopyTo(ms);
        var bytes = ms.ToArray();
        var sha = CanonicalJson.HexLower(System.Security.Cryptography.SHA256.HashData(bytes));
        var magic = bytes.Length >= 3 ? System.Text.Encoding.ASCII.GetString(bytes, 0, 3) : "?";

        Console.WriteLine($"{entry.FullName}  {entry.Length} B  sha256 {sha[..Math.Min(16, sha.Length)]}...  magic {magic}");

        if (extractDir is not null)
        {
            var target = Path.Combine(extractDir, entry.FullName.Replace('/', '\\'));
            Directory.CreateDirectory(Path.GetDirectoryName(target)!);
            File.WriteAllBytes(target, bytes);
            Console.WriteLine($"  extracted -> {target}");
        }
    }

    return 0;
}

static int GitSpikeCmd(string[] args)
{
    var dir = args[1];
    if (File.Exists(Path.Combine(dir, ".git")))
    {
        Console.Error.WriteLine($"{dir} already contains a git repository.");
        return 1;
    }

    Directory.CreateDirectory(dir);
    var result = GitSpike.Run(dir);

    Console.WriteLine($"Commits      : {result.Commits}");
    Console.WriteLine($"Branches     : {result.Branches} (head: {result.HeadBranch})");
    Console.WriteLine($"Merge        : {result.MergeStatus}, head has {result.HeadParentCount} parent(s)");
    return 0;
}

static string ChangeSummary(JsonNode? node)
{
    string? s = null;
    if (node is JsonObject obj)
    {
        s = (obj["name"] ?? obj["itemModel"] ?? obj["uid"])?.ToString();
    }

    s ??= node?.ToJsonString(CanonicalJson.Options);
    if (s is not null && s.Length > 48)
    {
        s = s[..45] + "...";
    }

    return s ?? "";
}

static int Mm(float v) => (int)MathF.Floor(v * 1000f + (v >= 0 ? 0.5f : -0.5f));

// ---------- repository commands ----------

static MapRepository OpenRepo(string[] args)
{
    var dir = OptionValue(args, "--repo") ?? Directory.GetCurrentDirectory();
    return MapRepository.Open(dir);
}

static string AuthorArg(string[] args, MapRepository repo) =>
    OptionValue(args, "--author") ?? repo.Meta.DefaultAuthor;

static int InitCmd(string[] args)
{
    var mapFile = args[1];
    var repoDir = OptionValue(args, "--repo")
        ?? Path.Combine(
            Path.GetDirectoryName(Path.GetFullPath(mapFile)) ?? ".",
            Path.GetFileNameWithoutExtension(Path.GetFileNameWithoutExtension(mapFile)) + ".mapgit");
    var author = OptionValue(args, "--author") ?? Environment.UserName;

    var repo = MapRepository.Init(mapFile, repoDir, author);
    var head = repo.Head!;
    Console.WriteLine($"Initialized   : {repoDir}");
    Console.WriteLine($"Repo id       : {repo.Meta.RepoId}");
    Console.WriteLine($"Initial commit: {head.Id[..12]} ({head.ManifestHash[..12]}) on {MapRepository.MainBranch}");
    return 0;
}

static int StatusCmd(string[] args)
{
    var repo = OpenRepo(args);
    var status = repo.Status();

    Console.WriteLine($"Repo    : {repo.RepoDir} ({repo.Meta.RepoId})");
    Console.WriteLine($"Branch  : {status.Branch}   (branches: {string.Join(", ", repo.Branches)})");
    if (status.Head is null)
    {
        Console.WriteLine("Head    : (no commits)");
        return 0;
    }

    Console.WriteLine($"Head    : {status.Head.Id[..12]} {status.Head.Message}  [{status.Head.ManifestHash[..12]}]");
    Console.WriteLine(status.Clean
        ? "Working : clean"
        : $"Working : DIRTY  (+{status.Added} / -{status.Removed} / ~{status.Modified} vs head)");
    return 0;
}

static int CommitCmd(string[] args)
{
    var repo = OpenRepo(args);
    var message = OptionValue(args, "-m") ?? throw new ArgumentException("commit requires -m <message>");

    var commit = repo.CommitWorking(AuthorArg(args, repo), message);
    if (commit is null)
    {
        Console.WriteLine("Nothing to commit � canonical manifest unchanged (volatile-only save skipped).");
        return 0;
    }

    Console.WriteLine($"Committed: {commit.Id[..12]} {commit.Message}  [{commit.ManifestHash[..12]}] by {commit.Author}");
    return 0;
}

static int LogCmd(string[] args)
{
    var repo = OpenRepo(args);
    var n = int.TryParse(OptionValue(args, "-n"), out var count) ? count : 20;

    foreach (var commit in repo.Log(n))
    {
        var parents = commit.Parents.Count > 1 ? $" (merge, {commit.Parents.Count} parents)" : "";
        Console.WriteLine($"{commit.Id[..12]} {commit.Timestamp.LocalDateTime:yyyy-MM-dd HH:mm} {commit.Author,-12} [{commit.ManifestHash[..12]}]{parents}");
        Console.WriteLine($"    {commit.Message.ReplaceLineEndings(" | ")}");
    }

    return 0;
}

static int BranchCmd(string[] args)
{
    var repo = OpenRepo(args);
    var positional = PositionalArgs(args);

    if (positional.Length == 0)
    {
        foreach (var branch in repo.Branches.OrderBy(b => b))
        {
            Console.WriteLine($"{(branch == repo.CurrentBranch ? "* " : "  ")}{branch}");
        }

        return 0;
    }

    repo.CreateBranch(positional[0]);
    Console.WriteLine($"Created branch: {positional[0]}");
    return 0;
}

static int CheckoutCmd(string[] args)
{
    var repo = OpenRepo(args);
    var branch = PositionalArgs(args)[0];

    repo.Checkout(branch);
    var status = repo.Status();
    Console.WriteLine($"On branch {branch} (head {status.Head?.Id[..12]}, working map: {(status.Clean ? "clean" : "dirty")})");
    return 0;
}

static int MergeCmd(string[] args)
{
    var repo = OpenRepo(args);
    var branch = PositionalArgs(args)[0];
    var message = OptionValue(args, "-m") ?? $"merge {branch}";

    var outcome = repo.Merge(branch, AuthorArg(args, repo), message);

    if (outcome.Success)
    {
        Console.WriteLine(outcome.Message);
        foreach (var applied in outcome.AppliedChanges.Take(20))
        {
            Console.WriteLine($"  {applied}");
        }

        if (outcome.AppliedChanges.Count > 20)
        {
            Console.WriteLine($"  ... and {outcome.AppliedChanges.Count - 20} more");
        }

        return 0;
    }

    Console.Error.WriteLine(outcome.Message);
    foreach (var conflict in outcome.Conflicts)
    {
        Console.Error.WriteLine($"  {conflict.Kind} {conflict.Section} {conflict.Key}: ours='{conflict.OursSummary}' theirs='{conflict.TheirsSummary}'");
    }

    return 2;
}
