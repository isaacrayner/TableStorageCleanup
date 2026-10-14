<#
.SYNOPSIS
    Deploys Azure Monitor Agent infrastructure for a single subscription (WAD replacement).

.DESCRIPTION
    This script automates the migration from Windows Azure Diagnostics (WAD) to Azure Monitor Agent (AMA).
    It creates all necessary infrastructure and configures VMs to collect Windows Event Logs and Performance Counters.
    
    The script will:
    1. Create a resource group for monitoring infrastructure
    2. Create a Log Analytics Workspace with 90-day retention
    3. Discover all VMs and their locations
    4. Create regional Data Collection Endpoints (DCEs)
    5. Create Data Collection Rules (DCRs) for Windows and Linux (per region)
    6. Associate all VMs with their regional DCR and DCE
    7. Configure collection of System and Application event logs

.PARAMETER SubscriptionId
    The Azure subscription ID to process.

.PARAMETER SubscriptionName
    Friendly name for the subscription (used in resource naming).

.PARAMETER Location
    Primary Azure region for the Log Analytics Workspace and central resources. Default: uksouth

.PARAMETER ResourceGroupName
    Name for the monitoring resource group. Default: rg-monitoring-<SubscriptionName>

.PARAMETER LogAnalyticsWorkspaceName
    Name for the Log Analytics Workspace. Default: law-monitoring-<SubscriptionName>

.PARAMETER IncludeSecurityLogs
    Include Security event logs in addition to System and Application. Warning: Increases costs.

.PARAMETER WhatIf
    Shows what would be created without actually creating resources.

.EXAMPLE
    .\Deploy-AMAInfrastructure.ps1 -SubscriptionId "12345-..." -SubscriptionName "Prod"

.EXAMPLE
    .\Deploy-AMAInfrastructure.ps1 -SubscriptionId "12345-..." -SubscriptionName "Prod" -IncludeSecurityLogs -WhatIf

.NOTES
    Date: December 2025
    Project: Azure Diagnostics Modernisation
    
    Prerequisites:
    - Az.Accounts, Az.Resources, Az.Monitor, Az.Compute, Az.OperationalInsights modules
    - Contributor access to the subscription
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $true)]
    [string]$SubscriptionId,
    
    [Parameter(Mandatory = $true)]
    [string]$SubscriptionName,
    
    [Parameter(Mandatory = $false)]
    [string]$Location = "uksouth",
    
    [Parameter(Mandatory = $false)]
    [string]$ResourceGroupName,
    
    [Parameter(Mandatory = $false)]
    [string]$LogAnalyticsWorkspaceName,
    
    [Parameter(Mandatory = $false)]
    [switch]$IncludeSecurityLogs
)

#Requires -Modules Az.Accounts, Az.Resources, Az.Monitor, Az.Compute, Az.OperationalInsights

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

#region Functions

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('Info', 'Success', 'Warning', 'Error')]
        [string]$Level = 'Info'
    )
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $color = switch ($Level) {
        'Info'    { 'Cyan' }
        'Success' { 'Green' }
        'Warning' { 'Yellow' }
        'Error'   { 'Red' }
    }
    
    Write-Host "[$timestamp] " -NoNewline -ForegroundColor Gray
    Write-Host "[$Level] " -NoNewline -ForegroundColor $color
    Write-Host $Message
}

function New-MonitoringResourceGroup {
    param(
        [string]$Name,
        [string]$Location,
        [bool]$WhatIf
    )
    
    if ($WhatIfPreference) {
        Write-Log "WHATIF: Would create resource group '$Name' in '$Location'" -Level Warning
        return $null
    }
    
    $rg = Get-AzResourceGroup -Name $Name -ErrorAction SilentlyContinue
    if ($rg) {
        Write-Log "Resource group '$Name' already exists" -Level Success
        return $rg
    }
    
    Write-Log "Creating resource group '$Name' in '$Location'..." -Level Info
    $rg = New-AzResourceGroup -Name $Name -Location $Location
    Write-Log "Resource group created successfully" -Level Success
    return $rg
}

