using FluentAssertions;
using TableStorageCleanup.Services;
using Xunit;

namespace TableStorageCleanup.Tests;

public class TableCleanerTests
{
    [Theory]
    [InlineData("WAD", "TableName ge 'WAD' and TableName lt 'WAE'")]
    [InlineData("LOG", "TableName ge 'LOG' and TableName lt 'LOH'")]
    [InlineData("A", "TableName ge 'A' and TableName lt 'B'")]
    public void BuildPrefixFilter_ShouldConstructValidRangeODataFilter(string prefix, string expectedFilter)
    {
        var filter = TableCleaner.BuildPrefixFilter(prefix);
        filter.Should().Be(expectedFilter);
    }

    [Fact]
    public void BuildPrefixFilter_ShouldReturnEmpty_WhenPrefixIsNullOrEmpty()
    {
        TableCleaner.BuildPrefixFilter("").Should().BeEmpty();
    }

    [Fact]
    public void BuildPrefixFilter_ShouldEscapeSingleQuotes()
    {
        var filter = TableCleaner.BuildPrefixFilter("TEST'X");
        filter.Should().Contain("TEST''X");
    }
}
