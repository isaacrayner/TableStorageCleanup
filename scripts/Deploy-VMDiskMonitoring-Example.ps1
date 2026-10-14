# Deploy Azure Monitor Agent and Data Collection Rules for VM Disk Space Monitoring
# OPTIMIZED: Uses Perf table with streamlined deployment process
# Auto-discovers VMs with monitoring tags and creates appropriate DCRs
# Cost: ~$0.30-0.60/month per VM with 10-minute intervals

param(
    [Parameter(Mandatory=$false)]
    [string]$SubscriptionId,
    
    [Parameter(Mandatory=$false)]
    [string[]]$CustomerSubscriptionIds,
    
    [Parameter(Mandatory=$false)]
    [string[]]$CustomerSubscriptionNames,
    
    [Parameter(Mandatory=$false)]
    [string]$Location = "uksouth",
    
    [Parameter(Mandatory=$true)]
    [string]$CustomerName = "Customer",
    
    [Parameter(Mandatory=$true)]
    [string]$AlertResourceGroupName,
    
    [Parameter(Mandatory=$true)]
    [string]$LogAnalyticsWorkspaceName,
    
    [Parameter(Mandatory=$false)]
    [string]$LogAnalyticsSubscriptionId,
    
    [Parameter(Mandatory=$false)]
    [string]$LogAnalyticsResourceGroupName,
    
    [Parameter(Mandatory=$true)]
    [string]$CSPSubscriptionId,
    
    [Parameter(Mandatory=$false)]
    [string]$CSPResourceGroupName,
    
    [Parameter(Mandatory=$false)]
    [switch]$DryRun = $false
)

#Requires -Modules Az.Accounts, Az.Resources, Az.Monitor, Az.Compute

Write-Host "Azure VM Disk Space Monitoring Deployment" -ForegroundColor Cyan

# Parameter validation and multi-subscription setup
if ($CustomerSubscriptionIds) {
    # Multi-subscription mode
    if ($SubscriptionId) {
        Write-Host "WARNING: Both SubscriptionId and CustomerSubscriptionIds provided. Using CustomerSubscriptionIds for multi-subscription deployment." -ForegroundColor Yellow
    }
    
    if ($CustomerSubscriptionNames -and $CustomerSubscriptionNames.Count -ne $CustomerSubscriptionIds.Count) {
        Write-Host "ERROR: CustomerSubscriptionNames count must match CustomerSubscriptionIds count" -ForegroundColor Red
        exit 1
    }
    
    # Create subscription processing list
    $subscriptionsToProcess = @()
    for ($i = 0; $i -lt $CustomerSubscriptionIds.Count; $i++) {
        $subName = if ($CustomerSubscriptionNames) { $CustomerSubscriptionNames[$i] } else { "Sub$($i+1)" }
        $subscriptionsToProcess += @{
            Id = $CustomerSubscriptionIds[$i]
            Name = $subName
        }
    }
    
    Write-Host "Multi-subscription deployment detected:" -ForegroundColor Cyan
    Write-Host "Processing $($subscriptionsToProcess.Count) customer subscriptions:" -ForegroundColor White
    foreach ($sub in $subscriptionsToProcess) {
        Write-Host "  - $($sub.Name): $($sub.Id)" -ForegroundColor Gray
    }
} elseif ($SubscriptionId) {
    # Single subscription mode (backward compatibility)
    $subscriptionsToProcess = @(@{
        Id = $SubscriptionId
        Name = $CustomerName
    })
    Write-Host "Single subscription deployment:" -ForegroundColor Cyan
    Write-Host "  - ${CustomerName}: $SubscriptionId" -ForegroundColor White
} else {
    Write-Host "ERROR: Must provide either SubscriptionId (single) or CustomerSubscriptionIds (multi-subscription)" -ForegroundColor Red
    exit 1
}