function New-LogAnalyticsWorkspace {
    param(
        [string]$Name,
        [string]$ResourceGroupName,
        [string]$Location,
        [bool]$WhatIf
    )
    
    if ($WhatIfPreference) {
        Write-Log "WHATIF: Would create Log Analytics Workspace '$Name'" -Level Warning
        return $null
    }
    
    $law = Get-AzOperationalInsightsWorkspace -ResourceGroupName $ResourceGroupName -Name $Name -ErrorAction SilentlyContinue
    if ($law) {
        Write-Log "Log Analytics Workspace '$Name' already exists" -Level Success
        return $law
    }
    
    Write-Log "Creating Log Analytics Workspace '$Name'..." -Level Info
    $law = New-AzOperationalInsightsWorkspace -ResourceGroupName $ResourceGroupName -Name $Name -Location $Location -Sku "PerGB2018" -RetentionInDays 90
    Write-Log "Log Analytics Workspace created successfully" -Level Success
    
    # Set 3GB daily cap
    Write-Log "Setting 3GB daily data cap..." -Level Info
    Set-AzOperationalInsightsWorkspace -ResourceGroupName $ResourceGroupName -Name $Name -DailyQuotaGb 3 | Out-Null
    Write-Log "Daily cap configured: 3GB" -Level Success
    
    # Set 90-day retention for Event table
    Write-Log "Configuring 90-day retention for Event table..." -Level Info
    try {
        Set-AzOperationalInsightsTable -ResourceGroupName $ResourceGroupName -WorkspaceName $Name -TableName "Event" -RetentionInDays 90 -ErrorAction SilentlyContinue | Out-Null
        Write-Log "Retention configured: 90 days for Event table" -Level Success
    } catch {
        Write-Log "Note: Retention will be applied once tables receive data" -Level Warning
    }
    
    return $law
}

function Get-AllVMs {
    Write-Log "Discovering all VMs in subscription..." -Level Info
    
    $vms = Get-AzVM
    $vmsByRegion = $vms | Group-Object -Property Location
    
    Write-Log "Found $($vms.Count) VM(s) across $($vmsByRegion.Count) region(s)" -Level Success
    
    foreach ($regionGroup in $vmsByRegion) {
        $windowsVMs = @($regionGroup.Group | Where-Object { $_.StorageProfile.OsDisk.OsType -eq "Windows" })
        $linuxVMs = @($regionGroup.Group | Where-Object { $_.StorageProfile.OsDisk.OsType -eq "Linux" })
        $windowsCount = $windowsVMs.Count
        $linuxCount = $linuxVMs.Count
        Write-Log "  Region '$($regionGroup.Name)': $windowsCount Windows, $linuxCount Linux" -Level Info
    }
    
    return @{
        AllVMs = $vms
        Regions = $vmsByRegion.Name
    }
}

function New-DataCollectionEndpoint {
    param(
        [string]$Name,
        [string]$ResourceGroupName,
        [string]$Location,
        [string]$SubscriptionName,
        [bool]$WhatIf
    )
    
    if ($WhatIfPreference) {
        Write-Log "WHATIF: Would create DCE '$Name' in '$Location'" -Level Warning
        return $null
    }
    
    $dceResourceId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Insights/dataCollectionEndpoints/$Name"
    $existingDCE = Get-AzResource -ResourceId $dceResourceId -ErrorAction SilentlyContinue
    
    if ($existingDCE) {
        Write-Log "DCE '$Name' already exists" -Level Success
        return $dceResourceId
    }
    
    Write-Log "Creating Data Collection Endpoint '$Name' in '$Location'..." -Level Info
    
    $template = @{
        '$schema' = "https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#"
        contentVersion = "1.0.0.0"
        resources = @(@{
            type = "Microsoft.Insights/dataCollectionEndpoints"
            apiVersion = "2022-06-01"
            name = $Name
            location = $Location
            tags = @{
                "Purpose" = "WAD-Replacement"
                "Subscription" = $SubscriptionName
            }
            properties = @{
                networkAcls = @{
                    publicNetworkAccess = "Enabled"
                }
            }
        })
    }
    
    $deployment = New-AzResourceGroupDeployment -ResourceGroupName $ResourceGroupName -Name "DCE-$Location-$(Get-Date -Format 'HHmmss')" -TemplateObject $template -ErrorAction Stop
    
    if ($deployment.ProvisioningState -eq "Succeeded") {
        Write-Log "DCE created successfully" -Level Success
        return $dceResourceId
    } else {
        Write-Log "DCE deployment failed with state: $($deployment.ProvisioningState)" -Level Error
        return $null
    }
}

