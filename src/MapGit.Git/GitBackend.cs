using LibGit2Sharp;

namespace MapGit.Git;

/// <summary>
/// Thin LibGit2Sharp backend. The MapGit repo directory IS a real git repository:
/// MapGit branches are git branches (single ref store), and commit metadata
/// (manifest/blob hashes) travels inside the commit message header, so later
/// push/pull over a git host is native.
/// </summary>
public static class GitBackend
{
    public static void Init(string repoDir) => Repository.Init(repoDir);

    /// <summary>Stages everything and creates a commit with explicit parents on the given branch. Returns the sha.</summary>
    public static string CommitAll(string repoDir, string branch, string author, string message, params string[] parentIds)
    {
        using var repo = new Repository(repoDir);
        Commands.Stage(repo, "*");

        var signature = new Signature(author, "mapgit@localhost", DateTimeOffset.Now);
        var tree = repo.ObjectDatabase.CreateTree(repo.Index);
        var parents = parentIds.Select(id => repo.Lookup<Commit>(id) ?? throw new InvalidOperationException($"parent commit {id} not found")).ToArray();

        var commit = repo.ObjectDatabase.CreateCommit(signature, signature, message, tree, parents, false);

        var branchRef = $"refs/heads/{branch}";
        if (repo.Branches[branch] is null)
        {
            repo.Refs.Add(branchRef, commit.Id);

            // fresh repository (unborn HEAD): move HEAD onto the created branch and drop
            // the default-named branch if the commit accidentally materialized on it
            if (repo.Refs.Head.TargetIdentifier != branchRef)
            {
                var previousHeadTarget = repo.Refs.Head.TargetIdentifier;
                // force is safe: the branch tip is the commit we just created from this very index
                Commands.Checkout(repo, branch, new CheckoutOptions { CheckoutModifiers = CheckoutModifiers.Force });

                if (previousHeadTarget != branchRef
                    && repo.Refs[previousHeadTarget]?.TargetIdentifier == commit.Sha)
                {
                    repo.Refs.Remove(previousHeadTarget);
                }
            }
        }
        else
        {
            repo.Refs.UpdateTarget(repo.Branches[branch].Reference, commit.Id);
        }

        return commit.Sha;
    }

    public static IReadOnlyList<string> Branches(string repoDir)
    {
        using var repo = new Repository(repoDir);
        return repo.Branches.Where(b => !b.IsRemote).Select(b => b.FriendlyName).ToList();
    }

    public static string HeadBranch(string repoDir)
    {
        using var repo = new Repository(repoDir);
        return repo.Head.FriendlyName;
    }

    public static string? HeadCommit(string repoDir)
    {
        using var repo = new Repository(repoDir);
        return repo.Head.Tip?.Sha;
    }

    public static void CreateBranch(string repoDir, string name)
    {
        using var repo = new Repository(repoDir);
        if (repo.Branches[name] is not null)
        {
            throw new InvalidOperationException($"branch '{name}' already exists");
        }

        repo.CreateBranch(name);
    }

    public static void Checkout(string repoDir, string name)
    {
        using var repo = new Repository(repoDir);
        if (repo.Branches[name] is null)
        {
            throw new InvalidOperationException($"branch '{name}' not found");
        }

        Commands.Checkout(repo, name);
    }

    /// <summary>Throws if the working tree has unstaged changes (like git checkout would).</summary>
    public static bool IsClean(string repoDir)
    {
        using var repo = new Repository(repoDir);
        Commands.Stage(repo, "*"); // stage first so status reflects content, not index state
        return !repo.RetrieveStatus().IsDirty;
    }

    public static string? BranchHead(string repoDir, string branch)
    {
        using var repo = new Repository(repoDir);
        return repo.Branches[branch]?.Tip.Sha;
    }

    public static string? FindMergeBase(string repoDir, string a, string b)
    {
        using var repo = new Repository(repoDir);
        var commitA = repo.Lookup<Commit>(a) ?? throw new InvalidOperationException($"commit {a} not found");
        var commitB = repo.Lookup<Commit>(b) ?? throw new InvalidOperationException($"commit {b} not found");
        return repo.ObjectDatabase.FindMergeBase(commitA, commitB)?.Sha;
    }

    public static (string Sha, string Message, IReadOnlyList<string> Parents, string Author, DateTimeOffset When) ReadCommit(string repoDir, string sha)
    {
        using var repo = new Repository(repoDir);
        var c = repo.Lookup<Commit>(sha) ?? throw new InvalidOperationException($"commit {sha} not found");
        return (c.Sha, c.Message, c.Parents.Select(p => p.Sha).ToList(), c.Author.Name, c.Author.When);
    }

    /// <summary>
    /// Reads a file's bytes from a commit's tree. Git is the durable object store:
    /// working-tree object files come and go with branch checkouts, but every committed
    /// object is always reachable through the commit that references it.
    /// </summary>
    public static byte[] ReadFileFromCommit(string repoDir, string commitSha, string relativePath)
    {
        using var repo = new Repository(repoDir);
        var commit = repo.Lookup<Commit>(commitSha) ?? throw new InvalidOperationException($"commit {commitSha} not found");
        var entry = commit[relativePath] ?? throw new InvalidOperationException($"'{relativePath}' is not in commit {commitSha[..12]}");
        var blob = repo.Lookup<Blob>(entry.Target.Id)
            ?? throw new InvalidOperationException($"'{relativePath}' in commit {commitSha[..12]} is not a blob");
        using var content = blob.GetContentStream();
        using var ms = new MemoryStream();
        content.CopyTo(ms);
        return ms.ToArray();
    }
}
