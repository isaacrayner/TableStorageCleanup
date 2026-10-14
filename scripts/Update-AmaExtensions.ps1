<#
.SYNOPSIS
    Enables automatic upgrades for Azure Monitor Agent (AMA) extensions on Azure VMs.

.DESCRIPTION
    This script updates Azure Monitor Agent (AMA) extensions to enable automatic minor version upgrades.
    It processes:
    - Windows VMs: AzureMonitorWindowsAgent
    - Linux VMs: AzureMonitorLinuxAgent
    
    Features:
    - Bulk updates across resource groups or entire subscriptions
    - Filtering by VM name patterns or tags
    - Discovery mode to see which VMs have AMA installed
    - WhatIf mode for safe testing
    - Detailed logging and progress tracking

.PARAMETER ResourceGroupName
    Specific resource group to process. If not provided, processes all resource groups.

.PARAMETER VMNamePattern
    Wildcard pattern to filter VM names (e.g., "web-*", "*prod*").

.PARAMETER TagName
    Filter VMs by tag name.

.PARAMETER TagValue
    Filter VMs by tag value (requires TagName).

.PARAMETER SubscriptionId
    Azure subscription ID to process. Cannot be used with -AllSubscriptions.

.PARAMETER AllSubscriptions
    Process all subscriptions the current account has access to.

.PARAMETER DiscoveryOnly
    Only discover VMs with AMA extension installed, don't update anything.

.PARAMETER Force
    Skips confirmation prompts (use with caution).

.EXAMPLE
    .\Update-AmaExtensions.ps1 -SubscriptionId "12345678-1234-1234-1234-123456789012" -DiscoveryOnly
    Lists all VMs with AMA extensions in specific subscription

.EXAMPLE
    .\Update-AmaExtensions.ps1 -DiscoveryOnly
    Lists all VMs with AMA extensions in current subscription

.EXAMPLE
    .\Update-AmaExtensions.ps1 -ResourceGroupName "rg-production" -WhatIf
    Shows what would be updated in the specified resource group

.EXAMPLE
    .\Update-AmaExtensions.ps1 -Force
    Enables auto-upgrade on all AMA extensions without confirmation

.NOTES
    Date: December 2025
    Project: Azure Diagnostics Modernisation
    
    This script enables EnableAutomaticUpgrade on AMA extensions so they receive
    automatic minor version updates from Microsoft.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $false)]
    [string]$ResourceGroupName,
    
    [Parameter(Mandatory = $false)]
    [string]$VMNamePattern,
    
    [Parameter(Mandatory = $false)]
    [string]$TagName,
    
    [Parameter(Mandatory = $false)]
    [string]$TagValue,
    
    [Parameter(Mandatory = $false)]
    [string]$SubscriptionId,
    
    [Parameter(Mandatory = $false)]
    [switch]$AllSubscriptions,
    
    [Parameter(Mandatory = $false)]
    [switch]$DiscoveryOnly,
    
    [Parameter(Mandatory = $false)]
    [switch]$Force
)

# Strict mode for better error handling
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

function Test-AzureConnection {
    Write-Log "Checking Azure connection..." -Level Info
    
    try {
        $context = Get-AzContext
        if ($null -eq $context) {
            Write-Log "Not connected to Azure. Please run 'Connect-AzAccount' first." -Level Error
            return $false
        }
        
        Write-Log "Connected to Azure as: $($context.Account.Id)" -Level Success
        Write-Log "Subscription: $($context.Subscription.Name) ($($context.Subscription.Id))" -Level Info
        return $true
    }
    catch {
        Write-Log "Failed to get Azure context: $_" -Level Error
        return $false
    }
}