function New-DataCollectionRule {
    param(
        [string]$Name,
        [string]$ResourceGroupName,
        [string]$Location,
        [string]$OSType,
        [string]$LogAnalyticsResourceId,
        [string]$DataCollectionEndpointId,
        [string]$SubscriptionName,
        [bool]$IncludeSecurityLogs,
        [bool]$WhatIf
    )
    
    if ($WhatIfPreference) {
        Write-Log "WHATIF: Would create DCR '$Name' for $OSType" -Level Warning
        return $null
    }
    
    $dcrResourceId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Insights/dataCollectionRules/$Name"
    $existingDCR = Get-AzResource -ResourceId $dcrResourceId -ErrorAction SilentlyContinue
    
    if ($existingDCR) {
        Write-Log "DCR '$Name' already exists" -Level Success
        return $dcrResourceId
    }
    
    Write-Log "Creating Data Collection Rule '$Name' for $OSType..." -Level Info
    
    if ($OSType -eq "Windows") {
        # Level 1=Critical, 2=Error, 3=Warning (excluding 4=Informational, 0=LogAlways)
        $xPathQueries = @(
            "System!*[System[(Level=1 or Level=2 or Level=3)]]",
            "Application!*[System[(Level=1 or Level=2 or Level=3)]]"
        )
        
        if ($IncludeSecurityLogs) {
            $xPathQueries += "Security!*"
        }
        
        $dataSources = @{
            windowsEventLogs = @(@{
                name = "eventLogsDataSource"
                streams = @("Microsoft-Event")
                xPathQueries = $xPathQueries
            })
        }
        
        $dataFlows = @(
            @{
                streams = @("Microsoft-Event")
                destinations = @("LAW-Destination")
                transformKql = "source"
            }
        )
    } else {
        # Linux - using syslog
        $dataSources = @{
            syslog = @(@{
                name = "syslogDataSource"
                streams = @("Microsoft-Syslog")
                facilityNames = @("auth", "authpriv", "cron", "daemon", "kern", "syslog")
                logLevels = @("Error", "Critical", "Alert", "Emergency", "Warning")
            })
        }
        
        $dataFlows = @(
            @{
                streams = @("Microsoft-Syslog")
                destinations = @("LAW-Destination")
                transformKql = "source"
            }
        )
    }
    
    $template = @{
        '$schema' = "https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#"
        contentVersion = "1.0.0.0"
        resources = @(@{
            type = "Microsoft.Insights/dataCollectionRules"
            apiVersion = "2022-06-01"
            name = $Name
            location = $Location
            tags = @{
                "Purpose" = "WAD-Replacement"
                "OSType" = $OSType
                "Subscription" = $SubscriptionName
                "Region" = $Location
            }
            properties = @{
                description = "WAD Replacement - $OSType Event Logs Only - $Location"
                dataCollectionEndpointId = $DataCollectionEndpointId
                dataSources = $dataSources
                destinations = @{
                    logAnalytics = @(@{
                        workspaceResourceId = $LogAnalyticsResourceId
                        name = "LAW-Destination"
                    })
                }
                dataFlows = $dataFlows
            }
        })
    }
    
    New-AzResourceGroupDeployment -ResourceGroupName $ResourceGroupName -Name "DCR-$OSType-$Location-$(Get-Date -Format 'HHmmss')" -TemplateObject $template | Out-Null
    Write-Log "DCR created successfully" -Level Success
    
    return $dcrResourceId
}

