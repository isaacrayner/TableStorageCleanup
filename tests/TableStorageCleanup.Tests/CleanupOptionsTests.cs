using FluentAssertions;
using Microsoft.Extensions.Configuration;
using TableStorageCleanup.Services;
using Xunit;

namespace TableStorageCleanup.Tests;

public class CleanupOptionsTests
{
    [Fact]
    public void From_ShouldUseDefaults_WhenConfigurationIsEmpty()
    {
        var config = new ConfigurationBuilder().AddInMemoryCollection().Build();

        var options = CleanupOptions.From(config);

        options.RetentionDays.Should().Be(30);
        options.MinRetentionDays.Should().Be(7);
        options.TablePrefix.Should().Be("WAD");
        options.TimerSchedule.Should().BeEmpty();
        options.TimerDryRun.Should().BeFalse();
    }

    [Fact]
    public void From_ShouldRespectConfiguredValues()
    {
        var settings = new Dictionary<string, string?>
        {
            ["RETENTION_DAYS"] = "60",
            ["MIN_RETENTION_DAYS"] = "14",
            ["TABLE_PREFIX"] = "CUSTOM",
            ["TIMER_SCHEDULE"] = "0 0 * * *",
            ["TIMER_DRY_RUN"] = "true"
        };
        var config = new ConfigurationBuilder().AddInMemoryCollection(settings).Build();

        var options = CleanupOptions.From(config);

        options.RetentionDays.Should().Be(60);
        options.MinRetentionDays.Should().Be(14);
        options.TablePrefix.Should().Be("CUSTOM");
        options.TimerSchedule.Should().Be("0 0 * * *");
        options.TimerDryRun.Should().BeTrue();
    }

    [Fact]
    public void From_ShouldClampRetentionDaysToMinRetentionDays_WhenConfiguredLower()
    {
        var settings = new Dictionary<string, string?>
        {
            ["RETENTION_DAYS"] = "3",
            ["MIN_RETENTION_DAYS"] = "10"
        };
        var config = new ConfigurationBuilder().AddInMemoryCollection(settings).Build();

        var options = CleanupOptions.From(config);

        options.RetentionDays.Should().Be(10);
        options.MinRetentionDays.Should().Be(10);
    }
}