function Get-VmsWithAmaExtension {
    param(
        [string]$ResourceGroupName,
        [string]$VMNamePattern,
        [string]$TagName,
        [string]$TagValue
    )
    
    Write-Log "Discovering VMs with Azure Monitor Agent extensions..." -Level Info
    
    try {
        # Get all VMs or filtered by resource group
        if ($ResourceGroupName) {
            Write-Log "Filtering by resource group: $ResourceGroupName" -Level Info
            $vms = Get-AzVM -ResourceGroupName $ResourceGroupName
        }
        else {
            Write-Log "Scanning all resource groups in subscription..." -Level Info
            $vms = Get-AzVM
        }
        
        Write-Log "Found $($vms.Count) total VM(s) in scope." -Level Info
        
        # Apply VM name pattern filter
        if ($VMNamePattern) {
            Write-Log "Applying name pattern filter: $VMNamePattern" -Level Info
            $vms = $vms | Where-Object { $_.Name -like $VMNamePattern }
            Write-Log "Filtered to $($vms.Count) VM(s) matching name pattern." -Level Info
        }
        
        # Apply tag filter
        if ($TagName) {
            Write-Log "Applying tag filter: $TagName=$(if($TagValue){'$TagValue'}else{'*'})" -Level Info
            $vms = $vms | Where-Object { 
                $_.Tags.ContainsKey($TagName) -and 
                ((-not $TagValue) -or ($_.Tags[$TagName] -eq $TagValue))
            }
            Write-Log "Filtered to $($vms.Count) VM(s) matching tag filter." -Level Info
        }
        
        # Find VMs with AMA extension
        $vmsWithAma = @()
        $progressCount = 0
        
        foreach ($vm in $vms) {
            $progressCount++
            Write-Progress -Activity "Scanning VMs for AMA extensions" `
                -Status "Processing $($vm.Name) ($progressCount of $($vms.Count))" `
                -PercentComplete (($progressCount / $vms.Count) * 100)
            
            # Get VM extension details
            $extensions = Get-AzVMExtension -ResourceGroupName $vm.ResourceGroupName -VMName $vm.Name -ErrorAction SilentlyContinue
            
            # Look for AMA extensions
            $amaExtensions = $extensions | Where-Object { 
                $_.ExtensionType -eq 'AzureMonitorWindowsAgent' -or 
                $_.ExtensionType -eq 'AzureMonitorLinuxAgent'
            }
            
            # Create one entry per extension found on this VM
            foreach ($extension in $amaExtensions) {
                $vmsWithAma += [PSCustomObject]@{
                    VMName                  = $vm.Name
                    ResourceGroup           = $vm.ResourceGroupName
                    Location                = $vm.Location
                    OSType                  = $vm.StorageProfile.OsDisk.OsType
                    ExtensionName           = $extension.Name
                    ExtensionType           = $extension.ExtensionType
                    ExtensionVersion        = $extension.TypeHandlerVersion
                    AutoUpgradeMinorVersion = $extension.AutoUpgradeMinorVersion
                    EnableAutomaticUpgrade  = $extension.EnableAutomaticUpgrade
                    ProvisioningState       = $extension.ProvisioningState
                    VMObject                = $vm
                    Extension               = $extension
                }
            }
        }
        
        Write-Progress -Activity "Scanning VMs for AMA extensions" -Completed
        
        Write-Log "Found $($vmsWithAma.Count) AMA extension(s) across VMs." -Level $(if ($vmsWithAma.Count -gt 0) { 'Success' } else { 'Warning' })
        
        return $vmsWithAma
    }
    catch {
        Write-Log "Failed to retrieve VMs: $_" -Level Error
        throw
    }
}

function Update-AmaExtensionOnVM {
    param(
        [PSCustomObject]$VMInfo,
        [switch]$WhatIf
    )
    
    try {
        if ($WhatIf) {
            Write-Log "WHATIF: Would enable auto-upgrade for '$($VMInfo.ExtensionName)' on VM '$($VMInfo.VMName)'" -Level Warning
            return $true
        }
        
        # Check if already enabled
        if ($VMInfo.EnableAutomaticUpgrade -eq $true) {
            Write-Log "Auto-upgrade already enabled for '$($VMInfo.VMName)' - skipping" -Level Info
            return $true
        }
        
        Write-Log "Enabling auto-upgrade for AMA on '$($VMInfo.VMName)'..." -Level Info
        
        # Use Set-AzVMExtension to enable automatic upgrade
        # Keep the current version, just enable auto-upgrade flag
        $params = @{
            ResourceGroupName      = $VMInfo.ResourceGroup
            VMName                 = $VMInfo.VMName
            Name                   = $VMInfo.ExtensionName
            ExtensionType          = $VMInfo.ExtensionType
            Publisher              = 'Microsoft.Azure.Monitor'
            EnableAutomaticUpgrade = $true
            TypeHandlerVersion     = $VMInfo.ExtensionVersion
            ErrorAction            = 'Stop'
        }
        
        Set-AzVMExtension @params | Out-Null
        
        Write-Log "Successfully enabled auto-upgrade for: $($VMInfo.VMName)" -Level Success
        return $true
    }
    catch {
        Write-Log "Failed to update AMA on '$($VMInfo.VMName)': $_" -Level Error
        return $false
    }
}