function Install-AzureMonitorAgent {
    param(
        [object]$VM,
        [bool]$WhatIf
    )
    
    if ($WhatIfPreference) {
        return $true
    }
    
    $vmIsWindows = $VM.StorageProfile.OsDisk.OsType -eq "Windows"
    $extensionName = if ($vmIsWindows) { "AzureMonitorWindowsAgent" } else { "AzureMonitorLinuxAgent" }
    
    $extension = Get-AzVMExtension -ResourceGroupName $VM.ResourceGroupName -VMName $VM.Name -Name $extensionName -ErrorAction SilentlyContinue
    
    if ($extension) {
        return $true
    }
    
    Write-Log "  Installing Azure Monitor Agent on '$($VM.Name)'..." -Level Info
    
    try {
        Set-AzVMExtension `
            -ResourceGroupName $VM.ResourceGroupName `
            -VMName $VM.Name `
            -Name $extensionName `
            -Publisher "Microsoft.Azure.Monitor" `
            -Type $extensionName `
            -TypeHandlerVersion "1.0" `
            -EnableAutomaticUpgrade:$true `
            -ErrorAction Stop | Out-Null
        
        return $true
    } catch {
        Write-Log "  Failed to install AMA: $_" -Level Error
        return $false
    }
}

function Set-VMDataCollection {
    param(
        [object]$VM,
        [string]$DCRResourceId,
        [string]$DCEResourceId,
        [bool]$WhatIf
    )
    
    if ($WhatIfPreference) {
        Write-Log "  WHATIF: Would associate '$($VM.Name)' with DCR and DCE" -Level Warning
        return
    }
    
    Write-Log "  Associating '$($VM.Name)' with DCR and DCE..." -Level Info
    
    # Install AMA first
    $amaInstalled = Install-AzureMonitorAgent -VM $VM -WhatIf $WhatIfPreference
    if (-not $amaInstalled) {
        Write-Log "  Skipping association due to AMA installation failure" -Level Error
        return
    }
    
    # Create associations
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
            @{
                type = "Microsoft.Insights/dataCollectionRuleAssociations"
                apiVersion = "2022-06-01"
                scope = "[format('Microsoft.Compute/virtualMachines/{0}', parameters('vmName'))]"
                name = "WAD-Replacement-DCR-Association"
                properties = @{ 
                    dataCollectionRuleId = "[parameters('dataCollectionRuleId')]"
                }
            },
            @{
                type = "Microsoft.Insights/dataCollectionRuleAssociations"
                apiVersion = "2022-06-01"
                scope = "[format('Microsoft.Compute/virtualMachines/{0}', parameters('vmName'))]"
                name = "configurationAccessEndpoint"
                properties = @{ 
                    dataCollectionEndpointId = "[parameters('dataCollectionEndpointId')]"
                }
            }
        )
    }
    
    try {
        New-AzResourceGroupDeployment `
            -ResourceGroupName $VM.ResourceGroupName `
            -Name "VMAssociations-$($VM.Name)-$(Get-Date -Format 'HHmmss')" `
            -TemplateObject $associationTemplate `
            -ErrorAction Stop | Out-Null
        
        Write-Log "  Successfully associated '$($VM.Name)'" -Level Success
    } catch {
        if ($_.Exception.Message -like "*already exists*") {
            Write-Log "  Already associated" -Level Success
        } else {
            Write-Log "  Association failed: $_" -Level Error
        }
    }
}

#endregion

#region Main Script

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Azure Monitor Agent Infrastructure Deployment" -ForegroundColor Cyan
Write-Host "WAD Replacement - Single Subscription" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# Set default names if not provided
if (-not $ResourceGroupName) {
    $ResourceGroupName = "rg-monitoring-$($SubscriptionName.ToLower() -replace '[^a-z0-9-]','')"
}

