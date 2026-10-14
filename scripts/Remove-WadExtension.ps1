<#
.SYNOPSIS
    Removes legacy diagnostic extensions (WAD and MMA) from Azure VMs in bulk.

.DESCRIPTION
    This script removes legacy monitoring extensions from multiple Azure VMs:
    - WAD (Windows Azure Diagnostics): IaaSDiagnostics, LinuxDiagnostic
    - MMA (Microsoft Monitoring Agent): MicrosoftMonitoringAgent, OmsAgentForLinux
    It supports:
    - Bulk removal across resource groups or entire subscriptions
    - Filtering by VM name patterns or tags
    - Discovery mode to see which VMs have WAD installed
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
    Azure subscription ID(s) to process. Can be a single ID or an array of IDs. Cannot be used with -AllSubscriptions.

.PARAMETER AllSubscriptions
    Process all subscriptions the current account has access to.

.PARAMETER DiscoveryOnly
    Only discover VMs with WAD extension installed, don't remove anything.

.PARAMETER Force
    Skips confirmation prompts (use with caution).

.EXAMPLE
    .\Remove-WadExtension.ps1 -SubscriptionId "12345678-1234-1234-1234-123456789012"
    Removes legacy extensions from specific subscription

.EXAMPLE
    .\Remove-WadExtension.ps1 -SubscriptionId "sub1-guid","sub2-guid","sub3-guid"
    Removes legacy extensions from multiple specified subscriptions

.EXAMPLE
    .\Remove-WadExtension.ps1 -DiscoveryOnly
    Lists all VMs with WAD and/or MMA extensions in current subscription

.EXAMPLE
    .\Remove-WadExtension.ps1 -ResourceGroupName "rg-production" -WhatIf
    Shows what extensions would be removed in the specified resource group

.EXAMPLE
    .\Remove-WadExtension.ps1 -VMNamePattern "web-*"
    Removes WAD and MMA extensions from all VMs starting with "web-"

.EXAMPLE
    .\Remove-WadExtension.ps1 -TagName "Environment" -TagValue "Production"
    Removes legacy extensions from all VMs tagged with Environment=Production

.EXAMPLE
    .\Remove-WadExtension.ps1 -Force
    Removes all legacy extensions from all VMs without confirmation

.NOTES
    Date: December 2025
    Project: Azure Diagnostics Modernisation
    
    IMPORTANT: Ensure you have:
    1. Migrated to Azure Monitor Agent (AMA) for modern monitoring
    2. Validated that new logging is working correctly in Log Analytics
    3. Confirmed no dependencies on WAD Table Storage data or MMA legacy logs
    4. Understand that MMA is deprecated - AMA is the replacement for both WAD and MMA
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
    [string[]]$SubscriptionId,
    
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

function Get-VmsWithWadExtension {
    param(
        [string]$ResourceGroupName,
        [string]$VMNamePattern,
        [string]$TagName,
        [string]$TagValue
    )
    
    Write-Log "Discovering VMs with WAD and/or MMA extensions..." -Level Info
    
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
        
        # Find VMs with WAD extension
        $vmsWithWad = @()
        $progressCount = 0
        
        foreach ($vm in $vms) {
            $progressCount++
            Write-Progress -Activity "Scanning VMs for WAD/MMA extensions" `
                -Status "Processing $($vm.Name) ($progressCount of $($vms.Count))" `
                -PercentComplete (($progressCount / $vms.Count) * 100)
            
            # Get VM extension details
            $extensions = Get-AzVMExtension -ResourceGroupName $vm.ResourceGroupName -VMName $vm.Name -ErrorAction SilentlyContinue
            
            # Look for legacy extensions:
            # WAD: IaaSDiagnostics (Windows), LinuxDiagnostic (Linux)
            # MMA: MicrosoftMonitoringAgent (Windows), OmsAgentForLinux (Linux)
            $legacyExtensions = $extensions | Where-Object { 
                $_.ExtensionType -eq 'IaaSDiagnostics' -or 
                $_.ExtensionType -eq 'LinuxDiagnostic' -or
                $_.ExtensionType -eq 'MicrosoftMonitoringAgent' -or
                $_.ExtensionType -eq 'OmsAgentForLinux' -or
                $_.Publisher -eq 'Microsoft.Azure.Diagnostics' -or
                $_.Publisher -eq 'Microsoft.EnterpriseCloud.Monitoring'
            }
            
            # Create one entry per extension found on this VM
            foreach ($extension in $legacyExtensions) {
                $vmsWithWad += [PSCustomObject]@{
                    VMName            = $vm.Name
                    ResourceGroup     = $vm.ResourceGroupName
                    Location          = $vm.Location
                    OSType            = $vm.StorageProfile.OsDisk.OsType
                    ExtensionName     = $extension.Name
                    ExtensionType     = $extension.ExtensionType
                    ExtensionVersion  = $extension.TypeHandlerVersion
                    ProvisioningState = $extension.ProvisioningState
                    VMObject          = $vm
                    Extension         = $extension
                }
            }
        }
        
        Write-Progress -Activity "Scanning VMs for WAD/MMA extensions" -Completed
        
        Write-Log "Found $($vmsWithWad.Count) legacy extension(s) (WAD/MMA) across VMs." -Level $(if ($vmsWithWad.Count -gt 0) { 'Success' } else { 'Warning' })
        
        return $vmsWithWad
    }
    catch {
        Write-Log "Failed to retrieve VMs: $_" -Level Error
        throw
    }
}