function Show-DiscoverySummary {
    param(
        [PSCustomObject[]]$VMs
    )
    
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "DISCOVERY SUMMARY" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host ""
    
    if ($VMs.Count -eq 0) {
        Write-Log "No VMs with AMA extensions found." -Level Warning
        return
    }
    
    # Group by subscription first, then resource group
    $groupedBySub = $VMs | Group-Object -Property SubscriptionName | Sort-Object Name
    
    foreach ($subGroup in $groupedBySub) {
        Write-Host ""
        Write-Host "Subscription: $($subGroup.Name) ($($subGroup.Count) extension(s))" -ForegroundColor Magenta
        
        $grouped = $subGroup.Group | Group-Object -Property ResourceGroup | Sort-Object Name
        
        foreach ($group in $grouped) {
            Write-Host "  Resource Group: $($group.Name) ($($group.Count) extension(s))" -ForegroundColor White
            
            foreach ($vm in $group.Group | Sort-Object VMName) {
                $autoUpgradeStatus = if ($vm.EnableAutomaticUpgrade) { "[ENABLED] Auto-Upgrade" } else { "[DISABLED] Auto-Upgrade" }
                $statusColor = if ($vm.EnableAutomaticUpgrade) { 'Green' } else { 'Yellow' }
                
                Write-Host "    VM: " -NoNewline -ForegroundColor Gray
                Write-Host "$($vm.VMName)" -NoNewline -ForegroundColor White
                Write-Host " | OS: $($vm.OSType) | Version: $($vm.ExtensionVersion) | " -NoNewline -ForegroundColor Gray
                Write-Host $autoUpgradeStatus -ForegroundColor $statusColor
            }
        }
    }
    
    Write-Host ""
    
    # Summary stats
    $needsUpdate = @($VMs | Where-Object { -not $_.EnableAutomaticUpgrade }).Count
    $alreadyEnabled = @($VMs | Where-Object { $_.EnableAutomaticUpgrade }).Count
    
    Write-Host "Summary:" -ForegroundColor Cyan
    Write-Host "  Total AMA Extensions: $($VMs.Count)" -ForegroundColor White
    Write-Host "  Auto-Upgrade Enabled: $alreadyEnabled" -ForegroundColor Green
    Write-Host "  Needs Update: $needsUpdate" -ForegroundColor Yellow
    Write-Host ""
}

function Confirm-Update {
    param(
        [int]$TotalVMs
    )
    
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Yellow
    Write-Host "CONFIRMATION REQUIRED" -ForegroundColor Yellow
    Write-Host "========================================" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "You are about to enable automatic upgrades for AMA on:" -ForegroundColor Yellow
    Write-Host "  - $TotalVMs extension(s) across VM(s)" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "This will:" -ForegroundColor White
    Write-Host "  1. Enable EnableAutomaticUpgrade flag on each AMA extension" -ForegroundColor White
    Write-Host "  2. Allow Microsoft to automatically update minor versions in future" -ForegroundColor White
    Write-Host "  3. Keep VMs on latest security patches and features" -ForegroundColor White
    Write-Host ""
    Write-Host "This is a safe operation and recommended for all AMA deployments." -ForegroundColor Green
    Write-Host ""
    
    $response = Read-Host "Do you want to proceed? (yes/no)"
    return ($response -eq 'yes' -or $response -eq 'y')
}

function Export-ResultsToCSV {
    param(
        [PSCustomObject[]]$Results,
        [string]$FilePath
    )
    
    try {
        $Results | Select-Object SubscriptionName, SubscriptionId, VMName, ResourceGroup, OSType, ExtensionName, ExtensionType, ExtensionVersion, AutoUpgradeEnabled, Status | 
            Export-Csv -Path $FilePath -NoTypeInformation -Force
        
        Write-Log "Results exported to: $FilePath" -Level Success
    }
    catch {
        Write-Log "Failed to export results: $_" -Level Warning
    }
}

#endregion