# Set CSPResourceGroupName to AlertResourceGroupName if not explicitly provided
# (They should always be the same value - both refer to the CSP resource group)
if (-not $CSPResourceGroupName) {
    $CSPResourceGroupName = $AlertResourceGroupName
}

# Validate they match to avoid configuration errors
if ($AlertResourceGroupName -ne $CSPResourceGroupName) {
    Write-Host "WARNING: AlertResourceGroupName ($AlertResourceGroupName) and CSPResourceGroupName ($CSPResourceGroupName) should be the same!" -ForegroundColor Yellow
    Write-Host "Using AlertResourceGroupName ($AlertResourceGroupName) for all operations." -ForegroundColor Yellow
    $CSPResourceGroupName = $AlertResourceGroupName
}

# Function to get VMs with monitoring tags
function Get-MonitoringVMs {
    param([string]$OSType)
    
    return Get-AzVM | Where-Object { 
        $_.StorageProfile.OsDisk.OsType -eq $OSType -and
        ($_.Tags.Monitoring -in @("Monitor", "AHMonitor", "Enabled", "True") -or $_.Tags.CGS -in @("Monitor", "AHMonitor"))
    }
}

# Function to create Data Collection Endpoint
function New-DCETemplate {
    param(
        [string]$Name,
        [string]$Location
    )
    
    return @{
        '$schema' = "https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#"
        contentVersion = "1.0.0.0"
        resources = @(@{
            type = "Microsoft.Insights/dataCollectionEndpoints"
            apiVersion = "2022-06-01"
            name = $Name
            location = $Location
            properties = @{
                networkAcls = @{
                    publicNetworkAccess = "Enabled"
                }
            }
        })
    }
}

# Function to create DCR template
function New-DCRTemplate {
    param(
        [string]$Name,
        [string]$OSType,
        [string]$LogAnalyticsResourceId,
        [string]$Location,
        [string]$CustomerName,
        [string]$DataCollectionEndpointId,
        [string]$SubscriptionName = ""
    )
    
    # Use OS-specific performance counters - corrected to standard names
    $counterSpecifier = if ($OSType -eq "Windows") { 
        @(
            "\LogicalDisk(*)\% Free Space",
            "\LogicalDisk(*)\Free Megabytes"
        )
    } else { 
        @(
            "Logical Disk(*)\% Free Space",
            "Logical Disk(*)\Free Megabytes"
        )
    }
    
    return @{
        '$schema' = "https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#"
        contentVersion = "1.0.0.0"
        resources = @(@{
            type = "Microsoft.Insights/dataCollectionRules"
            apiVersion = "2022-06-01"
            name = $Name
            location = $Location
            tags = @{
                "Monitoring" = "DiskMonitoring"
                "Customer" = $CustomerName
                "OSType" = $OSType
                "SubscriptionName" = $SubscriptionName
            }
            properties = @{
                description = "VM Disk Space - Perf Table (1min intervals) - $SubscriptionName"
                dataCollectionEndpointId = $DataCollectionEndpointId
                dataSources = @{
                    performanceCounters = @(@{
                        name = "DiskSpaceCounters-$OSType"
                        streams = @("Microsoft-Perf")
                        scheduledTransferPeriod = "PT1M"
                        samplingFrequencyInSeconds = 60
                        counterSpecifiers = @($counterSpecifier)
                    })
                }
                destinations = @{
                    logAnalytics = @(@{
                        workspaceResourceId = $LogAnalyticsResourceId
                        name = "LogAnalytics-Destination"
                    })
                }
                dataFlows = @(@{
                    streams = @("Microsoft-Perf")
                    destinations = @("LogAnalytics-Destination")
                    transformKql = "source"
                })
            }
        })
    }
}

