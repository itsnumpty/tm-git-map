using LibGit2Sharp;

namespace MapGit.Git;

public sealed record GitSpikeResult(
    int Commits,
    int Branches,
    string HeadBranch,
    int HeadParentCount,
    string MergeStatus);

/// <summary>
/// Phase 0 spike: prove the LibGit2Sharp operations we need for the engine
/// (init, commit, branch, checkout, merge commit with two parents) work locally.
/// </summary>
public static class GitSpike
{
    public static GitSpikeResult Run(string workDir)
    {
        Repository.Init(workDir);
        using var repo = new Repository(workDir);

        var alice = new Signature("Alice", "alice@mapgit.dev", DateTimeOffset.Now);
        var bob = new Signature("Bob", "bob@mapgit.dev", DateTimeOffset.Now);

        WriteAndCommit(repo, workDir, "readme.txt", "v1", "initial commit", alice);

        repo.CreateBranch("bob/scenery");
        Commands.Checkout(repo, "bob/scenery");
        WriteAndCommit(repo, workDir, "scenery.txt", "trees", "add scenery", bob);

        Commands.Checkout(repo, "master");
        WriteAndCommit(repo, workDir, "route.txt", "road", "add route", alice);

        var merge = repo.Merge("bob/scenery", alice);

        var head = repo.Commits.First();
        return new GitSpikeResult(
            Commits: repo.Commits.Count(),
            Branches: repo.Branches.Count(),
            HeadBranch: repo.Head.FriendlyName,
            HeadParentCount: head.Parents.Count(),
            MergeStatus: merge.Status.ToString());
    }

    private static void WriteAndCommit(Repository repo, string workDir, string file, string content, string message, Signature author)
    {
        File.WriteAllText(Path.Combine(workDir, file), content);
        Commands.Stage(repo, "*");
        repo.Commit(message, author, author);
    }
}