function Remove-WadExtensionFromVM {
    param(
        [PSCustomObject]$VMInfo,
        [switch]$WhatIf
    )
    
    try {
        if ($WhatIf) {
            Write-Log "WHATIF: Would remove extension '$($VMInfo.ExtensionName)' from VM '$($VMInfo.VMName)'" -Level Warning
            return $true
        }
        
        $extensionLabel = switch ($VMInfo.ExtensionType) {
            'IaaSDiagnostics' { 'WAD' }
            'LinuxDiagnostic' { 'WAD' }
            'MicrosoftMonitoringAgent' { 'MMA' }
            'OmsAgentForLinux' { 'MMA' }
            default { 'Legacy' }
        }
        
        Write-Log "Removing $extensionLabel extension '$($VMInfo.ExtensionName)' from '$($VMInfo.VMName)'..." -Level Info
        
        # Use a job with timeout for long-running operations
        $job = Start-Job -ScriptBlock {
            param($rg, $vmName, $extName)
            Remove-AzVMExtension -ResourceGroupName $rg -VMName $vmName -Name $extName -Force -ErrorAction Stop
        } -ArgumentList $VMInfo.ResourceGroup, $VMInfo.VMName, $VMInfo.ExtensionName
        
        # Wait for job with 5-minute timeout
        $completed = Wait-Job -Job $job -Timeout 300
        
        if ($null -eq $completed) {
            # Timeout occurred
            Stop-Job -Job $job
            Remove-Job -Job $job -Force
            Write-Log "Extension removal timed out after 5 minutes for '$($VMInfo.VMName)'. Extension may still be removing in background." -Level Warning
            return $false
        }
        
        # Check if job completed successfully
        $result = Receive-Job -Job $job -ErrorAction SilentlyContinue -ErrorVariable jobError
        Remove-Job -Job $job -Force
        
        if ($jobError) {
            Write-Log "Failed to remove $extensionLabel extension from '$($VMInfo.VMName)': $($jobError[0].Exception.Message)" -Level Error
            return $false
        }
        
        Write-Log "Successfully removed $extensionLabel extension from: $($VMInfo.VMName)" -Level Success
        return $true
    }
    catch {
        Write-Log "Failed to remove extension from '$($VMInfo.VMName)': $_" -Level Error
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
        Write-Log "No VMs with legacy extensions (WAD/MMA) found." -Level Warning
        return
    }
    
    # Group by subscription first, then resource group
    $groupedBySub = $VMs | Group-Object -Property SubscriptionName | Sort-Object Name
    
    foreach ($subGroup in $groupedBySub) {
        Write-Host ""
        Write-Host "Subscription: $($subGroup.Name) ($($subGroup.Count) VM(s))" -ForegroundColor Magenta
        
        $grouped = $subGroup.Group | Group-Object -Property ResourceGroup | Sort-Object Name
        
        foreach ($group in $grouped) {
            Write-Host "  Resource Group: $($group.Name) ($($group.Count) VM(s))" -ForegroundColor White
            
            foreach ($vm in $group.Group | Sort-Object VMName) {
                Write-Host "    VM: " -NoNewline -ForegroundColor Gray
                Write-Host "$($vm.VMName)" -NoNewline -ForegroundColor White
                Write-Host " | OS: $($vm.OSType) | Extension: $($vm.ExtensionType) v$($vm.ExtensionVersion)" -ForegroundColor Gray
            }
        }
    }
    
    Write-Host ""
}