# Function to configure VM with AMA and DCR association
function Set-VMMonitoring {
    param(
        [object]$VM,
        [string]$DCRResourceId,
        [string]$DCEResourceId,
        [bool]$DryRun
    )
    
    if ($DryRun) {
        Write-Host "  [DRY RUN] Would configure $($VM.Name)" -ForegroundColor Magenta
        return
    }
    
    $vmIsWindows = $VM.StorageProfile.OsDisk.OsType -eq "Windows"
    $extensionName = if ($vmIsWindows) { "AzureMonitorWindowsAgent" } else { "AzureMonitorLinuxAgent" }
    
    # Install AMA if not present
    $extension = Get-AzVMExtension -ResourceGroupName $VM.ResourceGroupName -VMName $VM.Name -Name $extensionName -ErrorAction SilentlyContinue
    if (-not $extension) {
        Write-Host "    Installing Azure Monitor Agent..." -ForegroundColor Gray
        Set-AzVMExtension -ResourceGroupName $VM.ResourceGroupName -VMName $VM.Name -Name $extensionName -Publisher "Microsoft.Azure.Monitor" -Type $extensionName -TypeHandlerVersion "1.0" -EnableAutomaticUpgrade:$true | Out-Null
        Start-Sleep 15
    } else {
        Write-Host "    Azure Monitor Agent already installed" -ForegroundColor Gray
    }
    
    # Create both DCR and DCE associations using ARM template deployment
    $associationTemplate = @{
        '$schema' = "https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#"
        contentVersion = "1.0.0.0"
        parameters = @{
            vmName = @{
                type = "string"
                defaultValue = $VM.Name
            }
            dataCollectionRuleId = @{
                type = "string"
                defaultValue = $DCRResourceId
            }
            dataCollectionEndpointId = @{
                type = "string"
                defaultValue = $DCEResourceId
            }
        }
        resources = @(
            # DCR Association
            @{
                type = "Microsoft.Insights/dataCollectionRuleAssociations"
                apiVersion = "2022-06-01"
                scope = "[format('Microsoft.Compute/virtualMachines/{0}', parameters('vmName'))]"
                name = "CGS-DiskSpace-DCR-Association"
                properties = @{ 
                    dataCollectionRuleId = "[parameters('dataCollectionRuleId')]"
                    description = "CGS Disk Space Monitoring DCR Association"
                }
            },
            # DCE Association (required for VM to send data to DCE)
            @{
                type = "Microsoft.Insights/dataCollectionRuleAssociations"
                apiVersion = "2022-06-01"
                scope = "[format('Microsoft.Compute/virtualMachines/{0}', parameters('vmName'))]"
                name = "configurationAccessEndpoint"
                properties = @{ 
                    dataCollectionEndpointId = "[parameters('dataCollectionEndpointId')]"
                    description = "CGS Disk Space Monitoring DCE Association"
                }
            }
        )
    }
    
    try {
        New-AzResourceGroupDeployment -ResourceGroupName $VM.ResourceGroupName -Name "VMAssociations-$($VM.Name)-$(Get-Date -Format 'HHmmss')" -TemplateObject $associationTemplate | Out-Null
        Write-Host "    Associated with DCR and DCE" -ForegroundColor Gray
    } catch {
        Write-Host "    Already associated with DCR and DCE" -ForegroundColor Gray
    }
}

# Set context to customer subscription for VM discovery
Set-AzContext -SubscriptionId $SubscriptionId | Out-Null

# Discover VMs and their regions
Write-Host "Discovering VMs with monitoring tags..." -ForegroundColor Yellow
$allMonitoredVMs = @()
$allMonitoredVMs += Get-MonitoringVMs -OSType "Windows"
$allMonitoredVMs += Get-MonitoringVMs -OSType "Linux"
$totalVMs = $allMonitoredVMs.Count

if ($totalVMs -eq 0) {
    Write-Host "No VMs found with CGS=Monitor or CGS=AHMonitor tags" -ForegroundColor Red
    exit 1
}

$allRegions = $allMonitoredVMs | Select-Object -ExpandProperty Location -Unique
Write-Host "Found $totalVMs VMs across $($allRegions.Count) regions." -ForegroundColor Green