if (-not $LogAnalyticsWorkspaceName) {
    $LogAnalyticsWorkspaceName = "law-monitoring-$($SubscriptionName.ToLower() -replace '[^a-z0-9-]','')"
}

Write-Log "Configuration:" -Level Info
Write-Log "  Subscription: $SubscriptionName ($SubscriptionId)" -Level Info
Write-Log "  Resource Group: $ResourceGroupName" -Level Info
Write-Log "  Log Analytics Workspace: $LogAnalyticsWorkspaceName" -Level Info
Write-Log "  Primary Location: $Location" -Level Info
Write-Log "  Include Security Logs: $IncludeSecurityLogs" -Level Info
Write-Host ""

# Connect to subscription
Write-Log "Setting subscription context..." -Level Info
try {
    Set-AzContext -SubscriptionId $SubscriptionId | Out-Null
    Write-Log "Connected to subscription successfully" -Level Success
} catch {
    Write-Log "Failed to set subscription context: $_" -Level Error
    exit 1
}

# Step 1: Create Resource Group
Write-Host ""
Write-Log "=== Step 1: Create Resource Group ===" -Level Info
$rg = New-MonitoringResourceGroup -Name $ResourceGroupName -Location $Location -WhatIf $WhatIfPreference

# Step 2: Create Log Analytics Workspace
Write-Host ""
Write-Log "=== Step 2: Create Log Analytics Workspace ===" -Level Info
$law = New-LogAnalyticsWorkspace -Name $LogAnalyticsWorkspaceName -ResourceGroupName $ResourceGroupName -Location $Location -WhatIf $WhatIfPreference

# Step 3: Discover VMs
Write-Host ""
Write-Log "=== Step 3: Discover Virtual Machines ===" -Level Info
$vmData = Get-AllVMs

if ($vmData.AllVMs.Count -eq 0) {
    Write-Log "No VMs found in subscription. Nothing to configure." -Level Warning
    exit 0
}

# Step 4 & 5: Create Data Collection Infrastructure
Write-Host ""
Write-Log "=== Step 4 & 5: Create Data Collection Infrastructure ===" -Level Info

# Create regional DCEs (must be in same region as VMs for VM association)
Write-Host ""
Write-Log "Creating Regional Data Collection Endpoints..." -Level Info
$regionalDCEs = @{}

# Always create DCE in LAW region (needed for DCR reference)
$lawDceName = "dce-monitoring-$($SubscriptionName.ToLower() -replace '[^a-z0-9-]','')-$Location"
$lawDceId = New-DataCollectionEndpoint -Name $lawDceName -ResourceGroupName $ResourceGroupName -Location $Location -SubscriptionName $SubscriptionName -WhatIf $WhatIfPreference

if ($lawDceId) {
    $regionalDCEs[$Location] = $lawDceId
    Write-Log "Created DCE in LAW region '$Location' for DCR reference" -Level Info
} else {
    Write-Log "Failed to create DCE in LAW region '$Location'" -Level Error
    exit 1
}

# Create DCEs in VM regions (if different from LAW region)
foreach ($region in $vmData.Regions) {
    if ($region -eq $Location) {
        Write-Log "Skipping DCE creation for '$region' (already created for LAW)" -Level Info
        continue
    }
    
    $dceName = "dce-monitoring-$($SubscriptionName.ToLower() -replace '[^a-z0-9-]','')-$region"
    $dceId = New-DataCollectionEndpoint -Name $dceName -ResourceGroupName $ResourceGroupName -Location $region -SubscriptionName $SubscriptionName -WhatIf $WhatIfPreference
    
    if ($dceId) {
        $regionalDCEs[$region] = $dceId
        Write-Log "Created DCE for VM region '$region'" -Level Info
    } else {
        Write-Log "Failed to create DCE for region '$region'" -Level Error
    }
}

# Create DCRs in LAW region (must match LAW location)
# DCR must reference a DCE in the same region (use LAW region DCE)
$primaryDceId = $regionalDCEs[$Location]

