using MapGit.Git;
using Xunit;

namespace MapGit.Core.Tests;

public class GitSpikeTests
{
    [Fact]
    public void libgit2sharp_supports_branch_and_merge_commits()
    {
        var dir = Path.Combine(Path.GetTempPath(), "mapgit-gitspike-" + Guid.NewGuid().ToString("N"));
        try
        {
            var result = GitSpike.Run(dir);

            Assert.Equal(4, result.Commits);          // c1, route, scenery, merge
            Assert.Equal(2, result.Branches);         // master + bob/scenery
            Assert.Equal("master", result.HeadBranch);
            Assert.Equal(2, result.HeadParentCount);  // real merge commit with two parents
            Assert.Equal("NonFastForward", result.MergeStatus);
        }
        finally
        {
            try
            {
                Directory.Delete(dir, recursive: true);
            }
            catch
            {
                // temp dir cleanup is best-effort
            }
        }
    }
}