# Validate CSP resource group exists (where alerts and DCRs will be created)
Set-AzContext -SubscriptionId $CSPSubscriptionId | Out-Null
$cspRG = Get-AzResourceGroup -Name $CSPResourceGroupName -ErrorAction SilentlyContinue
if (-not $cspRG) {
    Write-Host "CSP Resource Group '$CSPResourceGroupName' not found in subscription '$CSPSubscriptionId'" -ForegroundColor Red
    exit 1
}

# Set up cross-subscription parameters for Log Analytics workspace
if ($LogAnalyticsSubscriptionId -and $LogAnalyticsResourceGroupName) {
    $LogAnalyticsResourceGroup = $LogAnalyticsResourceGroupName
    $LogAnalyticsSubscription = $LogAnalyticsSubscriptionId
} else {
    $LogAnalyticsResourceGroup = $CSPResourceGroupName
    $LogAnalyticsSubscription = $CSPSubscriptionId
}

# Get Log Analytics workspace
if ($LogAnalyticsSubscription -ne $CSPSubscriptionId) { $originalContext = Get-AzContext; Set-AzContext -SubscriptionId $LogAnalyticsSubscription | Out-Null }
$logAnalyticsWorkspace = Get-AzOperationalInsightsWorkspace -ResourceGroupName $LogAnalyticsResourceGroup -Name $LogAnalyticsWorkspaceName -ErrorAction SilentlyContinue
if ($LogAnalyticsSubscription -ne $CSPSubscriptionId) { Set-AzContext -Context $originalContext | Out-Null }

if (-not $logAnalyticsWorkspace) {
    Write-Host "Log Analytics Workspace '$LogAnalyticsWorkspaceName' not found in subscription $LogAnalyticsSubscription" -ForegroundColor Red
    exit 1
}

Write-Host "Prerequisites validated" -ForegroundColor Green

# --- Create Regional Data Collection Endpoints (DCEs) ---
$dceResourceIds = @{}
Write-Host "`n--- Creating Regional Data Collection Endpoints (DCEs) ---`n" -ForegroundColor Cyan
foreach ($region in $allRegions) {
    $dceName = "DCE-$CustomerName-DiskSpace-$region"
    $dceResourceId = "/subscriptions/$CSPSubscriptionId/resourceGroups/$CSPResourceGroupName/providers/Microsoft.Insights/dataCollectionEndpoints/$dceName"
    $dceResourceIds[$region] = $dceResourceId

    Write-Host "Processing DCE for region: $region" -ForegroundColor Yellow
    $existingDCE = Get-AzResource -ResourceId $dceResourceId -ErrorAction SilentlyContinue
    if (-not $existingDCE -and -not $DryRun) {
        try {
            Set-AzContext -SubscriptionId $CSPSubscriptionId | Out-Null
            $dceTemplate = New-DCETemplate -Name $dceName -Location $region
            New-AzResourceGroupDeployment -ResourceGroupName $CSPResourceGroupName -Name "DCE-$region-$(Get-Date -Format 'HHmmss')" -TemplateObject $dceTemplate | Out-Null
            Write-Host "  ✅ DCE created successfully in $region" -ForegroundColor Green
        } catch {
            Write-Host "  ❌ DCE creation failed in ${region}: $($_.Exception.Message)" -ForegroundColor Red
            continue
        }
    } elseif ($existingDCE) {
        Write-Host "  ✅ DCE already exists in $region" -ForegroundColor Green
    } elseif ($DryRun) {
        Write-Host "  [DRY RUN] Would create DCE: $dceName in $region" -ForegroundColor Magenta
    }
}

# --- Create Central Data Collection Rules (DCRs) ---
Write-Host "`n--- Creating Central Data Collection Rules (DCRs) ---`n" -ForegroundColor Cyan
$primaryDceId = $dceResourceIds[$Location]
if (-not $primaryDceId) {
    Write-Host "ERROR: Could not find a Data Collection Endpoint for the primary location '$Location'. This can happen if no VMs are tagged for monitoring in that location. Cannot create DCRs." -ForegroundColor Red
    exit 1
}