#region Main Script

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "AMA Extension Auto-Upgrade Enablement Script" -ForegroundColor Cyan
Write-Host "Azure Diagnostics Modernisation" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# Check Azure connection
if (-not (Test-AzureConnection)) {
    Write-Log "Please connect to Azure using 'Connect-AzAccount' and try again." -Level Error
    exit 1
}

# Validate tag parameters
if ($TagValue -and -not $TagName) {
    Write-Log "TagValue specified without TagName. Please provide both or neither." -Level Error
    exit 1
}

# Validate subscription parameters
if ($SubscriptionId -and $AllSubscriptions) {
    Write-Log "Cannot specify both -SubscriptionId and -AllSubscriptions. Choose one." -Level Error
    exit 1
}

# Get list of subscriptions to process
$subscriptionsToProcess = @()

if ($AllSubscriptions) {
    Write-Log "Retrieving all accessible subscriptions..." -Level Info
    try {
        $allSubs = Get-AzSubscription
        Write-Log "Found $($allSubs.Count) subscription(s)." -Level Success
        $subscriptionsToProcess = $allSubs
    }
    catch {
        Write-Log "Failed to retrieve subscriptions: $_" -Level Error
        exit 1
    }
}
elseif ($SubscriptionId) {
    Write-Log "Setting subscription context to: $SubscriptionId" -Level Info
    try {
        $sub = Set-AzContext -SubscriptionId $SubscriptionId
        Write-Log "Subscription context set successfully." -Level Success
        $subscriptionsToProcess = @($sub.Subscription)
    }
    catch {
        Write-Log "Failed to set subscription context: $_" -Level Error
        exit 1
    }
}
else {
    # Use current subscription context
    $currentContext = Get-AzContext
    $subscriptionsToProcess = @($currentContext.Subscription)
    Write-Log "Using current subscription: $($currentContext.Subscription.Name)" -Level Info
}

# Discovery phase
Write-Host ""
Write-Log "Starting VM discovery phase across $($subscriptionsToProcess.Count) subscription(s)..." -Level Info
Write-Host ""

$allVmsWithAma = @()

foreach ($subscription in $subscriptionsToProcess) {
    Write-Host ""
    Write-Log "Processing Subscription: $($subscription.Name) ($($subscription.Id))" -Level Info
    Write-Log "========================================" -Level Info
    
    try {
        # Set context to this subscription
        Set-AzContext -SubscriptionId $subscription.Id | Out-Null
        
        $vmsWithAma = Get-VmsWithAmaExtension `
            -ResourceGroupName $ResourceGroupName `
            -VMNamePattern $VMNamePattern `
            -TagName $TagName `
            -TagValue $TagValue
        
        # Add subscription info to each VM
        foreach ($vm in $vmsWithAma) {
            $vm | Add-Member -NotePropertyName 'SubscriptionName' -NotePropertyValue $subscription.Name -Force
            $vm | Add-Member -NotePropertyName 'SubscriptionId' -NotePropertyValue $subscription.Id -Force
        }
        
        $allVmsWithAma += $vmsWithAma
        
        Write-Log "Found $($vmsWithAma.Count) extension(s) with AMA in this subscription." -Level Info
    }
    catch {
        Write-Log "Error processing subscription '$($subscription.Name)': $_" -Level Error
        continue
    }
}

$vmsWithAma = $allVmsWithAma

# Show discovery summary
Show-DiscoverySummary -VMs $vmsWithAma

if ($vmsWithAma.Count -eq 0) {
    Write-Log "No VMs with AMA extensions found. Exiting." -Level Warning
    exit 0
}

# If discovery only, exit here
if ($DiscoveryOnly) {
    Write-Host ""
    Write-Log "Discovery complete. Use without -DiscoveryOnly to enable auto-upgrade." -Level Info
    
    # Optionally export to CSV
    $exportPath = "AMA_Discovery_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
    Export-ResultsToCSV -Results $vmsWithAma -FilePath $exportPath
    
    exit 0
}

# Filter to only VMs that need updates
$vmsNeedingUpdate = @($vmsWithAma | Where-Object { -not $_.EnableAutomaticUpgrade })

if ($vmsNeedingUpdate.Count -eq 0) {
    Write-Host ""
    Write-Log "All AMA extensions already have auto-upgrade enabled. Nothing to do!" -Level Success
    exit 0
}

Write-Host ""
Write-Log "Found $($vmsNeedingUpdate.Count) extension(s) that need auto-upgrade enabled." -Level Info