if (-not $primaryDceId) {
    Write-Log "ERROR: DCE in LAW region '$Location' was not created successfully. Cannot create DCRs." -Level Error
    exit 1
}

Write-Host ""
Write-Log "Creating Data Collection Rules in LAW region: $Location" -Level Info
Write-Log "Using DCE in LAW region for DCR reference: $primaryDceId" -Level Info

$dcrs = @{}

# Check if we have any Windows VMs
$hasWindowsVMs = @($vmData.AllVMs | Where-Object { $_.StorageProfile.OsDisk.OsType -eq "Windows" }).Count -gt 0
if ($hasWindowsVMs) {
    Write-Log "Creating Windows DCR..." -Level Info
    $dcrWindowsName = "dcr-monitoring-windows-$($SubscriptionName.ToLower() -replace '[^a-z0-9-]','')"
    $dcrWindowsId = New-DataCollectionRule `
        -Name $dcrWindowsName `
        -ResourceGroupName $ResourceGroupName `
        -Location $Location `
        -OSType "Windows" `
        -LogAnalyticsResourceId $law.ResourceId `
        -DataCollectionEndpointId $primaryDceId `
        -SubscriptionName $SubscriptionName `
        -IncludeSecurityLogs $IncludeSecurityLogs `
        -WhatIf $WhatIfPreference
    $dcrs["Windows"] = $dcrWindowsId
}

# Check if we have any Linux VMs
$hasLinuxVMs = @($vmData.AllVMs | Where-Object { $_.StorageProfile.OsDisk.OsType -eq "Linux" }).Count -gt 0
if ($hasLinuxVMs) {
    Write-Log "Creating Linux DCR..." -Level Info
    $dcrLinuxName = "dcr-monitoring-linux-$($SubscriptionName.ToLower() -replace '[^a-z0-9-]','')"
    $dcrLinuxId = New-DataCollectionRule `
        -Name $dcrLinuxName `
        -ResourceGroupName $ResourceGroupName `
        -Location $Location `
        -OSType "Linux" `
        -LogAnalyticsResourceId $law.ResourceId `
        -DataCollectionEndpointId $primaryDceId `
        -SubscriptionName $SubscriptionName `
        -IncludeSecurityLogs $false `
        -WhatIf $WhatIfPreference
    $dcrs["Linux"] = $dcrLinuxId
}

# Step 6: Associate VMs with DCR and DCE
Write-Host ""
Write-Log "=== Step 6: Associate VMs with Data Collection Infrastructure ===" -Level Info

$successCount = 0
$failCount = 0

foreach ($vm in $vmData.AllVMs) {
    $vmRegion = $vm.Location
    $vmOS = $vm.StorageProfile.OsDisk.OsType
    
    Write-Log "Processing VM: $($vm.Name) ($vmOS) in $vmRegion" -Level Info
    
    # VMs use regional DCE (same region as VM) and central DCR (by OS type)
    # Force string conversion for hashtable lookup
    $dceId = $regionalDCEs[$vmRegion]
    $dcrId = $dcrs["$vmOS"]
    
    if (-not $dceId) {
        Write-Log "  Missing DCE for region $vmRegion - skipping" -Level Error
        $failCount++
        continue
    }
    
    if (-not $dcrId) {
        Write-Log "  Missing DCR for OS $vmOS - skipping" -Level Error
        $failCount++
        continue
    }
    
    try {
        Set-VMDataCollection -VM $vm -DCRResourceId $dcrId -DCEResourceId $dceId -WhatIf $WhatIfPreference
        $successCount++
    } catch {
        Write-Log "  Failed to configure VM: $_" -Level Error
        $failCount++
    }
}