function Confirm-Removal {
    param(
        [int]$TotalVMs
    )
    
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Yellow
    Write-Host "CONFIRMATION REQUIRED" -ForegroundColor Yellow
    Write-Host "========================================" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "You are about to remove legacy extensions (WAD/MMA) from:" -ForegroundColor Yellow
    Write-Host "  - $TotalVMs extension(s) across VM(s)" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "This will:" -ForegroundColor White
    Write-Host "  1. Stop WAD diagnostic data collection to Table Storage" -ForegroundColor White
    Write-Host "  2. Stop MMA log collection to Log Analytics (legacy agent)" -ForegroundColor White
    Write-Host "  3. Remove the extension(s) from each VM" -ForegroundColor White
    Write-Host "  4. Clear extension configuration from VM metadata" -ForegroundColor White
    Write-Host ""
    Write-Host "Ensure you have migrated to LAW/AMA before proceeding!" -ForegroundColor Red
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
        $Results | Select-Object SubscriptionName, SubscriptionId, VMName, ResourceGroup, OSType, ExtensionName, ExtensionType, Status | 
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
Write-Host "Legacy Extension Removal Script (WAD/MMA)" -ForegroundColor Cyan
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
    Write-Log "Processing specified subscription(s)..." -Level Info
    try {
        foreach ($subId in $SubscriptionId) {
            Write-Log "Adding subscription: $subId" -Level Info
            $sub = Set-AzContext -SubscriptionId $subId
            $subscriptionsToProcess += $sub.Subscription
        }
        Write-Log "Successfully added $($subscriptionsToProcess.Count) subscription(s)." -Level Success
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

$allVmsWithWad = @()

foreach ($subscription in $subscriptionsToProcess) {
    Write-Host ""
    Write-Log "Processing Subscription: $($subscription.Name) ($($subscription.Id))" -Level Info
    Write-Log "========================================" -Level Info
    
    try {
        # Set context to this subscription
        Set-AzContext -SubscriptionId $subscription.Id | Out-Null
        
        $vmsWithWad = Get-VmsWithWadExtension `
            -ResourceGroupName $ResourceGroupName `
            -VMNamePattern $VMNamePattern `
            -TagName $TagName `
            -TagValue $TagValue
        
        # Add subscription info to each VM
        foreach ($vm in $vmsWithWad) {
            $vm | Add-Member -NotePropertyName 'SubscriptionName' -NotePropertyValue $subscription.Name -Force
            $vm | Add-Member -NotePropertyName 'SubscriptionId' -NotePropertyValue $subscription.Id -Force
        }
        
        $allVmsWithWad += $vmsWithWad
        
        Write-Log "Found $($vmsWithWad.Count) VM(s) with WAD in this subscription." -Level Info
    }
    catch {
        Write-Log "Error processing subscription '$($subscription.Name)': $_" -Level Error
        continue
    }
}

$vmsWithWad = $allVmsWithWad

# Show discovery summary
Show-DiscoverySummary -VMs $vmsWithWad

if ($vmsWithWad.Count -eq 0) {
    Write-Log "No VMs with legacy extensions (WAD/MMA) found. Exiting." -Level Warning
    exit 0
}

# If discovery only, exit here
if ($DiscoveryOnly) {
    Write-Host ""
    Write-Log "Discovery complete. Found WAD and/or MMA extensions. Use without -DiscoveryOnly to remove." -Level Info
    
    # Optionally export to CSV
    $exportPath = "WAD_Discovery_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
    Export-ResultsToCSV -Results $vmsWithWad -FilePath $exportPath
    
    exit 0
}

# Confirmation (unless WhatIf or Force)
Write-Host ""

if ($WhatIfPreference) {
    Write-Log "Running in WhatIf mode - no removals will be performed." -Level Warning
    $proceed = $true
}
elseif ($Force) {
    Write-Log "Force mode enabled - skipping confirmation." -Level Warning
    $proceed = $true
}
else {
    $proceed = Confirm-Removal -TotalVMs $vmsWithWad.Count
}

if (-not $proceed) {
    Write-Log "Removal cancelled by user." -Level Warning
    exit 0
}

# Removal phase
Write-Host ""
Write-Host "========================================" -ForegroundColor Red
Write-Host "REMOVAL PHASE" -ForegroundColor Red
Write-Host "========================================" -ForegroundColor Red
Write-Host ""

$removalResults = @{
    Success = 0
    Failed  = 0
    Total   = $vmsWithWad.Count
}
$results = @()
$progressCount = 0

foreach ($vmInfo in $vmsWithWad) {
    $progressCount++
    Write-Progress -Activity "Removing legacy extensions (WAD/MMA)" `
        -Status "Processing $($vmInfo.VMName) in $($vmInfo.SubscriptionName) ($progressCount of $($vmsWithWad.Count))" `
        -PercentComplete (($progressCount / $vmsWithWad.Count) * 100)
    
    # Set context to the correct subscription
    try {
        Set-AzContext -SubscriptionId $vmInfo.SubscriptionId | Out-Null
    }
    catch {
        Write-Log "Failed to set context for subscription $($vmInfo.SubscriptionId): $_" -Level Error
        $removalResults.Failed++
        $results += [PSCustomObject]@{
            SubscriptionName = $vmInfo.SubscriptionName
            SubscriptionId   = $vmInfo.SubscriptionId
            VMName           = $vmInfo.VMName
            ResourceGroup    = $vmInfo.ResourceGroup
            OSType           = $vmInfo.OSType
            ExtensionName    = $vmInfo.ExtensionName
            ExtensionType    = $vmInfo.ExtensionType
            Status           = "Failed - Subscription Context Error"
        }
        continue
    }
    
    $success = Remove-WadExtensionFromVM -VMInfo $vmInfo -WhatIf:$WhatIfPreference
    
    if ($success) {
        $removalResults.Success++
        $status = "Success"
    }
    else {
        $removalResults.Failed++
        $status = "Failed"
    }
    
    $results += [PSCustomObject]@{
        SubscriptionName = $vmInfo.SubscriptionName
        SubscriptionId   = $vmInfo.SubscriptionId
        VMName           = $vmInfo.VMName
        ResourceGroup    = $vmInfo.ResourceGroup
        OSType           = $vmInfo.OSType
        ExtensionName    = $vmInfo.ExtensionName
        ExtensionType    = $vmInfo.ExtensionType
        Status           = $status
    }
    
    Start-Sleep -Milliseconds 500  # Brief pause between operations
}

Write-Progress -Activity "Removing legacy extensions (WAD/MMA)" -Completed

# Final summary
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "FINAL SUMMARY" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
Write-Log "Total VMs processed: $($removalResults.Total)" -Level Info
Write-Log "Successfully removed: $($removalResults.Success)" -Level Success
Write-Log "Failed removals: $($removalResults.Failed)" -Level $(if ($removalResults.Failed -gt 0) { 'Error' } else { 'Info' })
Write-Host ""

if ($WhatIfPreference) {
    Write-Log "WhatIf mode - no actual removals were performed." -Level Warning
}
elseif ($removalResults.Success -gt 0) {
    Write-Log "Removal completed successfully!" -Level Success
    Write-Log "WAD: VMs will stop writing to Table Storage." -Level Success
    Write-Log "MMA: VMs will stop sending logs via legacy agent." -Level Success
    Write-Log "Wait 30-60 minutes, then verify no new WAD table data before deletion." -Level Warning
}

# Export results to CSV
if (-not $WhatIfPreference) {
    Write-Host ""
    $exportPath = "WAD_Removal_Results_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
    Export-ResultsToCSV -Results $results -FilePath $exportPath
}

Write-Host ""
Write-Log "Script completed." -Level Info

#endregion