# Confirmation (unless WhatIf or Force)
Write-Host ""

if ($WhatIfPreference) {
    Write-Log "Running in WhatIf mode - no updates will be performed." -Level Warning
    $proceed = $true
}
elseif ($Force) {
    Write-Log "Force mode enabled - skipping confirmation." -Level Warning
    $proceed = $true
}
else {
    $proceed = Confirm-Update -TotalVMs $vmsNeedingUpdate.Count
}

if (-not $proceed) {
    Write-Log "Update cancelled by user." -Level Warning
    exit 0
}

# Update phase
Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host "UPDATE PHASE" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host ""

$updateResults = @{
    Success = 0
    Failed  = 0
    Skipped = 0
    Total   = $vmsNeedingUpdate.Count
}
$results = @()
$progressCount = 0

foreach ($vmInfo in $vmsNeedingUpdate) {
    $progressCount++
    Write-Progress -Activity "Enabling AMA auto-upgrade" `
        -Status "Processing $($vmInfo.VMName) in $($vmInfo.SubscriptionName) ($progressCount of $($vmsNeedingUpdate.Count))" `
        -PercentComplete (($progressCount / $vmsNeedingUpdate.Count) * 100)
    
    # Set context to the correct subscription
    try {
        Set-AzContext -SubscriptionId $vmInfo.SubscriptionId | Out-Null
    }
    catch {
        Write-Log "Failed to set context for subscription $($vmInfo.SubscriptionId): $_" -Level Error
        $updateResults.Failed++
        $results += [PSCustomObject]@{
            SubscriptionName    = $vmInfo.SubscriptionName
            SubscriptionId      = $vmInfo.SubscriptionId
            VMName              = $vmInfo.VMName
            ResourceGroup       = $vmInfo.ResourceGroup
            OSType              = $vmInfo.OSType
            ExtensionName       = $vmInfo.ExtensionName
            ExtensionType       = $vmInfo.ExtensionType
            ExtensionVersion    = $vmInfo.ExtensionVersion
            AutoUpgradeEnabled  = $false
            Status              = "Failed - Subscription Context Error"
        }
        continue
    }
    
    $success = Update-AmaExtensionOnVM -VMInfo $vmInfo -WhatIf:$WhatIfPreference
    
    if ($success) {
        $updateResults.Success++
        $status = "Success"
        $autoUpgradeEnabled = $true
    }
    else {
        $updateResults.Failed++
        $status = "Failed"
        $autoUpgradeEnabled = $false
    }
    
    $results += [PSCustomObject]@{
        SubscriptionName    = $vmInfo.SubscriptionName
        SubscriptionId      = $vmInfo.SubscriptionId
        VMName              = $vmInfo.VMName
        ResourceGroup       = $vmInfo.ResourceGroup
        OSType              = $vmInfo.OSType
        ExtensionName       = $vmInfo.ExtensionName
        ExtensionType       = $vmInfo.ExtensionType
        ExtensionVersion    = $vmInfo.ExtensionVersion
        AutoUpgradeEnabled  = $autoUpgradeEnabled
        Status              = $status
    }
    
    Start-Sleep -Milliseconds 500  # Brief pause between operations
}

Write-Progress -Activity "Enabling AMA auto-upgrade" -Completed

# Final summary
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "FINAL SUMMARY" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
Write-Log "Total extensions processed: $($updateResults.Total)" -Level Info
Write-Log "Successfully updated: $($updateResults.Success)" -Level Success
Write-Log "Failed updates: $($updateResults.Failed)" -Level $(if ($updateResults.Failed -gt 0) { 'Error' } else { 'Info' })
Write-Host ""

if ($WhatIfPreference) {
    Write-Log "WhatIf mode - no actual updates were performed." -Level Warning
}
elseif ($updateResults.Success -gt 0) {
    Write-Log "Auto-upgrade enabled successfully!" -Level Success
    Write-Log "AMA extensions will now receive automatic minor version updates from Microsoft." -Level Success
}

# Export results to CSV
if (-not $WhatIfPreference) {
    Write-Host ""
    $exportPath = "AMA_AutoUpgrade_Results_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
    Export-ResultsToCSV -Results $results -FilePath $exportPath
}

Write-Host ""
Write-Log "Script completed." -Level Info

#endregion