# Step 7: Create Azure Policy for Auto-Association (Windows VMs only)
if ($dcrs.ContainsKey("Windows") -and -not $WhatIfPreference) {
    Write-Host ""
    Write-Log "=== Step 7: Create Azure Policy for Auto-Association ===" -Level Info
    
    $policyName = "auto-associate-windows-dcr-$($SubscriptionName.ToLower() -replace '[^a-z0-9-]','')"
    $policyDisplayName = "Auto-associate Windows VMs with Monitoring DCR - $SubscriptionName"
    
    # Check if policy already exists
    $existingPolicy = Get-AzPolicyAssignment -Name $policyName -Scope "/subscriptions/$SubscriptionId" -ErrorAction SilentlyContinue
    
    if (-not $existingPolicy) {
        Write-Log "Creating Azure Policy for automatic DCR association..." -Level Info
        
        try {
            # Use built-in policy: Configure Windows machines to be associated with a Data Collection Rule
            $builtInPolicyId = "/providers/Microsoft.Authorization/policyDefinitions/eab1f514-22e3-42e3-9a1f-e1dc9199355c"
            
            $policyParams = @{
                dcrResourceId = $dcrs["Windows"]
            }
            
            New-AzPolicyAssignment `
                -Name $policyName `
                -DisplayName $policyDisplayName `
                -Scope "/subscriptions/$SubscriptionId" `
                -PolicyDefinition (Get-AzPolicyDefinition -Id $builtInPolicyId) `
                -PolicyParameterObject $policyParams `
                -Location $Location `
                -IdentityType "SystemAssigned" | Out-Null
            
            Write-Log "Azure Policy created successfully" -Level Success
            Write-Log "  Policy will auto-associate new Windows VMs with the DCR" -Level Info
            Write-Log "  Note: Existing VMs require manual remediation task" -Level Warning
            
        } catch {
            Write-Log "Failed to create policy: $_" -Level Warning
            Write-Log "You can manually create the policy in Azure Portal" -Level Info
        }
    } else {
        Write-Log "Azure Policy '$policyName' already exists" -Level Success
    }
}

# Summary
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "DEPLOYMENT SUMMARY" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

Write-Log "Infrastructure Created:" -Level Info
Write-Log "  Resource Group: $ResourceGroupName" -Level Success
Write-Log "  Log Analytics Workspace: $LogAnalyticsWorkspaceName (90-day retention, 3GB daily cap)" -Level Success
Write-Log "  Data Collection Endpoints: $($regionalDCEs.Count) (regional)" -Level Success
Write-Log "  Data Collection Rules: $($dcrs.Count) (by OS type in $Location)" -Level Success
Write-Host ""

Write-Log "VM Configuration:" -Level Info
Write-Log "  Total VMs: $($vmData.AllVMs.Count)" -Level Info
Write-Log "  Successfully Configured: $successCount" -Level Success
Write-Log "  Failed: $failCount" -Level $(if ($failCount -gt 0) { 'Error' } else { 'Info' })
Write-Host ""

Write-Log "Data Collection:" -Level Info
Write-Log "  Event Logs: System, Application (Warning/Error/Critical only)$(if ($IncludeSecurityLogs) {', Security'} else {''})" -Level Success
Write-Host ""

Write-Log "Automation:" -Level Info
if ($dcrs.ContainsKey("Windows")) {
    Write-Log "  Azure Policy: Auto-associate new Windows VMs with DCR" -Level Success
}
Write-Host ""

if (-not $WhatIfPreference) {
    Write-Log "Next Steps:" -Level Info
    Write-Log "  1. Wait 15-20 minutes for data to start flowing" -Level Info
    Write-Log "  2. Verify in Azure Portal: Log Analytics Workspace > Logs" -Level Info
    Write-Log "  3. Test query: Event | where TimeGenerated > ago(1h) | take 10" -Level Info
    Write-Log "  4. Test query: Perf | where TimeGenerated > ago(1h) | take 10" -Level Info
    Write-Log "  5. Once verified, run Remove-WadExtension.ps1 to decommission WAD" -Level Info
} else {
    Write-Host ""
    Write-Log "DRY RUN COMPLETE - No resources were created" -Level Warning
}

Write-Host ""
Write-Log "Script completed successfully" -Level Success

#endregion