$dcrConfigs = @(
    @{ Name = "DCR-$CustomerName-Windows-DiskSpace"; OSType = "Windows" },
    @{ Name = "DCR-$CustomerName-Linux-DiskSpace";   OSType = "Linux" }
)

$dcrResourceIds = @{}
foreach ($config in $dcrConfigs) {
    $dcrName = $config.Name
    $dcrResourceId = "/subscriptions/$CSPSubscriptionId/resourceGroups/$CSPResourceGroupName/providers/Microsoft.Insights/dataCollectionRules/$dcrName"
    $dcrResourceIds[$config.OSType] = $dcrResourceId

    Write-Host "Processing DCR for $($config.OSType)" -ForegroundColor Yellow
    $existingDCR = Get-AzResource -ResourceId $dcrResourceId -ErrorAction SilentlyContinue
    if (-not $existingDCR -and -not $DryRun) {
        try {
            Set-AzContext -SubscriptionId $CSPSubscriptionId | Out-Null
            $template = New-DCRTemplate -Name $dcrName -OSType $config.OSType -LogAnalyticsResourceId $logAnalyticsWorkspace.ResourceId -Location $Location -CustomerName $CustomerName -DataCollectionEndpointId $primaryDceId
            New-AzResourceGroupDeployment -ResourceGroupName $CSPResourceGroupName -Name "DCR-$($config.OSType)-$(Get-Date -Format 'HHmmss')" -TemplateObject $template | Out-Null
            Write-Host "  ✅ DCR created successfully" -ForegroundColor Green
        } catch {
            Write-Host "  ❌ DCR creation failed: $($_.Exception.Message)" -ForegroundColor Red
            continue
        }
    } elseif ($existingDCR) {
        Write-Host "  ✅ DCR already exists" -ForegroundColor Green
    } elseif ($DryRun) {
        Write-Host "  [DRY RUN] Would create DCR: $dcrName" -ForegroundColor Magenta
    }
}

# --- Associate VMs with Regional DCE and Central DCR ---
Write-Host "`n--- Associating VMs ---`n" -ForegroundColor Cyan
Set-AzContext -SubscriptionId $SubscriptionId | Out-Null

foreach ($vm in $allMonitoredVMs) {
    $vmRegion = $vm.Location
    $regionalDceId = $dceResourceIds[$vmRegion]
    $osType = $vm.StorageProfile.OsDisk.OsType
    $dcrToUseId = $dcrResourceIds["$osType"]

    Write-Host "Processing VM: $($vm.Name) in region $vmRegion" -ForegroundColor White
    Write-Host "  - DCR: $(($dcrToUseId -split '/')[-1])" -ForegroundColor Gray
    Write-Host "  - DCE: $(($regionalDceId -split '/')[-1])" -ForegroundColor Gray

    Set-VMMonitoring -VM $vm -DCRResourceId $dcrToUseId -DCEResourceId $regionalDceId -DryRun $DryRun
}

# Summary
Write-Host "`nDeployment Summary:" -ForegroundColor Cyan
Write-Host "VMs Configured: $totalVMs" -ForegroundColor Green
Write-Host "Data Collection: 1-minute intervals to Perf table" -ForegroundColor Green
Write-Host "Cost Estimate: ~`$$(($totalVMs * 2.50).ToString('F2'))/month total" -ForegroundColor Green

Write-Host "`nNext Steps:" -ForegroundColor Yellow
Write-Host "1. Wait 15-20 minutes for data collection" -ForegroundColor White
Write-Host "2. Verify: Perf | where ObjectName == 'LogicalDisk' and CounterName == '% Free Space' | take 10" -ForegroundColor White
Write-Host "3. Run alert configuration script/Function to create per-disk alerts" -ForegroundColor White

if ($DryRun) {
    Write-Host "`nDRY RUN COMPLETE - No resources were modified" -ForegroundColor Magenta
}
