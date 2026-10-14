using FluentAssertions;
using Microsoft.Extensions.Configuration;
using TableStorageCleanup.Services;
using Xunit;

namespace TableStorageCleanup.Tests;

public class StorageAccountRegistryTests
{
    [Fact]
    public void GetAll_ShouldExtractAccountName_FromConnectionString()
    {
        var settings = new Dictionary<string, string?>
        {
            ["STORAGE_ACCOUNT_1"] = "DefaultEndpointsProtocol=https;AccountName=myprodstorage;AccountKey=dGVzdGtleQ==;EndpointSuffix=core.windows.net",
            ["STORAGE_ACCOUNT_2"] = "DefaultEndpointsProtocol=https;AccountName=mystagingstorage;AccountKey=dGVzdGtleTI=;EndpointSuffix=core.windows.net",
            ["STORAGE_ACCOUNT_EMPTY"] = "",
            ["UNRELATED_SETTING"] = "somevalue"
        };
        var config = new ConfigurationBuilder().AddInMemoryCollection(settings).Build();
        var registry = new StorageAccountRegistry(config);

        var targets = registry.GetAll();

        targets.Should().HaveCount(2);
        targets[0].Key.Should().Be("STORAGE_ACCOUNT_1");
        targets[0].AccountName.Should().Be("myprodstorage");
        targets[0].AuthMode.Should().Be("ConnectionString");

        targets[1].Key.Should().Be("STORAGE_ACCOUNT_2");
        targets[1].AccountName.Should().Be("mystagingstorage");
        targets[1].AuthMode.Should().Be("ConnectionString");
    }

    [Fact]
    public void GetAll_ShouldSupportManagedIdentityUrls()
    {
        var settings = new Dictionary<string, string?>
        {
            ["STORAGE_ACCOUNT_MI"] = "https://managedidstorage.table.core.windows.net"
        };
        var config = new ConfigurationBuilder().AddInMemoryCollection(settings).Build();
        var registry = new StorageAccountRegistry(config);

        var targets = registry.GetAll();

        targets.Should().HaveCount(1);
        targets[0].AccountName.Should().Be("managedidstorage");
        targets[0].AuthMode.Should().Be("ManagedIdentity");
    }

    [Fact]
    public void Find_ShouldReturnTarget_CaseInsensitively()
    {
        var settings = new Dictionary<string, string?>
        {
            ["STORAGE_ACCOUNT_A"] = "UseDevelopmentStorage=true"
        };
        var config = new ConfigurationBuilder().AddInMemoryCollection(settings).Build();
        var registry = new StorageAccountRegistry(config);

        var found = registry.Find("storage_account_a");
        found.Should().NotBeNull();
        found!.AccountName.Should().Be("devstoreaccount1");
    }
}
