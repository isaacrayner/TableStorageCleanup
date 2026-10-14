using FluentAssertions;
using TableStorageCleanup.Services;
using Xunit;

namespace TableStorageCleanup.Tests;

public class RunStoreTests
{
    [Fact]
    public void NewRunId_ShouldBeChronologicallyInvertedAndUnique()
    {
        var id1 = RunStore.NewRunId();
        Thread.Sleep(5);
        var id2 = RunStore.NewRunId();

        id1.Should().NotBe(id2);
        // Newer timestamp produces a smaller inverted tick value, meaning id2 comes before id1 in lexicographical sort
        string.CompareOrdinal(id2, id1).Should().BeLessThan(0);
    }
}
